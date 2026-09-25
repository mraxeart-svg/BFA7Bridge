/*
 * BFA7 / Xiaomi Glasses iOS Import KEY-LITE hook.
 *
 * Crash-resistant version after the full key hook proved too aggressive.
 * It does NOT hook constructors, setEncrypt, stack windows, or broad Swift
 * symbols. It only logs:
 * - discovered MIWFlowEncrypt / MIWBTSession.setEncrypt symbols
 * - MIWFlowEncrypt.encrypt(data:) plaintext + ciphertext candidates
 * - CoreBluetooth writes to FE95/005F/005E
 * - NEHotspotConfiguration SSID/passphrase
 *
 * Run:
 *   py -3.12 -m frida_tools.repl -H 127.0.0.1:27042 -p <PID> -l frida-ios-xiaomi-import-key-lite-hook.js | Tee-Object <log>
 */

'use strict';

const STATE = { hooked: new Set() };
const MAX_DATA = 768;

function now() { return new Date().toISOString(); }
function log(message) { console.log(`[BFA7-iOS-KEY-LITE ${now()}] ${message}`); }
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
  if (pointer.isNull()) return false;
  const range = Process.findRangeByAddress(pointer);
  return !!range && range.protection.indexOf('r') >= 0;
}
function readBytes(pointer, length, limit) {
  if (pointer.isNull() || length <= 0 || !rangeReadable(pointer)) return null;
  const count = Math.min(length, limit || MAX_DATA);
  const raw = Memory.readByteArray(pointer, count);
  return raw === null ? null : new Uint8Array(raw);
}
function dumpBytes(pointer, length, limit) {
  const bytes = readBytes(pointer, length, limit || MAX_DATA);
  if (!bytes) return `${pointer} <unreadable>`;
  const suffix = length > bytes.length ? ` ... (${length} bytes)` : ` (${length} bytes)`;
  return `${bytesToHex(bytes)}${suffix} ascii=${bytesToAscii(bytes)}`;
}
function pointerHigh32(pointer) { return safe(() => pointer.shr(32).toUInt32(), -1); }
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
function stripSwiftPointerTag(pointer) { return safe(() => pointer.and(ptr('0x0000ffffffffffff')), ptr('0')); }
function logSwiftDataCandidate(label, x0, x1) {
  const count = pointerHigh32(x0);
  const inlineX0 = pointerLowBytes(x0, 8);
  const inlineX1 = pointerLowBytes(x1, 8);
  log(`${label} inline x0-le=${bytesToHex(inlineX0)} ascii=${bytesToAscii(inlineX0)} x1-le=${bytesToHex(inlineX1)} ascii=${bytesToAscii(inlineX1)} count-hi32=${count}`);

  if (count <= 0 || count > 4096) return;
  const taggedX1 = stripSwiftPointerTag(x1);
  if (!rangeReadable(taggedX1)) {
    log(`${label} x1-tagged=${taggedX1} len=${count} <unreadable>`);
    return;
  }

  const direct = readBytes(taggedX1, count, MAX_DATA);
  if (direct) {
    log(`${label} x1-tagged=${taggedX1} len=${count} ${dumpBytes(taggedX1, count, MAX_DATA)}`);
  }

  // In previous successful flow logs, Swift Data bytes were usually at x1-slot+16.
  [0, 8, 16, 24].forEach(offset => {
    const slot = taggedX1.add(offset);
    if (!rangeReadable(slot)) return;
    const candidate = safe(() => Memory.readPointer(slot), ptr('0'));
    if (candidate.isNull() || !rangeReadable(candidate)) return;
    log(`${label} x1-slot+${offset}=${candidate} len=${count} ${dumpBytes(candidate, count, MAX_DATA)}`);
  });
}
function nsDataInfo(objPtr, limit) {
  if (!ObjC.available || objPtr.isNull()) return '<no-nsdata>';
  return safe(() => {
    const obj = new ObjC.Object(objPtr);
    const cls = obj.$className || '';
    const length = Number(obj.length());
    return `${cls} len=${length} hex=${dumpBytes(obj.bytes(), length, limit || MAX_DATA)}`;
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
      log(`CB WRITE characteristic=${characteristic} type=${safe(() => args[4].toInt32(), '?')} ${nsDataInfo(args[2], MAX_DATA)}`);
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
function isEncryptSymbol(symbol) {
  const name = symbol.name || '';
  return /MIWFlowEncryptC7encrypt4data|MIWFlowEncrypt.*encrypt4data/.test(name);
}
function hookEncryptSymbol(module, symbol) {
  const key = `swift-encrypt:${symbol.address}`;
  if (STATE.hooked.has(key) || !symbol.address) return;
  STATE.hooked.add(key);
  try {
    Interceptor.attach(symbol.address, {
      onEnter(args) {
        this.x0 = args[0];
        this.x1 = args[1];
        log(`ENCRYPT ENTER addr=${symbol.address} name=${symbol.name} self=${args[0]} x1=${args[1]}`);
        logSwiftDataCandidate('ENCRYPT ARG', args[0], args[1]);
      },
      onLeave(retval) {
        log(`ENCRYPT LEAVE ret=${retval} x0=${this.context.x0} x1=${this.context.x1}`);
        logSwiftDataCandidate('ENCRYPT RET', this.context.x0, this.context.x1);
      }
    });
    log(`HOOK Swift MIWFlowEncrypt.encrypt(data:) ${symbol.name}`);
  } catch (error) {
    log(`SKIP Swift encrypt ${symbol.name}: ${error}`);
  }
}
function hookSwiftLite() {
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
      if (symbol.name && /MIWFlowEncrypt|MIWBTSession.*setEncrypt|MIWBTSessionC10setEncrypt/.test(symbol.name)) {
        if (discovered < 140) log(`DISCOVER ${symbol.address} ${symbol.name}`);
        discovered += 1;
      }
    });
    log(`DISCOVER matched=${discovered}`);
    symbols.forEach(symbol => { if (isEncryptSymbol(symbol)) hookEncryptSymbol(module, symbol); });
  });
}
function install() {
  if (!ObjC.available) {
    log('ObjC runtime is not available');
    return;
  }
  log('Installing BFA7 iOS Xiaomi KEY-LITE hooks');
  hookCoreBluetooth();
  hookHotspotConfiguration();
  hookSwiftLite();
  log(`Installed key-lite hooks=${STATE.hooked.size}`);
}

setImmediate(install);

rpc.exports = {
  ping() { return `key-lite hooks=${STATE.hooked.size}`; }
};
