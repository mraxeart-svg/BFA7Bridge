/*
 * BFA7 / Xiaomi Glasses iOS Import hook.
 *
 * Goal:
 * - Hook official iOS app com.xiaomi.superhexa on a jailbroken iPhone.
 * - Capture CoreBluetooth writes made by Xiaomi app during Import.
 * - Log FE95/005E/005F traffic and MIWBT/MIWear high-signal Swift symbols.
 *
 * Run from Windows/macOS/Linux with Frida tools:
 *   frida -U -f com.xiaomi.superhexa -l tools/frida-ios-xiaomi-import-hook.js
 *
 * In the Frida prompt, type `%resume`, then trigger Import in Xiaomi Glasses.
 */

'use strict';

const STATE = {
  hooked: new Set(),
  symbolHookCount: 0,
  maxSymbolHooks: 360
};

function now() {
  return new Date().toISOString();
}

function log(message) {
  console.log(`[BFA7-iOS ${now()}] ${message}`);
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
  const count = Math.min(length, limit || 512);
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
    if (cls.indexOf('Data') < 0 && cls.indexOf('NSData') < 0 && !obj.respondsToSelector_('bytes')) {
      return `${cls}: ${obj.toString()}`;
    }
    const length = Number(obj.length());
    const bytes = obj.bytes();
    return `${cls} len=${length} hex=${readBytes(bytes, length, limit || 512)}`;
  }, '<nsdata-error>');
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

function nsDataLength(objPtr) {
  if (!ObjC.available || objPtr.isNull()) {
    return -1;
  }
  return safe(() => {
    const obj = new ObjC.Object(objPtr);
    if (!obj.respondsToSelector_('length') || !obj.respondsToSelector_('bytes')) {
      return -1;
    }
    return Number(obj.length());
  }, -1);
}

function logBacktrace(label, context) {
  const trace = safe(() => Thread.backtrace(context, Backtracer.ACCURATE)
    .slice(0, 18)
    .map(address => `    ${DebugSymbol.fromAddress(address).toString()}`)
    .join('\n'), '');
  if (trace.length > 0) {
    log(`${label} backtrace:\n${trace}`);
  }
}

function pointerLooksReadable(address) {
  return safe(() => {
    if (address.isNull()) {
      return false;
    }
    const range = Process.findRangeByAddress(address);
    return !!range && range.protection.indexOf('r') >= 0;
  }, false);
}

function maybeDumpDataArg(label, argPtr, limit) {
  if (!ObjC.available || argPtr.isNull()) {
    return;
  }
  const nsInfo = safe(() => {
    const obj = new ObjC.Object(argPtr);
    if (obj.respondsToSelector_('length') && obj.respondsToSelector_('bytes')) {
      const length = Number(obj.length());
      if (length > 0 && length <= 4096) {
        return nsDataInfo(argPtr, limit || 384);
      }
    }
    return null;
  }, null);
  if (nsInfo) {
    log(`${label} ${nsInfo}`);
    return;
  }

  if (pointerLooksReadable(argPtr)) {
    const raw = safe(() => readBytes(argPtr, 64, 64), '');
    if (raw.length > 0) {
      log(`${label} raw64=${raw}`);
    }
  }
}

function dumpPotentialArgs(prefix, args, count) {
  for (let index = 0; index < count; index += 1) {
    maybeDumpDataArg(`${prefix} arg${index}=${args[index]}`, args[index], 384);
  }
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

function hookCoreBluetoothWrites() {
  hookObjCMethod('CBPeripheral', '- writeValue:forCharacteristic:type:', {
    onEnter(args) {
      const dataInfo = nsDataInfo(args[2], 1024);
      const characteristic = characteristicSummary(args[3]);
      const writeType = safe(() => args[4].toInt32(), '?');
      log(`CB WRITE characteristic=${characteristic} type=${writeType} ${dataInfo}`);
      const length = nsDataLength(args[2]);
      if (characteristic.indexOf('005F') >= 0 || characteristic.indexOf('005E') >= 0 || length >= 24) {
        logBacktrace(`CB WRITE ${characteristic} len=${length}`, this.context);
      }
    }
  });

  hookObjCMethod('CBPeripheral', '- setNotifyValue:forCharacteristic:', {
    onEnter(args) {
      const enabled = safe(() => args[2].toInt32(), '?');
      const characteristic = characteristicSummary(args[3]);
      log(`CB NOTIFY SET enabled=${enabled} characteristic=${characteristic}`);
    }
  });

  hookObjCMethod('CBPeripheral', '- readValueForCharacteristic:', {
    onEnter(args) {
      const characteristic = characteristicSummary(args[2]);
      log(`CB READ characteristic=${characteristic}`);
    }
  });
}

function hookCBDelegateNotifications() {
  if (!ObjC.available) {
    return;
  }
  const selectors = [
    '- peripheral:didUpdateValueForCharacteristic:error:',
    '- peripheral:didWriteValueForCharacteristic:error:',
    '- peripheral:didDiscoverCharacteristicsForService:error:'
  ];
  const classTerms = /HCW|MIW|MiWear|MHBle|Ble|Bluetooth/i;

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
              log(`CB NOTIFY ${className} characteristic=${characteristic} ${nsDataInfo(valuePtr, 512)}`);
            } else if (selector.indexOf('didWriteValueForCharacteristic') >= 0) {
              log(`CB WRITE ACK ${className} characteristic=${characteristicSummary(args[3])} error=${objSummary(args[4])}`);
            } else {
              log(`CB DISCOVER ${className} service=${objSummary(args[3])} error=${objSummary(args[4])}`);
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
    }
  });

  ['- initWithSSID:', '- initWithSSID:passphrase:isWEP:', '- initWithSSID:passphrase:isWEP:'].forEach(selector => {
    hookObjCMethod('NEHotspotConfiguration', selector, {
      onEnter(args) {
        log(`HOTSPOT config ${selector} ssid=${objSummary(args[2])} passphrase=${args[3] ? objSummary(args[3]) : '<none>'}`);
      }
    });
  });
}

