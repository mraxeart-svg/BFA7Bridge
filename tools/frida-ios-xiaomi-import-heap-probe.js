/*
 * BFA7 / Xiaomi Glasses iOS Import HEAP probe.
 *
 * No Swift Interceptor.attach. This avoids the crash seen when attaching to
 * MIWFlowEncrypt.encrypt(data:). The probe:
 * - discovers MIWFlowEncrypt symbols and field-offset globals
 * - searches ObjC runtime for MIWFlowEncrypt class instances
 * - dumps suspected appKey/appIV/deviceKey/deviceIV fields from object memory
 * - hooks only ObjC CoreBluetooth writes and Hotspot config
 *
 * Run:
 *   py -3.12 -m frida_tools.repl -H 127.0.0.1:27042 -p <PID> -l frida-ios-xiaomi-import-heap-probe.js | Tee-Object <log>
 */

'use strict';

const STATE = {
  hooked: new Set(),
  fieldOffsets: {},
  classNames: [],
  lastProbeMs: 0
};

function now() { return new Date().toISOString(); }
function log(message) { console.log(`[BFA7-iOS-HEAP ${now()}] ${message}`); }
function safe(fn, fallback) {
  try { return fn(); } catch (error) { return fallback === undefined ? `<error: ${error}>` : fallback; }
}
function hexByte(value) {
  const text = (value & 0xff).toString(16).toUpperCase();
  return text.length === 1 ? `0${text}` : text;
}
function bytesToHex(bytes) {
  const out = [];
  for (let i = 0; i < bytes.length; i += 1) out.push(hexByte(bytes[i]));
  return out.join(' ');
}
function bytesToAscii(bytes) {
  let out = '';
  for (let i = 0; i < bytes.length; i += 1) {
    const v = bytes[i];
    out += v >= 0x20 && v <= 0x7e ? String.fromCharCode(v) : '.';
  }
  return out;
}
function rangeReadable(pointer) {
  if (!pointer || pointer.isNull()) return false;
  const range = Process.findRangeByAddress(pointer);
  return !!range && range.protection.indexOf('r') >= 0;
}
function readBytes(pointer, length, limit) {
  if (!rangeReadable(pointer) || length <= 0) return null;
  const count = Math.min(length, limit || 512);
  const raw = Memory.readByteArray(pointer, count);
  return raw === null ? null : new Uint8Array(raw);
}
function dumpBytes(pointer, length, limit) {
  const bytes = readBytes(pointer, length, limit || 512);
  if (!bytes) return `${pointer} <unreadable>`;
  const suffix = length > bytes.length ? ` ... (${length} bytes)` : ` (${length} bytes)`;
  return `${bytesToHex(bytes)}${suffix} ascii=${bytesToAscii(bytes)}`;
}
function pointerLowBytes(pointer, count) {
  return safe(() => {
    let value = pointer;
    const out = [];
    for (let i = 0; i < count; i += 1) {
      out.push(value.and(ptr('0xff')).toUInt32());
      value = value.shr(8);
    }
    return out;
  }, []);
}
function pointerHigh32(pointer) { return safe(() => pointer.shr(32).toUInt32(), -1); }
function stripSwiftPointerTag(pointer) { return safe(() => pointer.and(ptr('0x0000ffffffffffff')), ptr('0')); }
function nsDataInfo(objPtr, limit) {
  if (!ObjC.available || objPtr.isNull()) return '<no-nsdata>';
  return safe(() => {
    const obj = new ObjC.Object(objPtr);
    const cls = obj.$className || '';
    const length = Number(obj.length());
    return `${cls} len=${length} hex=${dumpBytes(obj.bytes(), length, limit || 768)}`;
  }, `<nsdata-error ptr=${objPtr}>`);
}
function nsDataLength(objPtr) {
  if (!ObjC.available || objPtr.isNull()) return -1;
  return safe(() => Number(new ObjC.Object(objPtr).length()), -1);
}
function objSummary(objPtr) {
  if (!ObjC.available || objPtr.isNull()) return `${objPtr}`;
  return safe(() => {
    const obj = new ObjC.Object(objPtr);
    return `${obj.$className || ''}: ${obj.toString()}`;
  }, `${objPtr}`);
}
function characteristicSummary(charPtr) {
  if (!ObjC.available || charPtr.isNull()) return `${charPtr}`;
  return safe(() => {
    const characteristic = new ObjC.Object(charPtr);
    const uuid = characteristic.UUID();
    const uuidText = uuid.UUIDString ? uuid.UUIDString().toString() : uuid.toString();
    const service = characteristic.service ? characteristic.service() : null;
    let serviceText = '?';
    if (service && !service.isNull()) {
      const serviceObj = new ObjC.Object(service);
      const serviceUUID = serviceObj.UUID();
      serviceText = serviceUUID.UUIDString ? serviceUUID.UUIDString().toString() : serviceUUID.toString();
    }
    return `${serviceText}/${uuidText}`;
  }, objSummary(charPtr));
}
function hookObjCMethod(className, selector, handler) {
  if (!ObjC.available) return;
  const cls = ObjC.classes[className];
  if (!cls || !cls[selector]) return;
  const key = `${className} ${selector}`;
  if (STATE.hooked.has(key)) return;
  STATE.hooked.add(key);
  Interceptor.attach(cls[selector].implementation, handler);
  log(`HOOK ObjC ${key}`);
}
function hookCoreBluetooth() {
  hookObjCMethod('CBPeripheral', '- writeValue:forCharacteristic:type:', {
    onEnter(args) {
      const characteristic = characteristicSummary(args[3]);
      const length = nsDataLength(args[2]);
      if (characteristic.indexOf('005F') < 0 && characteristic.indexOf('005E') < 0 && length < 20) return;
      log(`CB WRITE characteristic=${characteristic} type=${safe(() => args[4].toInt32(), '?')} ${nsDataInfo(args[2], 1024)}`);
      scheduleHeapProbe('after-cb-write');
    }
  });
}
function hookHotspotConfiguration() {
  hookObjCMethod('NEHotspotConfigurationManager', '- applyConfiguration:completionHandler:', {
    onEnter(args) { log(`HOTSPOT applyConfiguration ${objSummary(args[2])}`); }
  });
  hookObjCMethod('NEHotspotConfiguration', '- initWithSSID:passphrase:isWEP:', {
    onEnter(args) { log(`HOTSPOT config ssid=${objSummary(args[2])} passphrase=${objSummary(args[3])}`); }
  });
  hookObjCMethod('NEHotspotConfiguration', '- initWithSSID:', {
    onEnter(args) { log(`HOTSPOT config ssid=${objSummary(args[2])} passphrase=<none>`); }
  });
}
function fieldNameFromSymbol(name) {
  if (name.indexOf('C6appKey10Foundation4DataVSgvpWvd') >= 0) return 'appKey';
  if (name.indexOf('C5appIV10Foundation4DataVSgvpWvd') >= 0) return 'appIV';
  if (name.indexOf('C9deviceKey10Foundation4DataVSgvpWvd') >= 0) return 'deviceKey';
  if (name.indexOf('C8deviceIV10Foundation4DataVSgvpWvd') >= 0) return 'deviceIV';
  if (name.indexOf('C13appAesContext') >= 0 && name.indexOf('Wvd') >= 0) return 'appAesContext';
  if (name.indexOf('C16deviceAesContext') >= 0 && name.indexOf('Wvd') >= 0) return 'deviceAesContext';
  return null;
}
function discoverSwiftMetadata() {
  const modules = Process.enumerateModules().filter(m => m.name.indexOf('MIWBTCore') >= 0 || (m.path || '').indexOf('MIWBTCore') >= 0);
  if (modules.length === 0) {
    log('MIWBTCore module not found');
    return;
  }
  modules.forEach(module => {
    const symbols = safe(() => Module.enumerateSymbolsSync(module.name), []);
    log(`MIWBTCore symbol count=${symbols.length} module=${module.name} base=${module.base} path=${module.path}`);
    let discovered = 0;
    symbols.forEach(symbol => {
      const name = symbol.name || '';
      if (!/MIWFlowEncrypt|MIWBTSession.*setEncrypt|MIWBTSessionC10setEncrypt/.test(name)) return;
      if (discovered < 160) log(`DISCOVER ${symbol.address} ${name}`);
      discovered += 1;
      const field = fieldNameFromSymbol(name);
      if (field && symbol.address && !symbol.address.isNull() && rangeReadable(symbol.address)) {
        const u32 = safe(() => Memory.readU32(symbol.address), null);
        const s32 = safe(() => Memory.readS32(symbol.address), null);
        const p = safe(() => Memory.readPointer(symbol.address), ptr('0'));
        STATE.fieldOffsets[field] = u32;
        log(`FIELD-OFFSET ${field} symbol=${symbol.address} u32=${u32} s32=${s32} ptr=${p}`);
      }
    });
    log(`DISCOVER matched=${discovered}`);
  });
}
function discoverObjCClasses() {
  if (!ObjC.available) return;
  const names = Object.keys(ObjC.classes).filter(name => /MIWFlowEncrypt|FlowEncrypt/.test(name));
  STATE.classNames = names;
  if (names.length === 0) {
    log('OBJC class MIWFlowEncrypt not found');
  } else {
    names.forEach(name => log(`OBJC class candidate ${name}`));
  }
}
function logSwiftDataAt(label, pointer) {
  if (!rangeReadable(pointer)) {
    log(`${label} ${pointer} <unreadable>`);
    return;
  }
  const w0 = safe(() => Memory.readPointer(pointer), ptr('0'));
  const w1 = safe(() => Memory.readPointer(pointer.add(Process.pointerSize)), ptr('0'));
  const inline = pointerLowBytes(w0, 8).concat(pointerLowBytes(w1, 8));
  const count = pointerHigh32(w0);
  log(`${label} raw=${dumpBytes(pointer, 32, 32)} w0=${w0} w1=${w1} inline=${bytesToHex(inline)} ascii=${bytesToAscii(inline)} count-hi32=${count}`);
  if (count > 0 && count <= 4096) {
    const tagged = stripSwiftPointerTag(w1);
    if (rangeReadable(tagged)) log(`${label} w1-tagged=${tagged} len=${count} ${dumpBytes(tagged, count, 256)}`);
    [0, 8, 16, 24].forEach(offset => {
      const slot = tagged.add(offset);
      if (!rangeReadable(slot)) return;
      const candidate = safe(() => Memory.readPointer(slot), ptr('0'));
      if (!candidate.isNull() && rangeReadable(candidate)) {
        log(`${label} w1-slot+${offset}=${candidate} len=${count} ${dumpBytes(candidate, count, 256)}`);
      }
    });
  }
}
function dumpEncryptObject(instancePtr, className, index) {
  log(`INSTANCE ${className}[${index}] ptr=${instancePtr} memory=${dumpBytes(instancePtr, 192, 192)}`);
  Object.keys(STATE.fieldOffsets).forEach(field => {
    const off = STATE.fieldOffsets[field];
    if (typeof off !== 'number' || off <= 0 || off > 512) {
      log(`FIELD ${field} offset=${off} skipped`);
      return;
    }
    const fieldPtr = instancePtr.add(off);
    logSwiftDataAt(`FIELD ${className}[${index}].${field} offset=${off}`, fieldPtr);
  });
}
function heapProbe(reason) {
  if (!ObjC.available) return;
  log(`HEAP-PROBE start reason=${reason} classes=${STATE.classNames.length}`);
  STATE.classNames.forEach(className => {
    const klass = ObjC.classes[className];
    if (!klass) return;
    let count = 0;
    safe(() => {
      ObjC.choose(klass, {
        onMatch(instance) {
          if (count < 8) dumpEncryptObject(instance.handle, className, count);
          count += 1;
        },
        onComplete() { log(`HEAP-PROBE class=${className} instances=${count}`); }
      });
    }, null);
  });
  log(`HEAP-PROBE end reason=${reason}`);
}
function scheduleHeapProbe(reason) {
  const current = Date.now();
  if (current - STATE.lastProbeMs < 1500) return;
  STATE.lastProbeMs = current;
  setTimeout(() => heapProbe(reason), 50);
}
function install() {
  if (!ObjC.available) {
    log('ObjC runtime is not available');
    return;
  }
  log('Installing BFA7 iOS Xiaomi HEAP probe');
  hookCoreBluetooth();
  hookHotspotConfiguration();
  discoverSwiftMetadata();
  discoverObjCClasses();
  scheduleHeapProbe('startup');
  setInterval(() => scheduleHeapProbe('timer'), 5000);
  log(`Installed heap probe hooks=${STATE.hooked.size}`);
}

setImmediate(install);

rpc.exports = {
  ping() { return `heap hooks=${STATE.hooked.size} classes=${STATE.classNames.length}`; },
  probe() { heapProbe('rpc'); return 'ok'; }
};
