/* Read only MIWBTPeripheralConfig.token; never call Swift through the C ABI.
 * ARM64 Swift String layout: swift/stdlib/public/core/StringObject.swift.
 * A candidate is a complete property, not a neighboring string or suffix.
 */
'use strict';
const VERSION = 'token-reader-3';
const SYMBOLS = {
  getter: '$s9MIWBTCore21MIWBTPeripheralConfigC5tokenSSvg',
  setter: '$s9MIWBTCore21MIWBTPeripheralConfigC5tokenSSvs',
  init: '$s9MIWBTCore21MIWBTPeripheralConfigC5token9phoneIdenACSS_SStcfc',
  peripheral: '$s9MIWBTCore15MIWBTPeripheralC16peripheralConfigAA0bD0CyF'
};
const tokens = new Map();
const stats = { objects: 0, empty: 0, unsupported: 0, unreadable: 0, decoded: 0 };
let propertyOffset = null;
let scanning = false;
let installed = 0;
function log(message) { console.log(`[BFA7-iOS-TOKEN-LITE ${new Date().toISOString()}] ${message}`); }
function bytesOf(word) {
  const output = [];
  for (let index = 0; index < 8; index++) {
    output.push(word.and(ptr('0xff')).toUInt32());
    word = word.shr(8);
  }
  return output;
}
function exactASCII(bytes) {
  if (bytes.some(value => value < 0x20 || value > 0x7e)) return null;
  return String.fromCharCode.apply(null, bytes);
}
function decodeString(first, second) {
  const words = bytesOf(first).concat(bytesOf(second));
  const tag = words[15];
  if ((tag & 0x20) !== 0) {
    const length = tag & 0x0f;
    const text = exactASCII(words.slice(0, length));
    return { kind: 'small', length, text, status: length === 0 ? 'empty' : text === null ? 'unsupported' : 'decoded' };
  }
  const count = first.and(ptr('0x0000ffffffffffff'));
  if (count.compare(ptr(256)) > 0) return { status: 'unsupported', kind: 'oversize' };
  const length = count.toUInt32();
  if (length === 0) return { status: 'empty', kind: 'large', length };
  // b60 of countAndFlags means tail-allocated UTF-8, biased by 32.
  if ((words[7] & 0x10) === 0) return { status: 'unsupported', kind: 'shared-or-foreign', length };
  const start = second.and(ptr('0x0fffffffffffffff')).add(32);
  try {
    const raw = start.readByteArray(length);
    if (raw === null) return { status: 'unreadable', kind: 'native', length };
    const text = exactASCII(Array.from(new Uint8Array(raw)));
    return { status: text === null ? 'unsupported' : 'decoded', kind: 'native', length, text };
  } catch (_) { return { status: 'unreadable', kind: 'native', length }; }
}
function inspectPair(label, first, second) {
  const result = decodeString(first, second);
  stats[result.status]++;
  log(`${label} status=${result.status} storage=${result.kind} length=${result.length === undefined ? '?' : result.length}`);
  if (result.status !== 'decoded' || !/^(?:[0-9a-fA-F]{2}){8,128}$/.test(result.text)) return;
  const hex = result.text.toUpperCase();
  let candidate = tokens.get(hex);
  if (!candidate) {
    candidate = `candidate-${tokens.size + 1}`;
    tokens.set(hex, candidate);
    log(`TOKEN-CANDIDATE id=${candidate} bytes=${hex.length / 2}; authentication must validate it`);
    log(`PAIRING_TOKEN_HEX=${hex}`);
  }
  log(`${label} token=${candidate}`);
}
function inspectConfig(label, instance) {
  stats.objects++;
  if (propertyOffset === null) { log(`${label} skipped: token layout unverified`); return; }
  try {
    const address = instance.handle || instance;
    const field = address.add(propertyOffset);
    inspectPair(label, field.readPointer(), field.add(8).readPointer());
  } catch (error) {
    stats.unreadable++;
    log(`${label} read-error=${error.name || 'Error'}`);
  }
}
function verifyOffset(getter) {
  // Inspect before Interceptor rewrites the prologue. Confirmed in 3.3.0 dump.
  let cursor = getter;
  let offset = null;
  for (let index = 0; index < 16; index++) {
    const instruction = Instruction.parse(cursor);
    const operands = instruction.opStr.replace(/\s+/g, '');
    if (instruction.mnemonic === 'add') {
      const match = /^x0,x20,#(0x[0-9a-f]+|[0-9]+)$/i.exec(operands);
      if (match) offset = Number(match[1]);
    }
    if (instruction.mnemonic === 'ldp') {
      const match = /^x19,x20,\[x20,#(0x[0-9a-f]+|[0-9]+)\]$/i.exec(operands);
      if (match && Number(match[1]) === offset && offset === 16) return offset;
    }
    if (instruction.mnemonic === 'ret') break;
    cursor = instruction.next;
  }
  return null;
}
function scanExistingConfigs() {
  if (scanning) return 'scan already running';
  if (propertyOffset === null) return 'layout not verified; observing natural calls only';
  scanning = true;
  try {
    const names = ['_TtC9MIWBTCore21MIWBTPeripheralConfig', 'MIWBTCore.MIWBTPeripheralConfig', 'MIWBTPeripheralConfig'];
    const seen = new Set();
    for (const name of names) {
      const cls = ObjC.classes[name];
      if (!cls || seen.has(cls.handle.toString())) continue;
      seen.add(cls.handle.toString());
      log(`CONFIG-SCAN class=${name}`);
      let count = 0;
      ObjC.choose({ class: cls, subclasses: false }, {
        onMatch(instance) { count++; inspectConfig(`config-${count}`, instance); },
        onComplete() { log(`CONFIG-SCAN instances=${count}`); }
      });
    }
    if (seen.size === 0) log('CONFIG-SCAN class-not-found');
  } catch (error) { log(`CONFIG-SCAN failed=${error.name || 'Error'}`); }
  finally { scanning = false; }
  log(`RESULT ${JSON.stringify({ ...stats, candidates: tokens.size })}`);
  return 'scan complete';
}
function install() {
  log(`Installing ${VERSION}`);
  if (Process.arch !== 'arm64' || !ObjC.available) { log('Unsupported runtime'); return; }
  const module = Process.findModuleByName('MIWBTCore');
  if (!module) { log('MIWBTCore not loaded; open glasses screen then reload'); return; }
  const symbols = typeof module.enumerateSymbols === 'function'
    ? module.enumerateSymbols() : Module.enumerateSymbolsSync(module.name);
  const targets = {};
  for (const [label, name] of Object.entries(SYMBOLS)) {
    const match = symbols.find(s => (s.name === name || s.name === `_${name}`) && !s.address.isNull());
    if (match) targets[label] = match.address;
  }
  if (targets.getter) {
    try { propertyOffset = verifyOffset(targets.getter); }
    catch (_) { log('LAYOUT instruction-read failed'); }
  }
  log(`LAYOUT tokenOffset=${propertyOffset === null ? 'unverified' : propertyOffset}`);
  const handlers = {
    getter: { onLeave(retval) { inspectPair('getter', retval, this.context.x1); } },
    setter: { onEnter(args) { inspectPair('setter', args[0], args[1]); } },
    init: { onEnter(args) { inspectPair('init', args[0], args[1]); } },
    peripheral: { onLeave(retval) { inspectConfig('active-config', retval); } }
  };
  for (const [label, callbacks] of Object.entries(handlers)) {
    if (!targets[label]) { log(`MISS ${label}`); continue; }
    try { Interceptor.attach(targets[label], callbacks); installed++; }
    catch (error) { log(`HOOK-FAILED ${label} ${error.name || 'Error'}`); }
  }
  log(`Installed hooks=${installed}; scanning existing config once`);
  setTimeout(scanExistingConfigs, 250);
}
setImmediate(install);
rpc.exports = {
  scan: scanExistingConfigs,
  status() { return { version: VERSION, hooks: installed, layoutVerified: propertyOffset !== null, ...stats, candidates: tokens.size }; }
};
