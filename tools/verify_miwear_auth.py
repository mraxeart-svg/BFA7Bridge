#!/usr/bin/env python3
"""Offline check of an O95 cloud credential against a captured AUTH26/27 exchange.

No network, Bluetooth, key guessing, or secret output. SERVER_PSK binding is
deliberately not treated as token authentication. Requires cryptography.
"""

import argparse
import hashlib
import hmac
import json
import re
from pathlib import Path

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESCCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

from audit_import_exchange import crc16, fields


MODEL = "miwear.phovideo.o95cn"


def read_record(value, device_id=None):
    """Select only the SDK's observed cloud field, never detail.token/appKey."""
    if not isinstance(value, dict):
        raise ValueError("Expected a source record or a source-list JSON object")
    if "code" in value:
        if type(value["code"]) is not int or value["code"] != 0:
            raise ValueError("Source-list response did not report success")
        value = value.get("data")
    if not isinstance(value, dict):
        raise ValueError("Missing source-list data")
    records = value.get("list", [value])
    if not isinstance(records, list) or not all(isinstance(r, dict) for r in records):
        raise ValueError("Malformed source list")
    matches = [r for r in records if r.get("model") == MODEL
               and (device_id is None or r.get("sid") == device_id)]
    if len(matches) != 1:
        raise ValueError("Select exactly one O95 record; use --device-id for multiple glasses")
    record = matches[0]
    detail = record.get("detail")
    if not isinstance(detail, dict):
        raise ValueError("Missing structured device detail")
    key = detail.get("encrypt_key")
    if not isinstance(key, str) or re.fullmatch(r"[0-9a-fA-F]{32}", key) is None:
        raise ValueError("detail.encrypt_key must be a 16-byte hex key; no fallback is allowed")
    return bytes.fromhex(key)


def derive_keys(key, app_random, device_random):
    return HKDF(algorithm=hashes.SHA256(), length=64, salt=app_random + device_random,
                info=b"miwear-auth").derive(key)


def ble_frames(text):
    """Reassemble notifications/writes independently; emit only CRC-valid frames."""
    buffers = {"WRITE": bytearray(), "NOTIFY": bytearray()}
    previous = {"WRITE": None, "NOTIFY": None}
    pattern = re.compile(r'CB (WRITE|NOTIFY).*?characteristic=FE95/(005[EF]).*?hex=((?:[a-fA-F0-9]{2} ?)+)')
    for line_number, line in enumerate(text.splitlines(), 1):
        match = pattern.search(line)
        if not match:
            continue
        direction, characteristic = match[1], match[2]
        if characteristic != {"WRITE": "005F", "NOTIFY": "005E"}[direction]:
            continue
        buffer = buffers[direction]
        buffer.extend(bytes.fromhex(match[3]))
        while len(buffer) >= 8:
            if buffer[:2] != b'\xa5\xa5':
                del buffer[0]
                continue
            length = int.from_bytes(buffer[4:6], 'little') + 8
            if len(buffer) < length:
                break
            frame = bytes(buffer[:length])
            if crc16(frame[8:]) != int.from_bytes(frame[6:8], 'little'):
                del buffer[0]
                continue
            del buffer[:length]
            if previous[direction] == frame:
                continue
            previous[direction] = frame
            yield line_number, direction, frame


