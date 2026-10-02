#!/usr/bin/env python3
"""Check AP exchange evidence without printing credentials, keys or capture contents."""
import argparse
import hashlib
import json
import re
from pathlib import Path

from analyze_ios_flow_log import parse_log


def fields(data):
    offset = 0

    def varint():
        nonlocal offset
        value = 0
        for shift in range(0, 64, 7):
            if offset == len(data):
                raise ValueError('truncated varint')
            byte = data[offset]
            offset += 1
            if shift == 63 and byte > 1:
                raise ValueError('overflow')
            value |= (byte & 127) << shift
            if byte < 128:
                return value
        raise ValueError('overflow')

    result = {}
    while offset < len(data):
        key = varint()
        number, wire = key >> 3, key & 7
        if not 0 < number <= 0x1fffffff or number in result:
            raise ValueError('invalid or duplicate field')
        if wire == 0:
            result[number] = varint()
            continue
        length = varint() if wire == 2 else {1: 8, 5: 4}.get(wire)
        if length is None or length > len(data) - offset:
            raise ValueError('invalid length or wire type')
        result[number] = data[offset:offset + length]
        offset += length
    return result


def crc16(data):
    value = 0
    for byte in data:
        value ^= byte
        for _ in range(8):
            value = (value >> 1) ^ (0xa001 if value & 1 else 0)
    return value


def credentials_shape(data):
    try:
        envelope = fields(data)
        if (envelope.get(1), envelope.get(2)) != (2, 88):
            return None
        result = fields(fields(envelope[4])[56])
        if result.get(1) != 0:
            return None
        wifi = fields(result[2])
        for n in (1, 2, 3):
            wifi[n].decode('utf-8')
        return {"path": "4/56/2", "ssid_bytes": len(wifi[1]),
                "password_bytes": len(wifi[2]), "gateway_bytes": len(wifi[3])}
    except (ValueError, KeyError, TypeError, AttributeError):
        return None


def audit(path):
    events, _ = parse_log(path)
    requests, results, later_candidates = [], [], []
    for index, event in enumerate(events):
        data = bytes.fromhex(event.hex_text)
        if event.kind.startswith('ARG encrypt') and data == bytes.fromhex('08 02 10 58'):
            record = {"plaintext_line": event.line, "time": event.ts, "wire_confirmed": False}
            for following in events[index + 1:]:
                if following.kind.startswith('ARG encrypt'):
                    break
                if following.kind.startswith('LEAVE encrypt') and following.length == 4:
                    cipher = bytes.fromhex(following.hex_text)
                    for write in events:
                        if write.line <= following.line or not write.kind.startswith('write FE95/005F'):
                            continue
                        frame = bytes.fromhex(write.hex_text)
                        if (len(frame) == 14 and frame[:3] == b'\xa5\xa5\x03'
                                and int.from_bytes(frame[4:6], 'little') == 6
                                and frame[8:] == b'\x01\x02' + cipher
                                and int.from_bytes(frame[6:8], 'little') == crc16(frame[8:])):
                            record.update(wire_confirmed=True, ciphertext_line=following.line,
                                          write_line=write.line)
                            break
                    break
            requests.append(record)
        if event.kind.startswith('LEAVE decrypt'):
            shape = credentials_shape(data)
            if shape:
                results.append({"line": event.line, "time": event.ts, **shape})
        if event.kind.startswith('ARG encrypt') and data.startswith(bytes.fromhex('08 0e 10 05')):
            later_candidates.append({"line": event.line, "time": event.ts,
                                     "after_credentials": any(r['line'] < event.line for r in results)})
    handshake = []
    seen = set()
    for line_number, line in enumerate(path.read_text(errors='replace').splitlines(), 1):
        match = re.search(r'CB (WRITE|NOTIFY).*?characteristic=FE95/005[EF].*?hex=((?:[A-F0-9]{2} ?)+)', line)
        if not match:
            continue
        frame = bytes.fromhex(match[2])
        identity = (match[1], frame)
        if identity in seen:
            continue
        seen.add(identity)
        if (len(frame) < 10 or frame[:3] != b'\xa5\xa5\x03' or frame[8:10] != b'\x01\x01'
                or int.from_bytes(frame[4:6], 'little') != len(frame) - 8
                or crc16(frame[8:]) != int.from_bytes(frame[6:8], 'little')):
            continue
        try:
            envelope = fields(frame[10:])
            if envelope.get(1) != 1:
                continue
            account = fields(envelope[3])
            record = {"line": line_number, "direction": match[1], "id": envelope.get(2),
                      "account_fields": sorted(account)}
            if 12 in account:
                info = fields(account[12])
                record.update(verify_mode=info.get(1), oob_mode=info.get(5))
            handshake.append(record)
        except (ValueError, KeyError, TypeError):
            continue
    return {"source_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "enable_ap": requests, "credential_results": results,
            "former_trigger_candidates": later_candidates,
            "plaintext_handshake": handshake,
            "authentication_verified": False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    args = parser.parse_args()
    print(json.dumps(audit(args.capture), indent=2))
