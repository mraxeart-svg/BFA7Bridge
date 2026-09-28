/*
 * Extracts the permanent MIWear pairing token from Xiaomi Glasses on iOS.
 *
 * This deliberately avoids broad module scanning and crypto hooks. It observes
 * only MIWBTPeripheralConfig and prints a copy-ready PAIRING_TOKEN_HEX line.
 * Run it after the official app has connected to the glasses:
 *
 *   py -3.12 -m frida_tools.repl -H 127.0.0.1:27042 -p <PID> \
 *     -l frida-ios-xiaomi-pairing-token-hook.js
 */

'use strict';

const PREFIX = 'BFA7-iOS-TOKEN';
const CONFIG_CLASS_TERM = 'MIWBTPeripheralConfig';
const SYMBOLS = {
  init: '$s9MIWBTCore21MIWBTPeripheralConfigC5token9phoneIdenACSS_SStcfC',
  allocatingInit: '$s9MIWBTCore21MIWBTPeripheralConfigC5token9phoneIdenACSS_SStcfc',
  tokenGetter: '$s9MIWBTCore21MIWBTPeripheralConfigC5tokenSSvg',
  tokenSetter: '$s9MIWBTCore21MIWBTPeripheralConfigC5tokenSSvs',
  updateConfig: '$s9MIWBTCore15MIWBTPeripheralC22updatePeripheralConfig6configyAA0bE0C_tF',
  tokenOffset: '$s9MIWBTCore21MIWBTPeripheralConfigC5tokenSSvpWvd',
  phoneOffset: '$s9MIWBTCore21MIWBTPeripheralConfigC9phoneIdenSSvpWvd'
};

const STATE = {
  hooks: new Set(),
  offsets: { token: null, phoneIden: null },
  emitted: new Set(),
  scans: 0
};

function now() { return new Date().toISOString(); }
function log(message) { console.log(`[${PREFIX} ${now()}] ${message}`); }
function safe(fn, fallback) {
  try { return fn(); } catch (_) { return fallback; }
}

function readable(address) {
  if (!address || address.isNull()) return false;
  const range = Process.findRangeByAddress(address);
  return !!range && range.protection.indexOf('r') >= 0;
}

function wordBytes(word) {
  let value = word;
  const bytes = [];
  for (let i = 0; i < Process.pointerSize; i += 1) {
    bytes.push(value.and(ptr('0xff')).toUInt32());
    value = value.shr(8);
  }
  return bytes;
}

function bytesText(bytes, count) {
  const length = Math.min(count === undefined ? bytes.length : count, bytes.length);
  let text = '';
  for (let i = 0; i < length; i += 1) {
    const value = bytes[i];
    if (value === 0) break;
    if (value < 0x20 || value > 0x7e) return null;
    text += String.fromCharCode(value);
  }
  return text.length > 0 ? text : null;
}

function cleanString(value) {
  if (!value) return null;
  const nul = value.indexOf('\0');
  const text = (nul >= 0 ? value.slice(0, nul) : value).trim();
  if (text.length < 4 || text.length > 512) return null;
  for (let i = 0; i < text.length; i += 1) {
    const code = text.charCodeAt(i);
    if (code < 0x20 || code > 0x7e) return null;
  }
  return text;
}

function pointerVariants(value) {
  const variants = [];
  const masks = [
    '0x0000ffffffffffff',
    '0x00ffffffffffffff',
    '0x0fffffffffffffff',
    '0x7fffffffffffffff'
  ];
  function add(candidate) {
    if (!candidate || candidate.isNull() || !readable(candidate)) return;
    if (!variants.some(existing => existing.equals(candidate))) variants.push(candidate);
  }
  add(value);
  masks.forEach(mask => add(safe(() => value.and(ptr(mask)), ptr('0'))));
  return variants;
}

