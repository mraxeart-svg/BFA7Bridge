/*
 * BFA7 / Xiaomi Glasses iOS MIWBTSession.setEncrypt hook.
 *
 * Use this when MIWFlowEncrypt.init has already happened before attach.
 * The hook is intentionally narrow:
 * - discovers MIWFlowEncrypt field offsets
 * - hooks only MIWBTSession.setEncrypt-like symbols
 * - dumps likely MIWFlowEncrypt objects passed through registers
 *
 * Run:
 *   py -3.12 -m frida_tools.repl -H 127.0.0.1:27042 -p <PID> -l frida-ios-xiaomi-session-encrypt-hook.js | Tee-Object <log>
 */

'use strict';

const STATE = {
  hooked: new Set(),
  fieldOffsets: {}
};

function now() { return new Date().toISOString(); }
function log(message) { console.log(`[BFA7-iOS-SESSIONENC ${now()}] ${message}`); }
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
    const value = bytes[i];
    out += value >= 0x20 && value <= 0x7e ? String.fromCharCode(value) : '.';
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
  const count = Math.min(length, limit || 256);
  const raw = Memory.readByteArray(pointer, count);
  return raw === null ? null : new Uint8Array(raw);
}
function dumpBytes(pointer, length, limit) {
  const bytes = readBytes(pointer, length, limit || 256);
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
function stripSwiftPointerTag(pointer) {
  return safe(() => pointer.and(ptr('0x0000ffffffffffff')), ptr('0'));
}
function logBacktrace(label, context) {
  const trace = safe(() => Thread.backtrace(context, Backtracer.ACCURATE)
    .slice(0, 16)
    .map(address => `    ${DebugSymbol.fromAddress(address).toString()}`)
    .join('\n'), '');
  if (trace.length > 0) log(`${label} backtrace:\n${trace}`);
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
  if (count <= 0 || count > 4096) return;
  const tagged = stripSwiftPointerTag(w1);
  if (rangeReadable(tagged)) log(`${label} tagged=${tagged} len=${count} ${dumpBytes(tagged, count, 256)}`);
  [0, 8, 16, 24, 32].forEach(offset => {
    const slot = tagged.add(offset);
    if (!rangeReadable(slot)) return;
    const candidate = safe(() => Memory.readPointer(slot), ptr('0'));
    if (candidate && !candidate.isNull() && rangeReadable(candidate)) {
      log(`${label} slot+${offset}=${candidate} len=${count} ${dumpBytes(candidate, count, 256)}`);
    }
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
function discoverFieldOffsets(module, symbols) {
  symbols.forEach(symbol => {
    const name = symbol.name || '';
    const field = fieldNameFromSymbol(name);
    if (!field || !symbol.address || symbol.address.isNull() || !rangeReadable(symbol.address)) return;
    const u32 = safe(() => Memory.readU32(symbol.address), null);
    const s32 = safe(() => Memory.readS32(symbol.address), null);
    const p = safe(() => Memory.readPointer(symbol.address), ptr('0'));
    if (typeof u32 === 'number') STATE.fieldOffsets[field] = u32;
    log(`FIELD-OFFSET ${field} symbol=${symbol.address} u32=${u32} s32=${s32} ptr=${p}`);
  });
}
function dumpPossibleEncryptObject(label, pointer) {
  if (!rangeReadable(pointer)) return;
  log(`${label} object=${pointer} memory=${dumpBytes(pointer, 192, 192)}`);
  Object.keys(STATE.fieldOffsets).forEach(field => {
    const offset = STATE.fieldOffsets[field];
    if (typeof offset !== 'number' || offset <= 0 || offset > 512) return;
    logSwiftDataAt(`${label}.${field} offset=${offset}`, pointer.add(offset));
  });
}
function shouldHookSetEncrypt(name) {
  return /MIWBTSession/.test(name) && /setEncrypt|C10setEncrypt/.test(name);
}
function hookSetEncrypt(module, symbol) {
  if (!symbol.address) return;
  const key = `${module.name}:${symbol.address}`;
  if (STATE.hooked.has(key)) return;
  STATE.hooked.add(key);
  Interceptor.attach(symbol.address, {
    onEnter(args) {
      log(`ENTER MIWBTSession.setEncrypt symbol=${symbol.name} addr=${symbol.address}`);
      log(`REGS x0=${args[0]} x1=${args[1]} x2=${args[2]} x3=${args[3]} x4=${args[4]} x5=${args[5]} x6=${args[6]} x7=${args[7]}`);
      for (let i = 0; i < 8; i += 1) dumpPossibleEncryptObject(`ARG x${i}`, args[i]);
      logBacktrace('MIWBTSession.setEncrypt', this.context);
    },
    onLeave(retval) {
      log(`LEAVE MIWBTSession.setEncrypt retval=${retval}`);
    }
  });
  log(`HOOK MIWBTSession.setEncrypt ${symbol.address} ${symbol.name}`);
}
function install() {
  log('Installing narrow MIWBTSession.setEncrypt hook');
  const modules = Process.enumerateModules().filter(module =>
    module.name.indexOf('MIWBTCore') >= 0 || (module.path || '').indexOf('MIWBTCore') >= 0
  );
  if (modules.length === 0) {
    log('MIWBTCore module not found; open Xiaomi Glasses first, then attach again');
    return;
  }
  modules.forEach(module => {
    const symbols = safe(() => Module.enumerateSymbolsSync(module.name), []);
    log(`MIWBTCore symbol count=${symbols.length} module=${module.name} base=${module.base} path=${module.path}`);
    let discovered = 0;
    symbols.forEach(symbol => {
      const name = symbol.name || '';
      if (/MIWBTSession|MIWFlowEncrypt/.test(name)) {
        if (discovered < 160) log(`DISCOVER ${symbol.address} ${name}`);
        discovered += 1;
      }
    });
    log(`DISCOVER matched=${discovered}`);
    discoverFieldOffsets(module, symbols);
    symbols.forEach(symbol => {
      if (shouldHookSetEncrypt(symbol.name || '')) hookSetEncrypt(module, symbol);
    });
  });
  log(`Installed session-encrypt hooks=${STATE.hooked.size}`);
}

setImmediate(install);

rpc.exports = {
  ping() { return `session-encrypt hooks=${STATE.hooked.size}`; }
};
