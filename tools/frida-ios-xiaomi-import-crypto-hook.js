/*
 * BFA7 / Xiaomi Glasses iOS Import CRYPTO hook.
 *
 * Safe mode for jailbroken iOS when broad Swift symbol hooks crash the app.
 * Captures CoreBluetooth writes/notifications, NEHotspotConfiguration calls,
 * and backtraces for FE95/005E/005F writes only.
 *
 * Run:
 *   frida -H 127.0.0.1:27042 -p <PID> -l tools/frida-ios-xiaomi-import-crypto-hook.js
 */

'use strict';

const STATE = { hooked: new Set() };

function now() {
  return new Date().toISOString();
}

function log(message) {
  console.log(`[BFA7-iOS-CRYPTO ${now()}] ${message}`);
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

function readBytes(pointer, length, limit) {
  if (pointer.isNull() || length <= 0) {
    return '';
  }
  const count = Math.min(length, limit || 1024);
  const bytes = Memory.readByteArray(pointer, count);
  if (bytes === null) {
    return '';
  }
  const view = new Uint8Array(bytes);
  const out = [];
  for (let index = 0; index < view.length; index += 1) {
    out.push(hexByte(view[index]));
  }
  const suffix = length > count ? ` ... (${length} bytes)` : ` (${length} bytes)`;
  return `${out.join(' ')}${suffix}`;
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
    return `${cls} len=${length} hex=${readBytes(bytes, length, limit || 1024)}`;
  }, safe(() => {
    const obj = new ObjC.Object(objPtr);
    const cls = obj.$className || '';
    return `${cls}: ${obj.toString()}`;
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
    return `${obj.$className}: ${obj.toString()}`;
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

function logBacktrace(label, context) {
  const trace = safe(() => Thread.backtrace(context, Backtracer.ACCURATE)
    .slice(0, 22)
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
      const writeType = safe(() => args[4].toInt32(), '?');
      const length = nsDataLength(args[2]);
      log(`CB WRITE characteristic=${characteristic} type=${writeType} ${nsDataInfo(args[2], 2048)}`);
      if (characteristic.indexOf('005F') >= 0 || characteristic.indexOf('005E') >= 0 || length >= 24) {
        logBacktrace(`CB WRITE ${characteristic} len=${length}`, this.context);
      }
    }
  });

  hookObjCMethod('CBPeripheral', '- setNotifyValue:forCharacteristic:', {
    onEnter(args) {
      log(`CB NOTIFY SET enabled=${safe(() => args[2].toInt32(), '?')} characteristic=${characteristicSummary(args[3])}`);
    }
  });

  hookObjCMethod('CBPeripheral', '- readValueForCharacteristic:', {
    onEnter(args) {
      log(`CB READ characteristic=${characteristicSummary(args[2])}`);
    }
  });
}

function hookCBDelegateNotifications() {
  if (!ObjC.available) {
    return;
  }
  const selectors = [
    '- peripheral:didUpdateValueForCharacteristic:error:',
    '- peripheral:didWriteValueForCharacteristic:error:'
  ];
  const classTerms = /HCW|MIW|MiWear|MHBle|Ble|Bluetooth|Central|Peripheral/i;

  Object.keys(ObjC.classes).forEach(className => {
    if (!classTerms.test(className)) {
      return;
    }
    const cls = ObjC.classes[className];
    selectors.forEach(selector => {
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
            if (selector.indexOf('didUpdateValueForCharacteristic') >= 0) {
              const characteristic = characteristicSummary(args[3]);
              const value = safe(() => new ObjC.Object(args[3]).value(), null);
              const valuePtr = value && value.handle ? value.handle : (value || ptr('0'));
              log(`CB NOTIFY ${className} characteristic=${characteristic} ${nsDataInfo(valuePtr, 1024)}`);
            } else {
              log(`CB WRITE ACK ${className} characteristic=${characteristicSummary(args[3])} error=${objSummary(args[4])}`);
            }
          }
        });
        log(`HOOK ObjC delegate ${key}`);
      } catch (error) {
        log(`SKIP ObjC delegate ${key}: ${error}`);
      }
    });
  });
}

function hookHotspotConfiguration() {
  hookObjCMethod('NEHotspotConfigurationManager', '- applyConfiguration:completionHandler:', {
    onEnter(args) {
      log(`HOTSPOT applyConfiguration ${objSummary(args[2])}`);
      logBacktrace('HOTSPOT applyConfiguration', this.context);
    }
  });

  ['- initWithSSID:', '- initWithSSID:passphrase:isWEP:'].forEach(selector => {
    hookObjCMethod('NEHotspotConfiguration', selector, {
      onEnter(args) {
        log(`HOTSPOT config ${selector} ssid=${objSummary(args[2])} passphrase=${args[3] ? objSummary(args[3]) : '<none>'}`);
      }
    });
  });
}