function stringsNearPointer(value) {
  const found = [];
  function add(text) {
    const clean = cleanString(text);
    if (clean && found.indexOf(clean) < 0) found.push(clean);
  }

  pointerVariants(value).forEach(base => {
    add(safe(() => Memory.readUtf8String(base, 256), null));
    [8, 16, 24, 32, 40, 48, 56, 64].forEach(offset => {
      add(safe(() => Memory.readUtf8String(base.add(offset), 256), null));
      const indirect = safe(() => Memory.readPointer(base.add(offset)), ptr('0'));
      pointerVariants(indirect).forEach(pointer => {
        add(safe(() => Memory.readUtf8String(pointer, 256), null));
      });
    });

    if (ObjC.available) {
      add(safe(() => new ObjC.Object(base).toString(), null));
    }
  });
  return found;
}

function decodeSwiftString(first, second) {
  const found = [];
  function add(text) {
    const clean = cleanString(text);
    if (clean && found.indexOf(clean) < 0) found.push(clean);
  }

  const inline = wordBytes(first).concat(wordBytes(second));
  const discriminator = inline[15];
  if ((discriminator & 0xf0) === 0xe0) {
    add(bytesText(inline, discriminator & 0x0f));
  }
  add(bytesText(inline, 15));
  stringsNearPointer(second).forEach(add);
  stringsNearPointer(first).forEach(add);
  return found;
}

function compactHex(text) {
  const compact = text.replace(/[\s:\-]/g, '');
  return compact.length >= 16 && compact.length <= 256 &&
    compact.length % 2 === 0 && /^[0-9a-fA-F]+$/.test(compact)
    ? compact.toUpperCase()
    : null;
}

function emitCandidate(label, text) {
  const clean = cleanString(text);
  if (!clean) return;
  const key = `${label}:${clean}`;
  if (STATE.emitted.has(key)) return;
  STATE.emitted.add(key);
  log(`${label}=${JSON.stringify(clean)}`);
  const hex = compactHex(clean);
  if (hex) {
    log(`PAIRING_TOKEN_HEX=${hex}`);
    log('Copy PAIRING_TOKEN_HEX into BFA7 Import 15; Frida is not needed after the token is saved.');
  }
}

function inspectStringPair(label, first, second) {
  const values = decodeSwiftString(first, second);
  log(`${label} raw0=${first} raw1=${second} decoded=${values.length}`);
  values.forEach(value => emitCandidate(label, value));
}

function inspectConfig(address, reason) {
  if (!readable(address)) return;
  log(`CONFIG reason=${reason} address=${address}`);

  if (STATE.offsets.token !== null) {
    const field = address.add(STATE.offsets.token);
    const first = safe(() => Memory.readPointer(field), ptr('0'));
    const second = safe(() => Memory.readPointer(field.add(Process.pointerSize)), ptr('0'));
    inspectStringPair('token-field', first, second);
  }
  if (STATE.offsets.phoneIden !== null) {
    const field = address.add(STATE.offsets.phoneIden);
    const first = safe(() => Memory.readPointer(field), ptr('0'));
    const second = safe(() => Memory.readPointer(field.add(Process.pointerSize)), ptr('0'));
    inspectStringPair('phoneIden-field', first, second);
  }

  // Offset globals should normally give the exact locations. These fallback
  // pairs keep the probe useful if symbols are stripped in a later app build.
  if (STATE.offsets.token === null) {
    for (let offset = 8; offset <= 80; offset += Process.pointerSize) {
      const first = safe(() => Memory.readPointer(address.add(offset)), ptr('0'));
      const second = safe(() => Memory.readPointer(address.add(offset + Process.pointerSize)), ptr('0'));
      decodeSwiftString(first, second).forEach(value => {
        if (compactHex(value)) emitCandidate(`config+${offset}`, value);
      });
    }
  }
}

function exactSymbol(symbols, name) {
  return symbols.find(symbol => symbol.name === name || symbol.name === `_${name}`) || null;
}

function attachOnce(name, symbol, callbacks) {
  if (!symbol || STATE.hooks.has(name)) return;
  Interceptor.attach(symbol.address, callbacks);
  STATE.hooks.add(name);
  log(`HOOK ${name} ${symbol.address} ${symbol.name}`);
}