def verify_capture(text, key):
    attempts = []
    current = None
    app_random = None
    device_random = None
    material = None
    bind_ids = set()
    malformed = 0
    for line, direction, frame in ble_frames(text):
        if frame[2] == 2:
            current = material = app_random = device_random = None
            continue
        if frame[2] != 3 or frame[8:10] != b'\x01\x01':
            continue
        try:
            envelope = fields(frame[10:])
            if envelope.get(1) != 1:
                continue
            command = envelope.get(2)
            account = fields(envelope[3])
            if command in (16, 17, 18, 19, 25):
                bind_ids.add(command)
                # Never carry a previous token session across a new binding flow.
                current = material = app_random = device_random = None
                continue
            if command == 26 and direction == "WRITE":
                verify = fields(account[30])
                random = verify[1]
                if not isinstance(random, bytes) or len(random) != 16:
                    raise ValueError("invalid app nonce")
                if current is not None and app_random == random:
                    continue
                app_random = random
                material = device_random = None
                current = {"app_verify_line": line, "device_signature": "not_observed",
                           "app_confirmation": "not_observed", "device_confirm": False,
                           "authenticated_exchange_verified": False}
                attempts.append(current)
                if verify.get(3, 0) != 0:
                    current["device_signature"] = "unsupported_dynamic_code"
            elif current is not None and direction == "NOTIFY" and 3 in account:
                current["account_error"] = account[3] if type(account[3]) is int else "malformed"
                current = material = app_random = device_random = None
            elif current is not None and command == 26 and direction == "NOTIFY":
                verify = fields(account[31])
                device_random, signature = verify[1], verify[2]
                if (not isinstance(device_random, bytes) or len(device_random) != 16
                        or not isinstance(signature, bytes) or len(signature) != 32):
                    raise ValueError("invalid device verify")
                if current["device_signature"] == "unsupported_dynamic_code":
                    continue
                material = derive_keys(key, app_random, device_random)
                expected = hmac.digest(material[:16], device_random + app_random, "sha256")
                current["device_signature"] = "valid" if hmac.compare_digest(signature, expected) else "mismatch"
                current["device_verify_line"] = line
            elif current is not None and command == 27 and direction == "WRITE":
                if material is None or current["device_signature"] != "valid":
                    continue
                confirm = fields(account[32])
                expected = hmac.digest(material[16:32], app_random + device_random, "sha256")
                if not isinstance(confirm[1], bytes) or not hmac.compare_digest(confirm[1], expected):
                    current["app_confirmation"] = "signature_mismatch"
                    continue
                try:
                    companion = AESCCM(material[16:32], tag_length=4).decrypt(
                        material[36:40] + bytes(8), confirm[2], None)
                    if not fields(companion):
                        raise ValueError("empty companion")
                    current["app_confirmation"] = "valid"
                except (InvalidTag, ValueError):
                    current["app_confirmation"] = "companion_invalid"
            elif current is not None and command == 27 and direction == "NOTIFY":
                confirm = fields(account[33])
                current["device_confirm"] = confirm.get(1) == 1
                current["authenticated_exchange_verified"] = (
                    current["device_signature"] == "valid"
                    and current["app_confirmation"] == "valid" and current["device_confirm"])
                current = material = app_random = device_random = None
        except (ValueError, KeyError, TypeError, AttributeError):
            malformed += 1
            current = material = app_random = device_random = None
    return {"credential_source": "detail.encrypt_key", "auth_attempts": attempts,
            "bind_ids_observed": sorted(bind_ids), "malformed_account_packets": malformed,
            "authentication_verified": any(a["authenticated_exchange_verified"] for a in attempts),
            "hardware_import_verified": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--record", type=Path, required=True, help="Private owner-exported device JSON")
    parser.add_argument("--device-id", help="Select sid when several O95 records exist")
    args = parser.parse_args()
    try:
        if args.record.stat().st_size > 1_048_576:
            raise ValueError("Device record exceeds 1 MiB")
        key = read_record(json.loads(args.record.read_text(encoding="utf-8-sig")), args.device_id)
        raw = args.capture.read_bytes()
        report = verify_capture(raw.decode("utf-8-sig", errors="replace"), key)
    except (OSError, ValueError):
        parser.exit(2, "Cannot read a valid O95 device record/capture. No secret values were printed.\n")
    report["capture_sha256"] = hashlib.sha256(raw).hexdigest()
    print(json.dumps(report, indent=2))
    return 0 if report["authentication_verified"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
