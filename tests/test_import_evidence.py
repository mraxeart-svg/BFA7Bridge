import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from analyze_ios_flow_log import parse_log, classify
from audit_import_exchange import fields, credentials_shape, crc16


class EvidenceTests(unittest.TestCase):
    def test_inline_length_not_padding(self):
        line = ('[BFA7-iOS-FLOW 2026-09-25T11:53:26.004Z] FLOW MIWFlowEncrypt.encrypt(data:) '
                'arg-x0/x1 swiftdata-inline x0-le=08 02 10 58 00 00 00 00 ascii=...X.... '
                'x1-le=00 00 00 00 00 00 04 00 ascii=........ count-hi32=0')
        with tempfile.TemporaryDirectory() as directory:
            p = Path(directory) / 'capture.txt'
            p.write_text(line)
            events, _ = parse_log(p)
        self.assertEqual(events[0].hex_text, '08 02 10 58')
        self.assertEqual(events[0].length, 4)
        self.assertEqual(events[0].tag, 'wifi-ap-trigger')

    def test_old_candidate_is_not_labelled_trigger(self):
        self.assertNotEqual(classify('08 0E 10 05 82 01 0E 2A 0C', '', 'ARG encrypt'), 'wifi-ap-trigger')

    def test_strict_parser(self):
        self.assertEqual(fields(bytes.fromhex('08 02 10 58')), {1: 2, 2: 88})
        for malformed in ('00', '0A FF FF FF FF FF FF FF FF FF 7F', '08 02 80', '08 02 08 03', '0A 02 01'):
            with self.assertRaises(ValueError):
                fields(bytes.fromhex(malformed))

    def test_no_credentials_from_unrelated_text(self):
        self.assertIsNone(credentials_shape(b'Xiaomi AI Glasses BFA7 password'))

    def test_crc_reference(self):
        self.assertEqual(crc16(b'123456789'), 0xbb3d)


if __name__ == '__main__':
    unittest.main()
