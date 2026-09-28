/*
 * Minimal MIWear pairing-token probe for Xiaomi Glasses on iOS.
 *
 * This version deliberately avoids ObjC.choose(), heap scans, and stored-property
 * offset reads. It performs one filtered symbol-table pass and hooks only the
 * four exact Swift token functions.
 */

'use strict';

const PREFIX = 'BFA7-iOS-TOKEN-LITE';
const SYMBOLS = {
  init: '$s9MIWBTCore21MIWBTPeripheralConfigC5token9phoneIdenACSS_SStcfC',
  allocatingInit: '$s9MIWBTCore21MIWBTPeripheralConfigC5token9phoneIdenACSS_SStcfc',
  tokenGetter: '$s9MIWBTCore21MIWBTPeripheralConfigC5tokenSSvg',
  tokenSetter: '$s9MIWBTCore21MIWBTPeripheralConfigC5tokenSSvs'
};

const installed = new Set();
const emitted = new Set();
const resolved = new Map();

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
  for (let index = 0; index < Process.pointerSize; index += 1) {
    bytes.push(value.and(ptr('0xff')).toUInt32());
    value = value.shr(8);
  }
  return bytes;
}

function cleanString(value) {
  if (!value) return null;
  const nul = value.indexOf('\0');
  const text = (nul >= 0 ? value.slice(0, nul) : value).trim();
  if (text.length < 4 || text.length > 512) return null;
  for (let index = 0; index < text.length; index += 1) {
    const code = text.charCodeAt(index);
    if (code < 0x20 || code > 0x7e) return null;
  }
  return text;
}

function addPointerStrings(value, output) {
  if (!readable(value)) return;
  const direct = cleanString(safe(() => Memory.readUtf8String(value, 256), null));
  if (direct && output.indexOf(direct) < 0) output.push(direct);
  if (!ObjC.available) return;
  const objc = cleanString(safe(() => new ObjC.Object(value).toString(), null));
  if (objc && output.indexOf(objc) < 0) output.push(objc);
}

function decodeSwiftString(first, second) {
  const output = [];
  const inline = wordBytes(first).concat(wordBytes(second));
  const discriminator = inline[15];
  const inlineLength = (discriminator & 0xf0) === 0xe0 ? discriminator & 0x0f : 15;
  let inlineText = '';
  for (let index = 0; index < inlineLength; index += 1) {
    const value = inline[index];
    if (value === 0) break;
    if (value < 0x20 || value > 0x7e) {
      inlineText = '';
      break;
    }
    inlineText += String.fromCharCode(value);
  }
  const cleanInline = cleanString(inlineText);
  if (cleanInline) output.push(cleanInline);

  addPointerStrings(second, output);
  addPointerStrings(first, output);
  return output;
}

function compactHex(text) {
  const compact = text.replace(/[\s:\-]/g, '');
  return compact.length >= 16 && compact.length <= 256 &&
    compact.length % 2 === 0 && /^[0-9a-fA-F]+$/.test(compact)
    ? compact.toUpperCase()
    : null;
}

function inspectStringPair(label, first, second) {
  decodeSwiftString(first, second).forEach(value => {
    const key = `${label}:${value}`;
    if (emitted.has(key)) return;
    emitted.add(key);
    log(`${label}=${JSON.stringify(value)}`);
    const hex = compactHex(value);
    if (hex) {
      log(`PAIRING_TOKEN_HEX=${hex}`);
      log('Copy only the text after PAIRING_TOKEN_HEX= into BFA7 Import 15.');
    }
  });
}

function resolveTargets(module) {
  const wanted = new Map();
  Object.values(SYMBOLS).forEach(name => {
    wanted.set(name, name);
    wanted.set(`_${name}`, name);
  });

  const symbols = safe(() => Module.enumerateSymbolsSync(module.name), []);
  symbols.forEach(symbol => {
    const canonical = wanted.get(symbol.name);
    if (canonical && !resolved.has(canonical)) resolved.set(canonical, symbol.address);
  });
  log(`TARGET-SCAN symbols=${symbols.length} matched=${resolved.size}`);
}

function resolve(name) {
  const address = resolved.get(name);
  if (address && !address.isNull()) {
    return address;
  }
  return null;
}

function attach(name, symbolName, callbacks) {
  const address = resolve(symbolName);
  if (!address) {
    log(`MISS ${name}`);
    return;
  }
  const key = address.toString();
  if (installed.has(key)) return;
  Interceptor.attach(address, callbacks);
  installed.add(key);
  log(`HOOK ${name} ${address}`);
}

function install() {
  const module = Process.findModuleByName('MIWBTCore');
  if (!module) {
    log('MIWBTCore is not loaded yet; retrying');
    setTimeout(install, 1000);
    return;
  }

  log(`Installing narrow hooks in MIWBTCore base=${module.base}`);
  resolveTargets(module);
  attach('config-init', SYMBOLS.init, {
    onEnter(args) {
      inspectStringPair('init-token', args[0], args[1]);
    }
  });
  attach('config-allocating-init', SYMBOLS.allocatingInit, {
    onEnter(args) {
      inspectStringPair('alloc-init-token', args[0], args[1]);
    }
  });
  attach('token-getter', SYMBOLS.tokenGetter, {
    onLeave(retval) {
      inspectStringPair('token-getter', retval, this.context.x1);
    }
  });
  attach('token-setter', SYMBOLS.tokenSetter, {
    onEnter(args) {
      inspectStringPair('token-setter', args[0], args[1]);
    }
  });
  log(`Installed hooks=${installed.size}; reconnect the glasses inside Xiaomi Glasses if no token appears.`);
}

setImmediate(install);

rpc.exports = {
  status() {
    return JSON.stringify({ hooks: installed.size, candidates: emitted.size });
  }
};
