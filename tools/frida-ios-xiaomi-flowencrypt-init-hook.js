/*
 * BFA7 / Xiaomi Glasses iOS MIWFlowEncrypt init hook.
 *
 * Narrow hook for the autonomous-import stage:
 * - attaches only to MIWFlowEncrypt(appKey:appIV:deviceKey:deviceIV:)
 * - logs the four Swift Data arguments and a short backtrace
 * - avoids encrypt/decrypt hooks, broad delegate hooks, and periodic heap scans
 *
 * Run:
 *   py -3.12 -m frida_tools.repl -H 127.0.0.1:27042 -p <PID> -l frida-ios-xiaomi-flowencrypt-init-hook.js | Tee-Object <log>
 */

'use strict';

const STATE = { hooked: new Set() };

function now() { return new Date().toISOString(); }
function log(message) { console.log(`[BFA7-iOS-FLOWINIT ${now()}] ${message}`); }
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
function dumpPointer(pointer, length, limit) {
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
function logCandidate(label, pointer, length) {
  if (!pointer || pointer.isNull() || length <= 0 || length > 4096) return;
  log(`${label} ptr=${pointer} len=${length} ${dumpPointer(pointer, length, 256)}`);
}
function logSwiftData(label, word0, word1) {
  const count = pointerHigh32(word0);
  const inline = pointerLowBytes(word0, 8).concat(pointerLowBytes(word1, 8));
  log(`${label} swiftData w0=${word0} w1=${word1} inline=${bytesToHex(inline)} ascii=${bytesToAscii(inline)} count-hi32=${count}`);

  if (count <= 0 || count > 4096) return;
  const tagged = stripSwiftPointerTag(word1);
  logCandidate(`${label} tagged`, tagged, count);
  [0, 8, 16, 24, 32].forEach(offset => {
    const slot = tagged.add(offset);
    if (!rangeReadable(slot)) return;
    const candidate = safe(() => Memory.readPointer(slot), ptr('0'));
    if (candidate && !candidate.isNull() && rangeReadable(candidate)) {
      logCandidate(`${label} slot+${offset}`, candidate, count);
    }
  });
}
function logBacktrace(label, context) {
  const trace = safe(() => Thread.backtrace(context, Backtracer.ACCURATE)
    .slice(0, 14)
    .map(address => `    ${DebugSymbol.fromAddress(address).toString()}`)
    .join('\n'), '');
  if (trace.length > 0) log(`${label} backtrace:\n${trace}`);
}
function shouldHookInit(symbolName) {
  if (symbolName.indexOf('MIWFlowEncrypt') < 0) return false;
  if (symbolName.indexOf('C6appKey0D2IV06deviceE00gF0AC10Foundation4DataVSg_A3Ktc') < 0) return false;
  return symbolName.endsWith('c') || symbolName.endsWith('C');
}
function hookSymbol(module, symbol) {
  const key = `${module.name}:${symbol.address}`;
  if (STATE.hooked.has(key)) return;
  STATE.hooked.add(key);
  Interceptor.attach(symbol.address, {
    onEnter(args) {
      log(`ENTER MIWFlowEncrypt.init symbol=${symbol.name} addr=${symbol.address}`);
      logSwiftData('ARG appKey', args[0], args[1]);
      logSwiftData('ARG appIV', args[2], args[3]);
      logSwiftData('ARG deviceKey', args[4], args[5]);
      logSwiftData('ARG deviceIV', args[6], args[7]);
      log(`ARG regs x0=${args[0]} x1=${args[1]} x2=${args[2]} x3=${args[3]} x4=${args[4]} x5=${args[5]} x6=${args[6]} x7=${args[7]}`);
      logBacktrace('MIWFlowEncrypt.init', this.context);
    },
    onLeave(retval) {
      log(`LEAVE MIWFlowEncrypt.init retval=${retval}`);
    }
  });
  log(`HOOK MIWFlowEncrypt.init ${symbol.address} ${symbol.name}`);
}
function install() {
  log('Installing narrow MIWFlowEncrypt init hook');
  const modules = Process.enumerateModules().filter(module =>
    module.name.indexOf('MIWBTCore') >= 0 || (module.path || '').indexOf('MIWBTCore') >= 0
  );
  if (modules.length === 0) {
    log('MIWBTCore module not found; open Xiaomi Glasses first, then attach again');
    return;
  }
  modules.forEach(module => {
    const symbols = safe(() => Module.enumerateSymbolsSync(module.name), []);
    let matched = 0;
    symbols.forEach(symbol => {
      const name = symbol.name || '';
      if (!shouldHookInit(name)) return;
      matched += 1;
      hookSymbol(module, symbol);
    });
    log(`SCAN module=${module.name} matched-init-symbols=${matched}`);
  });
  log(`Installed init hooks=${STATE.hooked.size}`);
}

setImmediate(install);

rpc.exports = {
  ping() { return `flow-init hooks=${STATE.hooked.size}`; }
};
