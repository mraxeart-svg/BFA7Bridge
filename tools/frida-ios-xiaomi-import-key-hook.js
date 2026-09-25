/*
 * BFA7 / Xiaomi Glasses iOS Import KEY hook.
 *
 * Goal: capture the session encryption material used by MIWBTCore before the
 * official app writes the AP/import command. This is narrower than the broad
 * crypto hook and is meant for the "replay failed, derive session cipher"
 * stage.
 *
 * Run:
 *   py -3.12 -m frida_tools.repl -H 127.0.0.1:27042 -p <PID> -l frida-ios-xiaomi-import-key-hook.js | Tee-Object <log>
 */

'use strict';

const STATE = { hooked: new Set() };

function now() { return new Date().toISOString(); }
function log(message) { console.log(`[BFA7-iOS-KEY ${now()}] ${message}`); }
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
function readBytes(pointer, length, limit) {
  if (pointer.isNull() || length <= 0) return null;
  const count = Math.min(length, limit || 512);
  const range = Process.findRangeByAddress(pointer);
  if (!range || range.protection.indexOf('r') < 0) return null;
  const raw = Memory.readByteArray(pointer, count);
  return raw === null ? null : new Uint8Array(raw);
}
function hexDump(pointer, length, limit) {
  const bytes = readBytes(pointer, length, limit || 512);
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
function logPointerCandidate(label, pointer, length) {
  if (pointer.isNull() || length <= 0 || length > 4096) return;
  const range = Process.findRangeByAddress(pointer);
  if (!range || range.protection.indexOf('r') < 0) {
    log(`${label} candidate=${pointer} len=${length} <unreadable-range>`);
    return;
  }
  log(`${label} candidate=${pointer} len=${length} ${hexDump(pointer, length, 512)}`);
}
function logSwiftDataWords(label, x0, x1, x2, x3) {
  const countFromX0 = pointerHigh32(x0);
  const inlineX0 = pointerLowBytes(x0, 8);
  const inlineX1 = pointerLowBytes(x1, 8);
  const taggedX1 = stripSwiftPointerTag(x1);
  log(`${label} swiftdata-inline x0-le=${bytesToHex(inlineX0)} ascii=${bytesToAscii(inlineX0)} x1-le=${bytesToHex(inlineX1)} ascii=${bytesToAscii(inlineX1)} count-hi32=${countFromX0}`);
  if (countFromX0 > 0 && countFromX0 <= 4096) {
    logPointerCandidate(`${label} swiftdata-x1-tagged`, taggedX1, countFromX0);
    logPointerCandidate(`${label} swiftdata-x1-raw`, x1, countFromX0);
    [0, 8, 16, 24, 32, 40, 48, 56].forEach(offset => {
      const slot = taggedX1.add(offset);
      const candidate = safe(() => Memory.readPointer(slot), ptr('0'));
      logPointerCandidate(`${label} swiftdata-x1-slot+${offset}`, candidate, countFromX0);
    });
  }
  if (!x2.isNull()) logPointerCandidate(`${label} x2-window`, x2, Math.min(countFromX0 > 0 ? countFromX0 : 128, 512));
  if (!x3.isNull()) logPointerCandidate(`${label} x3-window`, x3, Math.min(countFromX0 > 0 ? countFromX0 : 128, 512));
}
function logBacktrace(label, context, depth) {
  const trace = safe(() => Thread.backtrace(context, Backtracer.ACCURATE)
    .slice(0, depth || 14)
    .map(address => `    ${DebugSymbol.fromAddress(address).toString()}`)
    .join('\n'), '');
  if (trace.length > 0) log(`${label} backtrace:\n${trace}`);
}
function dumpRegsAsSwiftData(label, args, context) {
  log(`${label} regs x0=${args[0]} x1=${args[1]} x2=${args[2]} x3=${args[3]} x4=${args[4]} x5=${args[5]} x6=${args[6]} x7=${args[7]}`);
  logSwiftDataWords(`${label} data@x0/x1`, args[0], args[1], args[2], args[3]);
  logSwiftDataWords(`${label} data@x2/x3`, args[2], args[3], args[4], args[5]);
  logSwiftDataWords(`${label} data@x4/x5`, args[4], args[5], args[6], args[7]);
  logSwiftDataWords(`${label} data@x6/x7`, args[6], args[7], context.sp, ptr('0'));
  logPointerCandidate(`${label} stack`, context.sp, 256);
}
function symbolLabel(symbol) {
  const name = symbol.name || '';
  if (/MIWFlowEncrypt.*encrypt4data|MIWFlowEncryptC7encrypt/.test(name)) return 'MIWFlowEncrypt.encrypt(data:)';
  if (/MIWFlowEncrypt.*decrypt4data|MIWFlowEncryptC7decrypt/.test(name)) return 'MIWFlowEncrypt.decrypt(data:)';
  if (/MIWFlowEncrypt.*createAesContext|MIWFlowEncryptC16createAesContext/.test(name)) return 'MIWFlowEncrypt.createAesContext';
  if (/MIWFlowEncrypt.*cfC|MIWFlowEncrypt.*appKey|MIWFlowEncrypt.*device/.test(name)) return 'MIWFlowEncrypt.init/appKey/deviceKey';
  if (/MIWBTSession.*setEncrypt|MIWBTSessionC10setEncrypt/.test(name)) return 'MIWBTSession.setEncrypt';
  return name;
}
function shouldHook(symbol) {
  const name = symbol.name || '';
  if (!/MIWFlowEncrypt|MIWBTSession.*setEncrypt|MIWBTSessionC10setEncrypt/.test(name)) return false;
  return /encrypt4data|decrypt4data|C7encrypt|C7decrypt|createAesContext|C16createAesContext|cfC|appKey|deviceKey|setEncrypt|C10setEncrypt/.test(name);
}
function hookSymbol(module, symbol) {
  if (!symbol.address) return;
  const key = `${module.name}:${symbol.address}`;
  if (STATE.hooked.has(key)) return;
  STATE.hooked.add(key);
  const label = symbolLabel(symbol);
  try {
    Interceptor.attach(symbol.address, {
      onEnter(args) {
        this.label = label;
        log(`ENTER ${label} addr=${symbol.address} name=${symbol.name}`);
        dumpRegsAsSwiftData(`ARG ${label}`, args, this.context);
        logBacktrace(`ARG ${label}`, this.context, 10);
      },
      onLeave(retval) {
        log(`LEAVE ${this.label} ret=${retval} x0=${this.context.x0} x1=${this.context.x1} x2=${this.context.x2} x3=${this.context.x3}`);
        logSwiftDataWords(`RET ${this.label}`, this.context.x0, this.context.x1, this.context.x2, this.context.x3);
      }
    });
    log(`HOOK ${label} ${symbol.name}`);
  } catch (error) {
    log(`SKIP ${label} ${symbol.name}: ${error}`);
  }
}
function install() {
  log('Installing BFA7 iOS Xiaomi KEY hooks');
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
        if (discovered < 160) log(`DISCOVER ${symbol.address} ${symbol.name}`);
        discovered += 1;
      }
    });
    log(`DISCOVER matched=${discovered}`);
    symbols.forEach(symbol => {
      if (shouldHook(symbol)) hookSymbol(module, symbol);
    });
  });
  log(`Installed key hooks=${STATE.hooked.size}`);
}

setImmediate(install);

rpc.exports = {
  ping() { return `key hooks=${STATE.hooked.size}`; }
};
