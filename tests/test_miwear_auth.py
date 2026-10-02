import copy
import hmac
import json
import sys
import unittest
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESCCM

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from audit_import_exchange import crc16
from verify_miwear_auth import MODEL, ble_frames, derive_keys, read_record, verify_capture


def varint(value):
    result = bytearray()
    while value > 127:
        result.append((value & 127) | 128)
        value >>= 7
    return bytes(result) + bytes([value])


def field(number, value):
    if isinstance(value, int):
        return varint(number << 3) + varint(value)
    return varint((number << 3) | 2) + varint(len(value)) + value


def packet(command, number, payload):
    return field(1, 1) + field(2, command) + field(3, field(number, payload))


def frame(packet_bytes, sequence=0):
    payload = b'\x01\x01' + packet_bytes
    return (b'\xa5\xa5\x03' + bytes([sequence]) + len(payload).to_bytes(2, 'little')
            + crc16(payload).to_bytes(2, 'little') + payload)


def line(direction, data):
    char = '005F' if direction == 'WRITE' else '005E'
    return f'CB {direction} characteristic=FE95/{char} len={len(data)} hex={data.hex(" ")} ({len(data)} bytes)'


class AuthVerificationTests(unittest.TestCase):
    def setUp(self):
        self.key = bytes(range(16))
        self.record = {'model': MODEL, 'sid': 'synthetic', 'name': 'Test glasses',
                       'detail': {'encrypt_key': self.key.hex(), 'token': 'f' * 32,
                                  'appKey': 'e' * 32}}
        self.app, self.device = bytes(range(16, 32)), bytes(range(32, 48))
        self.material = derive_keys(self.key, self.app, self.device)
        self.verify_request = packet(26, 30, field(1, self.app))
        self.verify_reply = packet(26, 31, field(1, self.device) + field(
            2, hmac.digest(self.material[:16], self.device + self.app, 'sha256')))
        companion = AESCCM(self.material[16:32], tag_length=4).encrypt(
            self.material[36:40] + bytes(8), field(1, 1) + field(3, b'Test'), None)
        self.confirm_request = packet(27, 32, field(
            1, hmac.digest(self.material[16:32], self.app + self.device, 'sha256')) + field(2, companion))
        self.confirm_reply = packet(27, 33, field(1, 1))
        self.capture = self.make_capture()

    def make_capture(self):
        return '\n'.join(line(direction, frame(p, i)) for i, (direction, p) in enumerate([
            ('WRITE', self.verify_request), ('NOTIFY', self.verify_reply),
            ('WRITE', self.confirm_request), ('NOTIFY', self.confirm_reply)]))

    def test_key_selection_is_not_token_or_session_key(self):
        self.assertEqual(read_record(self.record), self.key)
        self.assertEqual(read_record({'code': 0, 'data': {'list': [self.record]}}), self.key)
        for field_name in ('token', 'appKey', 'deviceKey', 'auth_key'):
            bad = copy.deepcopy(self.record)
            bad['detail'] = {field_name: self.key.hex()}
            with self.assertRaises(ValueError):
                read_record(bad)

    def test_rejects_ambiguity_wrong_model_failed_response_and_bad_hex(self):
        cases = [[], {'code': 1, 'data': {'list': [self.record]}},
                 {'code': False, 'data': {'list': [self.record]}},
                 {'list': [self.record, self.record]}, {**self.record, 'model': 'band'}]
        for key in ('', 'ab' * 15, 'gg' * 16, 'ab ' * 16, 'ab' * 17):
            cases.append({**self.record, 'detail': {'encrypt_key': key}})
        for value in cases:
            with self.assertRaises(ValueError):
                read_record(value)
        another = {**self.record, 'sid': 'another'}
        self.assertEqual(read_record({'list': [another, self.record]}, 'synthetic'), self.key)

    def test_hkdf_independent_reference(self):
        self.assertEqual(self.material[:16].hex(), 'd738074e6570abb50d001db70f497a37')
        self.assertEqual(self.material[16:32].hex(), '923e295e02aecb7619a8e1b9f574c988')

    def test_full_handshake_and_redacted_output(self):
        report = verify_capture(self.capture, self.key)
        self.assertTrue(report['authentication_verified'])
        self.assertFalse(report['hardware_import_verified'])
        serialized = json.dumps(report)
        for secret in (self.key, self.app, self.device, self.material[:16], self.material[16:32]):
            self.assertNotIn(secret.hex(), serialized)
        self.assertFalse(verify_capture(self.capture, b'\xff' * 16)['authentication_verified'])

    def test_requires_both_confirmations_and_valid_ccm(self):
        self.assertFalse(verify_capture('\n'.join(self.capture.splitlines()[:2]), self.key)['authentication_verified'])
        self.confirm_reply = packet(27, 33, field(1, 0))
        self.assertFalse(verify_capture(self.make_capture(), self.key)['authentication_verified'])
        self.confirm_reply = packet(27, 33, field(1, 1))
        self.confirm_request = self.confirm_request[:-1] + bytes([self.confirm_request[-1] ^ 1])
        self.assertFalse(verify_capture(self.make_capture(), self.key)['authentication_verified'])

    def test_reassembly_and_duplicate_complete_notifications(self):
        f = frame(self.verify_reply)
        for split in range(1, len(f)):
            text = line('NOTIFY', f[:split]) + '\n' + line('NOTIFY', f[split:])
            self.assertEqual([item[2] for item in ble_frames(text)], [f])
        text = line('NOTIFY', f) + '\n' + line('NOTIFY', f)
        self.assertEqual(len(list(ble_frames(text))), 1)
        corrupt = f[:-1] + bytes([f[-1] ^ 1])
        self.assertEqual(list(ble_frames(line('NOTIFY', corrupt))), [])

    def test_bind_and_oob_are_not_successful_token_auth(self):
        bind = line('NOTIFY', frame(packet(17, 12, field(1, 1))))
        report = verify_capture(bind, self.key)
        self.assertEqual(report['bind_ids_observed'], [17])
        self.assertEqual(report['auth_attempts'], [])
        self.verify_request = packet(26, 30, field(1, self.app) + field(3, 1))
        report = verify_capture(self.make_capture(), self.key)
        self.assertFalse(report['authentication_verified'])
        self.assertEqual(report['auth_attempts'][0]['device_signature'], 'unsupported_dynamic_code')

    def test_account_error_invalidates_pending_session(self):
        parts = self.capture.splitlines()
        error = line('NOTIFY', frame(packet(26, 3, 4), 99))
        report = verify_capture('\n'.join(parts[:2] + [error] + parts[2:]), self.key)
        self.assertFalse(report['authentication_verified'])
        self.assertEqual(report['auth_attempts'][0]['account_error'], 4)


if __name__ == '__main__':
    unittest.main()
