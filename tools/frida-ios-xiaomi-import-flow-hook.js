/*
 * BFA7 / Xiaomi Glasses iOS Import FLOW hook.
 *
 * Narrow hook for the MIWBTCore crypto boundary. It avoids broad Swift auto-hooks
 * and logs the CoreBluetooth/Hotspot flow plus MIWFlowEncrypt encrypt/decrypt
 * argument buffers. Use after the crypto discovery hook has shown the exact
 * Swift symbol names.
 *
 * Run:
 *   frida -H 127.0.0.1:27042 -p <PID> -l tools/frida-ios-xiaomi-import-flow-hook.js
 */

'use strict';

const STATE = { hooked: new Set() };
const FLOW_SYMBOLS = [
  ['$s9MIWBTCore14MIWFlowEncryptC7encrypt4data10Foundation4DataVSgAH_tF', 'MIWFlowEncrypt.encrypt(data:)'],
  ['$s9MIWBTCore14MIWFlowEncryptC7decrypt4data10Foundation4DataVSgAH_tF', 'MIWFlowEncrypt.decrypt(data:)']
];

function now() {
  return new Date().toISOString();
}

function log(message) {
  console.log(`[BFA7-iOS-FLOW ${now()}] ${message}`);
}

function safe(fn, fallback) {
  try {
    return fn();
  } catch (error) {
    return fallback === undefined ? `<error: ${error}>` : fallback;
  }
}

function hexByte(value) {
  const text = (value & 0xff).toString(16).toUpperCase();
  return text.length === 1 ? `0${text}` : text;
}

function bytesToHex(bytes) {
  const out = [];
  for (let index = 0; index < bytes.length; index += 1) {
    out.push(hexByte(bytes[index]));
  }
  return out.join(' ');
}

function bytesToAscii(bytes) {
  let out = '';
  for (let index = 0; index < bytes.length; index += 1) {
    const value = bytes[index];
    out += value >= 0x20 && value <= 0x7e ? String.fromCharCode(value) : '.';
  }
  return out;
}

function readBytes(pointer, length, limit) {
  if (pointer.isNull() || length <= 0) {
    return null;
  }
  const count = Math.min(length, limit || 1024);
  const range = Process.findRangeByAddress(pointer);
  if (!range || range.protection.indexOf('r') < 0) {
    return null;
  }
  const raw = Memory.readByteArray(pointer, count);
  if (raw === null) {
    return null;
  }
  return new Uint8Array(raw);
}

function hexDump(pointer, length, limit) {
  const bytes = readBytes(pointer, length, limit || 1024);
  if (!bytes) {
    return `${pointer} <unreadable>`;
  }
  const suffix = length > bytes.length ? ` ... (${length} bytes)` : ` (${length} bytes)`;
  return `${bytesToHex(bytes)}${suffix} ascii=${bytesToAscii(bytes)}`;
}

function nsDataInfo(objPtr, limit) {
  if (!ObjC.available || objPtr.isNull()) {
    return '<no-nsdata>';
  }
  return safe(() => {
    const obj = new ObjC.Object(objPtr);
    const cls = obj.$className || '';
    const length = Number(obj.length());
    const bytes = obj.bytes();
    return `${cls} len=${length} hex=${hexDump(bytes, length, limit || 1024)}`;
  }, safe(() => {
    const obj = new ObjC.Object(objPtr);
    return `${obj.$className || ''}: ${obj.toString()}`;
  }, `<nsdata-error ptr=${objPtr}>`));
}

function nsDataLength(objPtr) {
  if (!ObjC.available || objPtr.isNull()) {
    return -1;
  }
  return safe(() => Number(new ObjC.Object(objPtr).length()), -1);
}

function objSummary(objPtr) {
  if (!ObjC.available || objPtr.isNull()) {
    return `${objPtr}`;
  }
  return safe(() => {
    const obj = new ObjC.Object(objPtr);
    return `${obj.$className || ''}: ${obj.toString()}`;
  }, `${objPtr}`);
}

