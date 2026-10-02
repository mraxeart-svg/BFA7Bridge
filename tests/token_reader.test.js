'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const memory = new Map();
class Pointer {
  constructor(value) { this.value = BigInt(value) & ((1n << 64n) - 1n); }
  and(other) { return new Pointer(this.value & other.value); }
  shr(bits) { return new Pointer(this.value >> BigInt(bits)); }
  add(value) { return new Pointer(this.value + BigInt(value)); }
  toUInt32() { return Number(this.value & 0xffffffffn); }
  compare(other) { return this.value < other.value ? -1 : this.value > other.value ? 1 : 0; }
  toString() { return '0x' + this.value.toString(16); }
  readByteArray(length) {
    const data = memory.get(this.toString());
    if (!data || length > data.length) throw new Error('unreadable');
    return Uint8Array.from(data.slice(0, length)).buffer;
  }
  readPointer() {
    const data = this.readByteArray(8);
    return new Pointer(Buffer.from(data).readBigUInt64LE());
  }
}
const ptr = value => new Pointer(value);
const messages = [];
const context = vm.createContext({ptr, console: {log: line => messages.push(line)},
  rpc: {}, setImmediate() {}, setTimeout() {}, Uint8Array});
vm.runInContext(fs.readFileSync(path.join(__dirname, '../tools/frida-ios-xiaomi-pairing-token-hook-lite.js'), 'utf8'), context);
const decode = (first, second) => context.decodeString(ptr(first), ptr(second));
assert.equal(decode(0, '0xe000000000000000').status, 'empty');
assert.equal(decode('0x31323334', '0xe400000000000000').text, '4321');
assert.equal(decode('0x1000000000000101', 0).kind, 'oversize');
assert.equal(decode(32, 0).kind, 'shared-or-foreign');
assert.equal(decode('0x1000000000000020', 0).status, 'unreadable');
const token = '0123456789ABCDEF0123456789ABCDEF';
memory.set('0x1020', Buffer.from(token + 'DONT_READ_NEIGHBORS'));
assert.equal(decode('0x1000000000000020', '0x1000').text, token);
context.inspectPair('test', ptr('0x1000000000000020'), ptr('0x1000'));
context.inspectPair('test-again', ptr('0x1000000000000020'), ptr('0x1000'));
assert.equal(messages.filter(x => x.includes('PAIRING_TOKEN_HEX=')).length, 1);
memory.set('0x2020', Buffer.from(token + '!'));
context.inspectPair('nonhex', ptr('0x1000000000000021'), ptr('0x2000'));
assert.equal(messages.filter(x => x.includes('PAIRING_TOKEN_HEX=')).length, 1);
memory.set('0x3020', Buffer.from([0, 1, 2, 3]));
assert.equal(decode('0x1000000000000004', '0x3000').status, 'unsupported');

context.Instruction = {parse(address) {
  const i = Number(address.value / 4n);
  return {mnemonic: ['add', 'ldp', 'ret'][i],
    opStr: ['x0, x20, #0x10', 'x19, x20, [x20, #0x10]', ''][i], next: address.add(4)};
}};
assert.equal(context.verifyOffset(ptr(0)), 16);
context.Instruction = {parse: address => ({mnemonic: 'ret', opStr: '', next: address.add(4)})};
assert.equal(context.verifyOffset(ptr(0)), null);

vm.runInContext('propertyOffset = 16', context);
memory.set('0x4010', Buffer.from('2000000000000010', 'hex'));
memory.set('0x4018', Buffer.from('0010000000000000', 'hex'));
let scans = 0;
const cls = {handle: ptr(0x5000)};
context.ObjC = {classes: {'_TtC9MIWBTCore21MIWBTPeripheralConfig': cls, 'MIWBTCore.MIWBTPeripheralConfig': cls},
  choose(_options, callbacks) { scans++; callbacks.onMatch({handle: ptr(0x4000)}); callbacks.onComplete(); }};
context.scanExistingConfigs();
assert.equal(scans, 1);
assert.equal(context.rpc.exports.status().candidates, 1);
assert.equal(context.rpc.exports.status().objects, 1);
console.log('Token reader: decoding, bounds, layout verification and alias deduplication passed');