function enumerateSymbols(moduleName) {
  return safe(() => {
    if (Module.enumerateSymbolsSync) {
      return Module.enumerateSymbolsSync(moduleName);
    }
    return Module.enumerateSymbols(moduleName);
  }, []);
}

const prioritySymbolTerms = /MIWBTReqC7timeOut7channel7package|MIWBTReqC32convertPackagetoTransmissionData|MIWBTReqC16transmissionData|MIWBTChannelC16transmissionData|MIWBTChannelC11payloadData|MIWChannelPayloadC11payloadData|MIWFlowEncryptC7encrypt|MIWFlowEncryptC7decrypt|MIWBTSessionC10setEncrypt|WearSystemV13wifiApRequest|WearWiFiAPV7RequestV9frequency|WearWiFiAPV7RequestV13SwiftProtobuf7Message|WearPacket|serializedBytes/i;

function hookSymbol(symbol, moduleName) {
  const key = `sym:${moduleName}:${symbol.name}:${symbol.address}`;
  if (STATE.hooked.has(key) || STATE.symbolHookCount >= STATE.maxSymbolHooks) {
    return;
  }
  STATE.hooked.add(key);
  STATE.symbolHookCount += 1;
  Interceptor.attach(symbol.address, {
    onEnter(args) {
      this.symbolName = symbol.name;
      this.priority = prioritySymbolTerms.test(symbol.name);
      const argText = [];
      for (let index = 0; index < 6; index += 1) {
        argText.push(`a${index}=${args[index]}`);
      }
      log(`SYM ENTER ${moduleName} ${symbol.name} ${argText.join(' ')}`);
      if (this.priority) {
        dumpPotentialArgs(`SYM DATA ${symbol.name}`, args, 6);
        logBacktrace(`SYM ${symbol.name}`, this.context);
      }
    },
    onLeave(retval) {
      log(`SYM LEAVE ${moduleName} ${this.symbolName} ret=${retval}`);
      if (this.priority) {
        maybeDumpDataArg(`SYM RET ${this.symbolName}`, retval, 384);
      }
    }
  });
  log(`HOOK symbol ${moduleName} ${symbol.name}`);
}

function hookMIWSymbols() {
  const moduleTerms = /MIWBT|MIWear|MIWWifi|HCWCompanion|Xiaomi|Super/i;
  const symbolTerms = /MIWBTReq|MIWBTChannel|MIWChannelPayload|MIWBTSession|MIWFlowEncrypt|authAppConfirmToDevice|aesCCMEncrypt|WearPacket|WearSystem|WearWiFiAP|wifiApRequest|wifiApResult|payloadData|transmissionData|serializedBytes|decodeMessage|traverse|encrypt\(data|decrypt\(data/i;

  Process.enumerateModules().forEach(module => {
    if (!moduleTerms.test(module.name) && !moduleTerms.test(module.path || '')) {
      return;
    }
    log(`SCAN module ${module.name} ${module.path}`);
    const symbols = enumerateSymbols(module.name);
    symbols.forEach(symbol => {
      if (symbol.address && prioritySymbolTerms.test(symbol.name)) {
        hookSymbol(symbol, module.name);
      }
    });
    symbols.forEach(symbol => {
      if (symbol.address && symbolTerms.test(symbol.name)) {
        hookSymbol(symbol, module.name);
      }
    });
  });
}

function dumpInterestingObjCClasses() {
  if (!ObjC.available) {
    return;
  }
  const terms = /MIW|Wear|Wifi|WiFi|Bluetooth|BT|Hotspot|Xiaomi|Super/i;
  const names = Object.keys(ObjC.classes).filter(name => terms.test(name)).sort();
  log(`Interesting ObjC classes count=${names.length}`);
  names.slice(0, 300).forEach(name => log(`  CLASS ${name}`));
}

function install() {
  if (!ObjC.available) {
    log('ObjC runtime is not available');
    return;
  }
  log('Installing BFA7 iOS Xiaomi import hooks');
  hookCoreBluetoothWrites();
  hookHotspotConfiguration();
  hookMIWSymbols();
  hookCBDelegateNotifications();
  dumpInterestingObjCClasses();
  log(`Installed hooks=${STATE.hooked.size} symbolHooks=${STATE.symbolHookCount}`);
}

setImmediate(install);

rpc.exports = {
  rescan() {
    hookMIWSymbols();
    return `hooks=${STATE.hooked.size} symbolHooks=${STATE.symbolHookCount}`;
  }
};