function discoverSymbols() {
  const module = Process.enumerateModules().find(item => item.name.indexOf('MIWBTCore') >= 0);
  if (!module) {
    log('MIWBTCore module is not loaded yet');
    return false;
  }
  const symbols = safe(() => Module.enumerateSymbolsSync(module.name), []);
  log(`MIWBTCore module=${module.name} base=${module.base} symbols=${symbols.length}`);

  [['token', SYMBOLS.tokenOffset], ['phoneIden', SYMBOLS.phoneOffset]].forEach(entry => {
    const symbol = exactSymbol(symbols, entry[1]);
    const offset = symbol ? safe(() => Memory.readU32(symbol.address), null) : null;
    if (offset !== null && offset >= 8 && offset <= 512) {
      STATE.offsets[entry[0]] = offset;
      log(`FIELD-OFFSET ${entry[0]}=${offset} symbol=${symbol.address}`);
    } else {
      log(`FIELD-OFFSET ${entry[0]} unavailable`);
    }
  });

  attachOnce('config-init', exactSymbol(symbols, SYMBOLS.init), {
    onEnter(args) {
      inspectStringPair('init-token', args[0], args[1]);
      inspectStringPair('init-phoneIden', args[2], args[3]);
    },
    onLeave(retval) { inspectConfig(retval, 'config-init-return'); }
  });

  attachOnce('config-allocating-init', exactSymbol(symbols, SYMBOLS.allocatingInit), {
    onEnter(args) {
      inspectStringPair('alloc-init-token', args[0], args[1]);
      inspectStringPair('alloc-init-phoneIden', args[2], args[3]);
    },
    onLeave(retval) { inspectConfig(retval, 'config-allocating-init-return'); }
  });

  attachOnce('token-getter', exactSymbol(symbols, SYMBOLS.tokenGetter), {
    onLeave(retval) { inspectStringPair('token-getter', retval, this.context.x1); }
  });

  attachOnce('token-setter', exactSymbol(symbols, SYMBOLS.tokenSetter), {
    onEnter(args) { inspectStringPair('token-setter', args[0], args[1]); }
  });

  attachOnce('update-config', exactSymbol(symbols, SYMBOLS.updateConfig), {
    onEnter(args) {
      inspectConfig(args[0], 'update-config-x0');
      inspectConfig(this.context.x20, 'update-config-x20');
    }
  });
  return true;
}

function scanExistingInstances(reason) {
  if (!ObjC.available) return;
  STATE.scans += 1;
  const classNames = Object.keys(ObjC.classes).filter(name => name.indexOf(CONFIG_CLASS_TERM) >= 0);
  log(`INSTANCE-SCAN #${STATE.scans} reason=${reason} classes=${classNames.join(',') || '<none>'}`);
  classNames.forEach(className => {
    const klass = ObjC.classes[className];
    let count = 0;
    safe(() => ObjC.choose(klass, {
      onMatch(instance) {
        count += 1;
        inspectConfig(instance.handle, `existing-${className}`);
      },
      onComplete() { log(`INSTANCE-SCAN class=${className} instances=${count}`); }
    }), null);
  });
}

function install() {
  log('Installing narrow MIWBT pairing-token hook');
  if (!discoverSymbols()) {
    setTimeout(install, 1000);
    return;
  }
  scanExistingInstances('startup');
  setTimeout(() => scanExistingInstances('after-2s'), 2000);
  setTimeout(() => scanExistingInstances('after-8s'), 8000);
  log(`Installed hooks=${STATE.hooks.size}`);
}

setImmediate(install);

rpc.exports = {
  scan() {
    scanExistingInstances('rpc');
    return `hooks=${STATE.hooks.size} scans=${STATE.scans}`;
  },
  status() {
    return JSON.stringify({ hooks: STATE.hooks.size, offsets: STATE.offsets, scans: STATE.scans });
  }
};