function characteristicSummary(charPtr) {
  if (!ObjC.available || charPtr.isNull()) {
    return `${charPtr}`;
  }
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

function logBacktrace(label, context, depth) {
  const trace = safe(() => Thread.backtrace(context, Backtracer.ACCURATE)
    .slice(0, depth || 12)
    .map(address => `    ${DebugSymbol.fromAddress(address).toString()}`)
    .join('\n'), '');
  if (trace.length > 0) {
    log(`${label} backtrace:\n${trace}`);
  }
}

function hookObjCMethod(className, selector, handler) {
  if (!ObjC.available) {
    return;
  }
  const cls = ObjC.classes[className];
  if (!cls || !cls[selector]) {
    return;
  }
  const key = `${className} ${selector}`;
  if (STATE.hooked.has(key)) {
    return;
  }
  STATE.hooked.add(key);
  Interceptor.attach(cls[selector].implementation, handler);
  log(`HOOK ObjC ${key}`);
}

function hookCoreBluetooth() {
  hookObjCMethod('CBPeripheral', '- writeValue:forCharacteristic:type:', {
    onEnter(args) {
      const characteristic = characteristicSummary(args[3]);
      const length = nsDataLength(args[2]);
      log(`CB WRITE characteristic=${characteristic} type=${safe(() => args[4].toInt32(), '?')} ${nsDataInfo(args[2], 768)}`);
      if (characteristic.indexOf('005F') >= 0 || characteristic.indexOf('005E') >= 0 || length >= 24) {
        logBacktrace(`CB WRITE ${characteristic} len=${length}`, this.context, 10);
      }
    }
  });
}

function hookCBDelegateNotifications() {
  if (!ObjC.available) {
    return;
  }
  const selector = '- peripheral:didUpdateValueForCharacteristic:error:';
  const classTerms = /HCW|MIW|MiWear|MHBle|Ble|Bluetooth|Central|Peripheral/i;
  Object.keys(ObjC.classes).forEach(className => {
    if (!classTerms.test(className)) {
      return;
    }
    const cls = ObjC.classes[className];
    const method = safe(() => cls[selector], null);
    if (!method) {
      return;
    }
    const key = `${className} ${selector}`;
    if (STATE.hooked.has(key)) {
      return;
    }
    STATE.hooked.add(key);
    try {
      Interceptor.attach(method.implementation, {
        onEnter(args) {
          const characteristic = characteristicSummary(args[3]);
          if (characteristic.indexOf('005E') < 0 && characteristic.indexOf('005F') < 0) {
            return;
          }
          const value = safe(() => new ObjC.Object(args[3]).value(), null);
          const valuePtr = value && value.handle ? value.handle : (value || ptr('0'));
          log(`CB NOTIFY ${className} characteristic=${characteristic} ${nsDataInfo(valuePtr, 768)}`);
        }
      });
      log(`HOOK ObjC delegate ${key}`);
    } catch (error) {
      log(`SKIP ObjC delegate ${key}: ${error}`);
    }
  });
}

function hookHotspotConfiguration() {
  hookObjCMethod('NEHotspotConfigurationManager', '- applyConfiguration:completionHandler:', {
    onEnter(args) {
      log(`HOTSPOT applyConfiguration ${objSummary(args[2])}`);
      logBacktrace('HOTSPOT applyConfiguration', this.context, 14);
    }
  });

  hookObjCMethod('NEHotspotConfiguration', '- initWithSSID:passphrase:isWEP:', {
    onEnter(args) {
      log(`HOTSPOT config ssid=${objSummary(args[2])} passphrase=${objSummary(args[3])}`);
    }
  });
}

function maybeLength(value) {
  const number = value.toUInt32();
  if (number > 0 && number <= 4096) {
    return number;
  }
  return -1;
}

function logFlowData(label, args, context) {
  const x5Length = maybeLength(args[5]);
  const x7Length = maybeLength(args[7]);
  log(`${label} regs x0=${args[0]} x1=${args[1]} x2=${args[2]} x3=${args[3]} x4=${args[4]} x5=${args[5]} x6=${args[6]} x7=${args[7]}`);

  if (x5Length > 0) {
    log(`${label} arg-x3/x5 ${hexDump(args[3], x5Length, 512)}`);
  }
  if (x7Length > 0 && x7Length !== x5Length) {
    log(`${label} arg-x3/x7 ${hexDump(args[3], x7Length, 512)}`);
  }
  log(`${label} arg-x3/window ${hexDump(args[3], 128, 128)}`);
}

function hookFlowSymbols() {
  const module = Process.enumerateModules().find(item => item.name.indexOf('MIWBTCore') >= 0 || (item.path || '').indexOf('MIWBTCore') >= 0);
  if (!module) {
    log('MIWBTCore module not found');
    return;
  }
  const symbols = safe(() => Module.enumerateSymbolsSync(module.name), []);
  log(`MIWBTCore symbol count=${symbols.length} module=${module.name} base=${module.base}`);

  FLOW_SYMBOLS.forEach(([name, label]) => {
    const symbol = symbols.find(item => item.name === name);
    if (!symbol || !symbol.address) {
      log(`MISS Flow ${label} ${name}`);
      return;
    }
    const key = `flow:${name}`;
    if (STATE.hooked.has(key)) {
      return;
    }
    STATE.hooked.add(key);
    Interceptor.attach(symbol.address, {
      onEnter(args) {
        this.label = label;
        log(`FLOW ENTER ${label} addr=${symbol.address}`);
        logFlowData(`FLOW ${label}`, args, this.context);
        logBacktrace(`FLOW ${label}`, this.context, 10);
      },
      onLeave(retval) {
        log(`FLOW LEAVE ${this.label} ret=${retval} x0=${this.context.x0} x1=${this.context.x1} x2=${this.context.x2} x3=${this.context.x3}`);
      }
    });
    log(`HOOK Flow ${label} ${symbol.name}`);
  });
}

function install() {
  if (!ObjC.available) {
    log('ObjC runtime is not available');
    return;
  }
  log('Installing BFA7 iOS Xiaomi FLOW hooks');
  hookCoreBluetooth();
  hookHotspotConfiguration();
  hookFlowSymbols();
  hookCBDelegateNotifications();
  log(`Installed flow hooks=${STATE.hooked.size}`);
}

setImmediate(install);

rpc.exports = {
  ping() {
    return `flow hooks=${STATE.hooked.size}`;
  }
};
