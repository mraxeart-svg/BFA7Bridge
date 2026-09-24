#!/usr/bin/env python3
"""Analyze BFA7 A5A5 protocol reports copied from BFA7 Bridge.

The tool intentionally accepts messy pasted reports. It extracts timeline rows,
full HEX blocks, JSON exports and plain A5 byte lines, then highlights frames
that match the Xiaomi AI Glasses import/AP pattern seen in public notes:
incoming A5A5 payload frames with declared payload length 65 or 67 bytes.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import math
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Iterable


TIMELINE_RE = re.compile(
    r"(?P<rel>[+-]\d+(?:\.\d+)?)s\s+\|\s+"
    r"(?:(?P<date>\d{4}-\d{2}-\d{2}T[^|]+?)\s+\|\s+)?"
    r"(?:(?P<dir><-|->)\s+)?"
    r"(?:(?P<service>[0-9A-Fa-f-]+)/)?(?P<char>[0-9A-Fa-f]{4})\s+\|\s+"
    r"(?P<count>\d+)\s*B\s+\|\s+"
    r"(?P<first>(?:[0-9A-Fa-f]{2}\s+){1,7}[0-9A-Fa-f]{2})"
    r"(?:\s+\|\s+(?P<summary>[^\\n\\r]+))?"
)
FULL_HEX_RE = re.compile(r"\bHEX:\s*(?P<hex>(?:[0-9A-Fa-f]{2}\s+)+[0-9A-Fa-f]{2})")
JSON_HEX_RE = re.compile(r'"hex"\s*:\s*"(?P<hex>(?:[0-9A-Fa-f]{2}\s+)+[0-9A-Fa-f]{2})"')
BARE_A5_RE = re.compile(r"(?m)^(?P<hex>A5 A5(?:\s+[0-9A-Fa-f]{2}){6,})\s*$")
PRIMARY_AP_LENGTHS = {65}
ALTERNATE_AP_LENGTHS = {67}
AP_LENGTHS = PRIMARY_AP_LENGTHS | ALTERNATE_AP_LENGTHS
AP_PACKET_SIZES = {length + 8 for length in AP_LENGTHS}


@dataclasses.dataclass
class Frame:
    source: str
    index: int
    direction: str | None
    service: str | None
    characteristic: str | None
    relative_seconds: float | None
    date: str | None
    byte_count: int
    data: bytes
    full_hex: bool
    summary: str | None = None

    @property
    def first8(self) -> bytes:
        return self.data[:8]

    @property
    def looks_a5(self) -> bool:
        return len(self.data) >= 2 and self.data[0] == 0xA5 and self.data[1] == 0xA5

    @property
    def op(self) -> int | None:
        return self.data[2] if self.looks_a5 and len(self.data) >= 3 else None

    @property
    def seq(self) -> int | None:
        return self.data[3] if self.looks_a5 and len(self.data) >= 4 else None

    @property
    def declared_length(self) -> int | None:
        if not self.looks_a5 or len(self.data) < 6:
            return None
        return self.data[4] | (self.data[5] << 8)

    @property
    def checksum(self) -> int | None:
        if not self.looks_a5 or len(self.data) < 8:
            return None
        return self.data[6] | (self.data[7] << 8)

    @property
    def payload(self) -> bytes:
        return self.data[8:] if self.looks_a5 and len(self.data) > 8 else b""

    @property
    def is_complete_payload_start(self) -> bool:
        return self.looks_a5 and self.op == 0x03 and self.declared_length is not None and len(self.payload) == self.declared_length

    @property
    def inferred_complete_from_count(self) -> bool:
        return self.looks_a5 and self.declared_length is not None and self.byte_count == self.declared_length + 8

    @property
    def kind(self) -> str:
        if not self.looks_a5:
            return "continuation/raw"
        if self.op == 0x01 and self.byte_count == 8:
            return "shortControl"
        if self.op == 0x03:
            return "payloadStart"
        return f"a5-op-0x{self.op:02X}" if self.op is not None else "a5"

    @property
    def score(self) -> int:
        score = 0
        if self.direction == "<-":
            score += 2
        if (self.characteristic or "").upper() == "005E":
            score += 2
        if self.op == 0x03:
            score += 2
        if self.declared_length in PRIMARY_AP_LENGTHS:
            score += 10
        elif self.declared_length in ALTERNATE_AP_LENGTHS:
            score += 7
        if self.byte_count == 73:
            score += 5
        elif self.byte_count in AP_PACKET_SIZES:
            score += 4
        if self.inferred_complete_from_count:
            score += 2
        return score

    @property
    def ap_role(self) -> str:
        if self.declared_length in PRIMARY_AP_LENGTHS and self.byte_count == self.declared_length + 8:
            return "primary-ap-flow"
        if self.declared_length in ALTERNATE_AP_LENGTHS and self.byte_count == self.declared_length + 8:
            return "alternate-ap-flow"
        if self.declared_length in AP_LENGTHS:
            return "ap-adjacent"
        return "-"

    def label(self) -> str:
        direction = self.direction or "?"
        char = self.characteristic or "?"
        seq = f"0x{self.seq:02X}" if self.seq is not None else "-"
        length = str(self.declared_length) if self.declared_length is not None else "-"
        rel = f"{self.relative_seconds:+.3f}s" if self.relative_seconds is not None else "-"
        return f"{rel} | {direction} {char} | {self.byte_count}B | seq={seq} len={length} | {hex_spaced(self.first8)}"


def parse_hex(text: str) -> bytes:
    return bytes(int(part, 16) for part in re.findall(r"[0-9A-Fa-f]{2}", text))


def hex_spaced(data: bytes) -> str:
    return " ".join(f"{byte:02X}" for byte in data)


def short_hash(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()[:12]


def shannon_entropy(data: bytes) -> float:
    if not data:
        return 0.0
    counts = Counter(data)
    total = len(data)
    return -sum((count / total) * math.log2(count / total) for count in counts.values())


def printable_ratio(data: bytes) -> float:
    if not data:
        return 0.0
    printable = sum(1 for byte in data if byte in (9, 10, 13) or 32 <= byte <= 126)
    return printable / len(data)


def crc16_ccitt_false(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def crc16_xmodem(data: bytes) -> int:
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def crc16_modbus(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
            crc &= 0xFFFF
    return crc


def checksum_matches(frame: Frame) -> list[str]:
    if not frame.looks_a5 or frame.checksum is None or not frame.payload:
        return []
    candidates = {
        "sum16(payload)": sum(frame.payload) & 0xFFFF,
        "crc16-ccitt(payload)": crc16_ccitt_false(frame.payload),
        "crc16-xmodem(payload)": crc16_xmodem(frame.payload),
        "crc16-modbus(payload)": crc16_modbus(frame.payload),
        "crc16-ccitt(op-seq-len-payload)": crc16_ccitt_false(frame.data[2:6] + frame.payload),
        "crc16-xmodem(op-seq-len-payload)": crc16_xmodem(frame.data[2:6] + frame.payload),
        "crc16-modbus(op-seq-len-payload)": crc16_modbus(frame.data[2:6] + frame.payload),
    }
    return [name for name, value in candidates.items() if value == frame.checksum]


def protobuf_probe(data: bytes, limit: int = 12) -> list[str]:
    """Best-effort protobuf tag scan; encrypted blobs will look sparse/noisy."""
    out: list[str] = []
    index = 0
    while index < len(data) and len(out) < limit:
        tag, tag_len = read_varint(data, index)
        if tag is None or tag == 0:
            break
        field = tag >> 3
        wire = tag & 7
        if field == 0 or wire not in (0, 1, 2, 5):
            break
        index += tag_len
        if wire == 0:
            value, consumed = read_varint(data, index)
            if value is None:
                break
            out.append(f"{field}:varint={value}")
            index += consumed
        elif wire == 1:
            if index + 8 > len(data):
                break
            out.append(f"{field}:fixed64")
            index += 8
        elif wire == 2:
            length, consumed = read_varint(data, index)
            if length is None or length < 0 or index + consumed + length > len(data):
                break
            value = data[index + consumed : index + consumed + length]
            preview = value.decode("utf-8", "replace") if printable_ratio(value) > 0.8 else hex_spaced(value[:8])
            out.append(f"{field}:len={length}:{preview}")
            index += consumed + length
        elif wire == 5:
            if index + 4 > len(data):
                break
            out.append(f"{field}:fixed32")
            index += 4
    return out


def read_varint(data: bytes, index: int) -> tuple[int | None, int]:
    value = 0
    shift = 0
    for consumed in range(1, 11):
        if index >= len(data):
            return None, consumed - 1
        byte = data[index]
        index += 1
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, consumed
        shift += 7
    return None, 10


def extract_frames(path: Path) -> list[Frame]:
    text = path.read_text(encoding="utf-8", errors="replace")
    frames: list[Frame] = []
    seen_spans: set[tuple[int, int]] = set()

    for match in TIMELINE_RE.finditer(text):
        data = parse_hex(match.group("first"))
        frames.append(
            Frame(
                source=str(path),
                index=len(frames),
                direction=match.group("dir"),
                service=match.group("service"),
                characteristic=match.group("char").upper(),
                relative_seconds=float(match.group("rel")),
                date=(match.group("date") or "").strip() or None,
                byte_count=int(match.group("count")),
                data=data,
                full_hex=False,
                summary=match.group("summary"),
            )
        )
        seen_spans.add(match.span())

    for regex in (FULL_HEX_RE, JSON_HEX_RE, BARE_A5_RE):
        for match in regex.finditer(text):
            data = parse_hex(match.group("hex"))
            if len(data) < 8:
                continue
            frames.append(
                Frame(
                    source=str(path),
                    index=len(frames),
                    direction=None,
                    service=None,
                    characteristic=None,
                    relative_seconds=None,
                    date=None,
                    byte_count=len(data),
                    data=data,
                    full_hex=True,
                )
            )

    # Some ProtocolLab exports are JSON arrays with richer direction metadata.
    for json_frames in extract_json_frames(text):
        for item in json_frames:
            frames.append(
                Frame(
                    source=str(path),
                    index=len(frames),
                    direction="<-" if item.get("direction") == "in" else "->" if item.get("direction") == "out" else None,
                    service=item.get("serviceUUID"),
                    characteristic=(item.get("characteristicUUID") or "").upper() or None,
                    relative_seconds=None,
                    date=item.get("date"),
                    byte_count=int(item.get("byteCount") or 0),
                    data=parse_hex(item.get("hex") or ""),
                    full_hex=True,
                )
            )

    return frames


def extract_json_frames(text: str) -> list[list[dict]]:
    try:
        decoded = json.loads(text)
    except Exception:
        return []
    if isinstance(decoded, list) and all(isinstance(item, dict) for item in decoded):
        return [decoded]
    return []


def dedupe(frames: Iterable[Frame]) -> list[Frame]:
    result: list[Frame] = []
    seen: set[tuple[str | None, str | None, int | None, int | None, int, bytes]] = set()
    for frame in frames:
        key = (
            frame.direction,
            frame.characteristic,
            frame.seq,
            frame.declared_length,
            frame.byte_count,
            frame.data,
        )
        if key in seen:
            continue
        seen.add(key)
        result.append(frame)
    return result


def range_summary(indices: Iterable[int], limit: int = 12) -> str:
    values = sorted(set(indices))
    if not values:
        return "-"
    ranges: list[str] = []
    start = previous = values[0]
    for value in values[1:]:
        if value == previous + 1:
            previous = value
            continue
        ranges.append(f"{start}" if start == previous else f"{start}-{previous}")
        start = previous = value
    ranges.append(f"{start}" if start == previous else f"{start}-{previous}")
    suffix = "" if len(ranges) <= limit else f" ... +{len(ranges) - limit} ranges"
    return ", ".join(ranges[:limit]) + suffix


def stable_prefix_length(payloads: list[bytes]) -> int:
    if len(payloads) < 2:
        return len(payloads[0]) if payloads else 0
    limit = min(map(len, payloads))
    for index in range(limit):
        if len({payload[index] for payload in payloads}) != 1:
            return index
    return limit


def render_payload_comparison(candidates: list[Frame]) -> list[str]:
    full_candidates = [
        frame for frame in candidates
        if frame.payload and frame.is_complete_payload_start and frame.declared_length in AP_LENGTHS
    ]
    grouped: dict[int, list[Frame]] = defaultdict(list)
    for frame in full_candidates:
        if frame.declared_length is not None:
            grouped[frame.declared_length].append(frame)

    lines: list[str] = []
    interesting_groups = {length: group for length, group in grouped.items() if len(group) >= 2}
    if not interesting_groups:
        return lines

    lines.append("## AP Payload Comparison")
    lines.append("")
    lines.append("Compares full payload bytes across repeated successful import/AP-flow candidates.")
    lines.append("")

    for length in sorted(interesting_groups):
        group = interesting_groups[length]
        payloads = [frame.payload for frame in group]
        min_len = min(map(len, payloads))
        stable_positions = [
            index for index in range(min_len)
            if len({payload[index] for payload in payloads}) == 1
        ]
        variable_positions = [
            index for index in range(min_len)
            if len({payload[index] for payload in payloads}) != 1
        ]
        role = "primary" if length in PRIMARY_AP_LENGTHS else "alternate"
        unique_payloads = {payload for payload in payloads}
        lines.append(f"### len={length} ({role})")
        lines.append("")
        lines.append(f"- samples: {len(group)}")
        lines.append(f"- unique payloads: {len(unique_payloads)}")
        lines.append(f"- stable prefix: {stable_prefix_length(payloads)} bytes")
        lines.append(f"- stable positions: {len(stable_positions)}/{min_len} ({range_summary(stable_positions)})")
        lines.append(f"- variable positions: {len(variable_positions)}/{min_len} ({range_summary(variable_positions)})")
        lines.append("")
        lines.append("| sample | frame | payload hash | first 16 payload bytes | entropy | printable |")
        lines.append("| ---: | --- | --- | --- | ---: | ---: |")
        for sample_index, frame in enumerate(group[:24], start=1):
            lines.append(
                f"| {sample_index} | `{frame.label()}` | `{short_hash(frame.payload)}` | "
                f"`{hex_spaced(frame.payload[:16])}` | {shannon_entropy(frame.payload):.2f} | {printable_ratio(frame.payload):.2f} |"
            )
        lines.append("")
    return lines


def ap_candidate_records(frames: list[Frame]) -> list[dict]:
    records: list[dict] = []
    for frame in dedupe(frames):
        if frame.op != 0x03 or frame.declared_length not in AP_LENGTHS or frame.byte_count != (frame.declared_length or 0) + 8:
            continue
        if not frame.is_complete_payload_start:
            continue
        record = {
            "source": frame.source,
            "role": frame.ap_role,
            "direction": frame.direction,
            "service": frame.service,
            "characteristic": frame.characteristic,
            "relative_seconds": frame.relative_seconds,
            "date": frame.date,
            "byte_count": frame.byte_count,
            "sequence": frame.seq,
            "declared_length": frame.declared_length,
            "checksum_le": frame.checksum,
            "header_hex": hex_spaced(frame.first8),
            "payload_hash": short_hash(frame.payload),
            "payload_entropy": round(shannon_entropy(frame.payload), 4),
            "payload_printable_ratio": round(printable_ratio(frame.payload), 4),
            "payload_hex": hex_spaced(frame.payload),
            "frame_hex": hex_spaced(frame.data),
        }
        records.append(record)
    return records


def render_report(frames: list[Frame]) -> str:
    frames = dedupe(frames)
    a5 = [frame for frame in frames if frame.looks_a5]
    payload_starts = [frame for frame in a5 if frame.op == 0x03]
    candidates = sorted((frame for frame in payload_starts if frame.score >= 10), key=lambda item: (-item.score, item.source, item.index))

    lines: list[str] = []
    lines.append("# BFA7 A5 Analysis")
    lines.append("")
    lines.append(f"frames={len(frames)}, a5={len(a5)}, payloadStart={len(payload_starts)}, candidates={len(candidates)}")
    lines.append("")

    lengths = Counter(frame.declared_length for frame in payload_starts if frame.declared_length is not None)
    if lengths:
        lines.append("## Declared Lengths")
        lines.append("")
        for length, count in lengths.most_common(20):
            if length in PRIMARY_AP_LENGTHS:
                marker = " <= primary AP-flow candidate"
            elif length in ALTERNATE_AP_LENGTHS:
                marker = " <= alternate AP-flow candidate"
            else:
                marker = ""
            lines.append(f"- len={length}: {count}{marker}")
        lines.append("")

    size_counts = Counter(frame.byte_count for frame in frames)
    if size_counts:
        lines.append("## Packet Sizes")
        lines.append("")
        for size, count in size_counts.most_common(20):
            if size == 73:
                marker = " <= primary len+8 candidate"
            elif size in AP_PACKET_SIZES:
                marker = " <= alternate len+8 candidate"
            else:
                marker = ""
            lines.append(f"- {size}B: {count}{marker}")
        lines.append("")

    if candidates:
        lines.append("## High-Signal Candidates")
        lines.append("")
        lines.append("| score | role | source | frame | completeness | payload stats | crc/checksum | protobuf probe |")
        lines.append("| ---: | --- | --- | --- | --- | --- | --- | --- |")
        for frame in candidates[:40]:
            payload = frame.payload
            completeness = []
            if frame.inferred_complete_from_count:
                completeness.append("count=len+8")
            if frame.is_complete_payload_start:
                completeness.append("full-hex")
            if not completeness:
                completeness.append("header-only")
            stats = "-"
            if payload:
                stats = f"payload={len(payload)}B entropy={shannon_entropy(payload):.2f} printable={printable_ratio(payload):.2f}"
            crc = ", ".join(checksum_matches(frame)) or f"0x{frame.checksum:04X}" if frame.checksum is not None else "-"
            pb = "; ".join(protobuf_probe(payload)) if payload else "-"
            lines.append(
                f"| {frame.score} | {frame.ap_role} | `{Path(frame.source).name}` | `{frame.label()}` | "
                f"{', '.join(completeness)} | {stats} | {crc} | {pb or '-'} |"
            )
        lines.append("")
    else:
        lines.append("## High-Signal Candidates")
        lines.append("")
        lines.append("No incoming 65/67-byte payload candidates were found.")
        lines.append("")

    lines.extend(render_payload_comparison(candidates))

    repeated_headers = Counter(hex_spaced(frame.first8) for frame in a5)
    repeats = [(header, count) for header, count in repeated_headers.items() if count > 1]
    if repeats:
        lines.append("## Repeated A5 Headers")
        lines.append("")
        for header, count in sorted(repeats, key=lambda item: (-item[1], item[0]))[:30]:
            lines.append(f"- `{header}` x{count}")
        lines.append("")

    lines.append("## Interpretation Notes")
    lines.append("")
    lines.append("- Successful BFA7 imports repeatedly show `73B / len=65`; this is now the primary AP-flow response candidate for our device/firmware.")
    lines.append("- Public Xiaomi AI Glasses notes mention a 67-byte Wi-Fi config response; treat `75B / len=67` as an alternate variant, not the only success marker.")
    lines.append("- A candidate being encrypted/noisy is expected; the goal is to identify the session envelope boundary, not replay incoming frames.")
    lines.append("- Rows marked `header-only` came from focused reports that include only the first 8 bytes; use Full HEX or Wi-Fi Credential Candidate reports for payload analysis.")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Analyze BFA7 A5A5 reports")
    parser.add_argument("paths", nargs="+", type=Path, help="ProtocolLab report, JSON export, or pasted text file")
    parser.add_argument("-o", "--output", type=Path, help="Write markdown report to this path")
    parser.add_argument("--ap-json", type=Path, help="Write AP-flow candidate corpus as JSON")
    args = parser.parse_args()

    frames: list[Frame] = []
    for path in args.paths:
        if not path.exists():
            print(f"missing input: {path}", file=sys.stderr)
            return 2
        frames.extend(extract_frames(path))

    if args.ap_json:
        args.ap_json.write_text(json.dumps(ap_candidate_records(frames), indent=2, ensure_ascii=False), encoding="utf-8")

    report = render_report(frames)
    if args.output:
        args.output.write_text(report, encoding="utf-8")
    else:
        print(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