const EXACT_SWIFT_SYMBOLS = [
  ['MIWBTCore', '_$s9MIWBTCore14MIWFlowEncryptC7encrypt4data10Foundation4DataVSgAH_tF', 'MIWFlowEncrypt.encrypt(data:)'],
  ['MIWBTCore', '_$s9MIWBTCore14MIWFlowEncryptC7decrypt4data10Foundation4DataVSgAH_tF', 'MIWFlowEncrypt.decrypt(data:)'],
  ['MIWBTCore', '_$s9MIWBTCore8MIWBTReqC7timeOut7channel7packageACs5UInt8V_AA14MIWChannelTypeO8MIWearPB04WearL6PacketVSgtcfC', 'MIWBTReq.init(timeOut:channel:package:)'],
  ['MIWBTCore', '_$s9MIWBTCore8MIWBTReqC32convertPackagetoTransmissionDataAA12MIWBTRspCodeOSgyF', 'MIWBTReq.convertPackagetoTransmissionData()'],
  ['MIWBTCore', '_$s9MIWBTCore8MIWBTReqC16transmissionData4datay10Foundation0D0V_tF', 'MIWBTReq.transmissionData(data:)'],
  ['MIWBTCore', '_$s9MIWBTCore12MIWBTChannelC11payloadData10Foundation0D0VyF', 'MIWBTChannel.payloadData()'],
  ['MIWBTCore', '_$s9MIWBTCore17MIWChannelPayloadC11payloadData10Foundation0E0VSgyF', 'MIWChannelPayload.payloadData()']
];

function pointerSummary(address, limit) {
  return safe(() => {
    if (address.isNull()) {
      return `${address}`;
    }
    const range = Process.findRangeByAddress(address);
    if (!range || range.protection.indexOf('r') < 0) {
      return `${address} <unreadable>`;
    }
    return `${address} ${readBytes(address, Math.min(range.size, limit || 96), limit || 96)}`;
  }, `${address} <read-error>`);
}

function dumpRegisters(label, args, context) {
  const pieces = [];
  for (let index = 0; index < 8; index += 1) {
    pieces.push(`x${index}=${args[index]}`);
  }
  log(`${label} regs ${pieces.join(' ')}`);
  for (let index = 0; index < 4; index += 1) {
    log(`${label} mem x${index} ${pointerSummary(args[index], 96)}`);
  }
  log(`${label} sp ${pointerSummary(context.sp, 160)}`);
}

function hookExactSwiftSymbols() {
  Process.enumerateModules().forEach(module => {
    EXACT_SWIFT_SYMBOLS.forEach(([moduleNeedle, symbolName, label]) => {
      if (module.name.indexOf(moduleNeedle) < 0 && (module.path || '').indexOf(moduleNeedle) < 0) {
        return;
      }
      const key = `exact:${module.name}:${symbolName}`;
      if (STATE.hooked.has(key)) {
        return;
      }
      const symbols = safe(() => Module.enumerateSymbolsSync(module.name), []);
      const symbol = symbols.find(item => item.name === symbolName);
      if (!symbol || !symbol.address) {
        log(`MISS Swift ${label} in ${module.name}`);
        STATE.hooked.add(key);
        return;
      }
      STATE.hooked.add(key);
      Interceptor.attach(symbol.address, {
        onEnter(args) {
          this.label = label;
          log(`SWIFT ENTER ${label} addr=${symbol.address}`);
          dumpRegisters(`SWIFT ${label}`, args, this.context);
          logBacktrace(`SWIFT ${label}`, this.context);
        },
        onLeave(retval) {
          log(`SWIFT LEAVE ${this.label} ret=${retval} ${pointerSummary(retval, 96)}`);
        }
      });
      log(`HOOK Swift ${label} ${symbol.name}`);
    });
  });
}

function install() {
  if (!ObjC.available) {
    log('ObjC runtime is not available');
    return;
  }
  log('Installing BFA7 iOS Xiaomi import CRYPTO hooks');
  hookCoreBluetooth();
  hookHotspotConfiguration();
  hookExactSwiftSymbols();
  hookCBDelegateNotifications();
  log(`Installed crypto hooks=${STATE.hooked.size}`);
}

setImmediate(install);

rpc.exports = {
  ping() {
    return `crypto hooks=${STATE.hooked.size}`;
  }
};
