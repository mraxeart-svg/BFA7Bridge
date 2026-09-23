#!/usr/bin/env python3
"""Extract useful MIWBT/MIWearPB clues from Xiaomi Glasses iOS IPA binaries.

The script is intentionally self-contained and Linux-friendly: it parses enough
Mach-O 64-bit metadata to list sections, symbols and high-signal strings without
depending on macOS `otool`/`nm`/`swift-demangle`.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import re
import struct
from collections import Counter, defaultdict
from pathlib import Path
from typing import Iterable

try:
    from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
except Exception:  # pragma: no cover - optional local analysis dependency
    Cs = None
    CS_ARCH_ARM64 = None
    CS_MODE_ARM = None


MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
LC_ENCRYPTION_INFO = 0x21
LC_ENCRYPTION_INFO_64 = 0x2C

DEFAULT_TARGETS = {
    "app": "Payload/HCWCompanionRelease.app/HCWCompanionRelease",
    "MIWBTCore": "Payload/HCWCompanionRelease.app/Frameworks/MIWBTCore.framework/MIWBTCore",
    "MIWBTModule": "Payload/HCWCompanionRelease.app/Frameworks/MIWBTModule.framework/MIWBTModule",
    "MIWearPB": "Payload/HCWCompanionRelease.app/Frameworks/MIWearPB.framework/MIWearPB",
    "MIWWifiSDK": "Payload/HCWCompanionRelease.app/Frameworks/MIWWifiSDK.framework/MIWWifiSDK",
}

KEYWORDS = [
    "wifiApRequest",
    "wifiApResult",
    "WearWiFiAP",
    "WearPacket",
    "WearSystem",
    "MIWBTReq",
    "MIWBTChannel",
    "MIWChannelPayload",
    "MIWChannelHeader",
    "MIWChannelType",
    "MIWBTOpType",
    "MIWFlowEncrypt",
    "encrypt",
    "decrypt",
    "crc",
    "CRC",
    "payloadData",
    "transmissionData",
    "serializedBytes",
    "NEHotspotConfiguration",
    "CreateWifi",
    "WifiAP",
    "WiFiAP",
]

CATEGORY_PATTERNS = {
    "wifi_ap": re.compile(r"wifi.?ap|WearWiFiAP|NEHotspot|gateway|ssid|password", re.I),
    "wear_packet": re.compile(r"WearPacket|WearSystem|Wear.*ID|TypeEnum|serializedBytes"),
    "transport": re.compile(r"MIWBTReq|MIWBTChannel|MIWChannel|ChannelType|OpType|payloadData|transmissionData"),
    "encryption": re.compile(r"MIWFlowEncrypt|CryptoSwift|AES|encrypt|decrypt|appKey|deviceKey|IV", re.I),
    "crc": re.compile(r"crc|checksum|digest|md5", re.I),
    "swift_protobuf": re.compile(r"SwiftProtobuf|protobuf_nameMap|decodeMessage|traverse|unknownFields"),
}

FUNCTION_PATTERNS = re.compile(
    r"MIWBTReq|MIWBTChannel|MIWChannelPayload|MIWChannelHeader|MIWChannelType|MIWBTOpType|"
    r"MIWFlowEncrypt|encrypt|decrypt|crc16|crc32|CRC32Context|WearPacketV11MIWBTModule|"
    r"wifiApRequest|WearWiFiAP|authAppConfirmToDevice|MIWBTCryptoUtils|aesCCMEncrypt|"
    r"convertPackagetoTransmissionData|transmissionData|payloadData|setEncrypt",
    re.I,
)

PRIORITY_FUNCTION_PATTERNS = re.compile(
    r"MIWFlowEncryptC16createAesContext|MIWFlowEncryptC7encrypt|MIWFlowEncryptC7decrypt|"
    r"MIWBTReqC7timeOut7channel7package|MIWBTReqC32convertPackagetoTransmissionData|"
    r"MIWBTReqC16transmissionData|MIWBTChannelC16transmissionData|"
    r"MIWBTChannelC11payloadData|MIWChannelPayloadC11payloadData|"
    r"MIWBTSessionC10setEncrypt|authAppConfirmToDevice|aesCCMEncrypt",
    re.I,
)


@dataclasses.dataclass
class Section:
    segname: str
    sectname: str
    addr: int
    size: int
    offset: int
    flags: int

    @property
    def label(self) -> str:
        return f"{self.segname},{self.sectname}"


@dataclasses.dataclass
class Symbol:
    name: str
    type: int
    sect: int
    desc: int
    addr: int
    section: str | None = None
    file_offset: int | None = None
    size: int | None = None


@dataclasses.dataclass
class MachOInfo:
    path: Path
    sections: list[Section]
    symbols: list[str]
    symbol_records: list[Symbol]
    encryption: dict[str, int] | None = None


def parse_macho(path: Path) -> MachOInfo:
    data = path.read_bytes()
    if len(data) < 32:
        raise ValueError(f"{path}: too small")
    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from("<IiiIIIII", data, 0)
    if magic != MH_MAGIC_64:
        raise ValueError(f"{path}: unsupported magic 0x{magic:08x}")

    sections: list[Section] = []
    encryption: dict[str, int] | None = None
    symoff = nsyms = stroff = strsize = None
    cursor = 32
    for _ in range(ncmds):
        if cursor + 8 > len(data):
            break
        cmd, cmdsize = struct.unpack_from("<II", data, cursor)
        if cmdsize < 8 or cursor + cmdsize > len(data):
            break
        if cmd == LC_SEGMENT_64:
            segname_raw = data[cursor + 8 : cursor + 24]
            segname = cstr(segname_raw)
            nsects = struct.unpack_from("<I", data, cursor + 64)[0]
            scur = cursor + 72
            for _section_index in range(nsects):
                if scur + 80 > cursor + cmdsize:
                    break
                sectname = cstr(data[scur : scur + 16])
                ssegname = cstr(data[scur + 16 : scur + 32])
                addr, size = struct.unpack_from("<QQ", data, scur + 32)
                offset = struct.unpack_from("<I", data, scur + 48)[0]
                flags = struct.unpack_from("<I", data, scur + 64)[0]
                sections.append(Section(ssegname or segname, sectname, addr, size, offset, flags))
                scur += 80
        elif cmd == LC_SYMTAB:
            symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", data, cursor + 8)
        elif cmd in (LC_ENCRYPTION_INFO, LC_ENCRYPTION_INFO_64):
            cryptoff, cryptsize, cryptid = struct.unpack_from("<III", data, cursor + 8)
            encryption = {"cryptoff": cryptoff, "cryptsize": cryptsize, "cryptid": cryptid}
        cursor += cmdsize

    symbol_records: list[Symbol] = []
    if symoff is not None and stroff is not None and strsize is not None:
        strtab = data[stroff : stroff + strsize]
        for index in range(nsyms or 0):
            off = symoff + index * 16
            if off + 16 > len(data):
                break
            n_strx, n_type, n_sect, n_desc, n_value = struct.unpack_from("<IBBHQ", data, off)
            if 0 < n_strx < len(strtab):
                symbol_records.append(Symbol(
                    name=read_cstr(strtab, n_strx),
                    type=n_type,
                    sect=n_sect,
                    desc=n_desc,
                    addr=n_value,
                ))
    annotate_symbols(symbol_records, sections)
    symbols = [s.name for s in symbol_records]
    return MachOInfo(path=path, sections=sections, symbols=symbols, symbol_records=symbol_records, encryption=encryption)


def cstr(raw: bytes) -> str:
    return raw.split(b"\0", 1)[0].decode("utf-8", "replace")


def read_cstr(data: bytes, offset: int) -> str:
    end = data.find(b"\0", offset)
    if end < 0:
        end = len(data)
    return data[offset:end].decode("utf-8", "replace")


def annotate_symbols(symbols: list[Symbol], sections: list[Section]) -> None:
    for sym in symbols:
        if 1 <= sym.sect <= len(sections):
            section = sections[sym.sect - 1]
            sym.section = section.label
            if section.addr <= sym.addr < section.addr + section.size:
                sym.file_offset = section.offset + (sym.addr - section.addr)

    by_section: dict[str, list[Symbol]] = defaultdict(list)
    for sym in symbols:
        if sym.section and sym.file_offset is not None:
            by_section[sym.section].append(sym)
    for section_label, section_symbols in by_section.items():
        section_symbols.sort(key=lambda s: s.addr)
        section = next((s for s in sections if s.label == section_label), None)
        for index, sym in enumerate(section_symbols):
            next_addr = section_symbols[index + 1].addr if index + 1 < len(section_symbols) else None
            if next_addr is None and section is not None:
                next_addr = section.addr + section.size
            if next_addr is not None and next_addr > sym.addr:
                sym.size = min(next_addr - sym.addr, 4096)


def symbol_row(sym: Symbol) -> dict[str, object]:
    return {
        "name": sym.name,
        "type": f"0x{sym.type:02X}",
        "sect": sym.sect,
        "desc": sym.desc,
        "addr": f"0x{sym.addr:X}",
        "section": sym.section or "",
        "file_offset": "" if sym.file_offset is None else f"0x{sym.file_offset:X}",
        "estimated_size": "" if sym.size is None else sym.size,
    }


def hexdump(data: bytes, base: int = 0) -> str:
    lines: list[str] = []
    for offset in range(0, len(data), 16):
        chunk = data[offset:offset + 16]
        hex_part = " ".join(f"{b:02X}" for b in chunk)
        ascii_part = "".join(chr(b) if 32 <= b <= 126 else "." for b in chunk)
        lines.append(f"{base + offset:08X}  {hex_part:<47}  {ascii_part}")
    return "\n".join(lines)


def nearest_symbol(addr: int, symbols_by_addr: list[Symbol]) -> str:
    best: Symbol | None = None
    for sym in symbols_by_addr:
        if sym.addr > addr:
            break
        if sym.addr == addr:
            return sym.name
        best = sym
    if best is not None and best.size and best.addr <= addr < best.addr + best.size:
        return f"{best.name}+0x{addr - best.addr:X}"
    return ""


def parse_branch_target(op_str: str) -> int | None:
    match = re.search(r"#?0x([0-9a-fA-F]+)", op_str)
    if not match:
        return None
    return int(match.group(1), 16)


def disassemble_arm64(blob: bytes, base_addr: int, symbols: list[Symbol]) -> tuple[list[str], list[dict[str, str]]]:
    if Cs is None:
        return [], []
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    symbols_by_addr = sorted([s for s in symbols if s.addr], key=lambda s: s.addr)
    lines: list[str] = []
    calls: list[dict[str, str]] = []
    for insn in md.disasm(blob, base_addr):
        target = parse_branch_target(insn.op_str) if insn.mnemonic.startswith(("b", "bl")) else None
        target_name = nearest_symbol(target, symbols_by_addr) if target is not None else ""
        suffix = f" ; {target_name}" if target_name else ""
        lines.append(f"0x{insn.address:08X}: {insn.mnemonic:<8} {insn.op_str}{suffix}")
        if insn.mnemonic.startswith("bl"):
            calls.append({
                "addr": f"0x{insn.address:X}",
                "target": "" if target is None else f"0x{target:X}",
                "symbol": target_name,
                "instruction": f"{insn.mnemonic} {insn.op_str}",
            })
    return lines, calls


def function_slices(data: bytes, symbols: list[Symbol]) -> list[dict[str, object]]:
    selected = []
    seen = set()
    for sym in sorted(symbols, key=lambda s: (s.file_offset is None, s.file_offset or 0, s.name)):
        if sym.file_offset is None or not FUNCTION_PATTERNS.search(sym.name):
            continue
        if sym.file_offset in seen:
            continue
        seen.add(sym.file_offset)
        size = sym.size or 192
        if PRIORITY_FUNCTION_PATTERNS.search(sym.name):
            size = max(size, 1024)
        size = max(64, min(size, 4096))
        blob = data[sym.file_offset:sym.file_offset + size]
        disasm_lines, calls = disassemble_arm64(blob, sym.addr, symbols)
        selected.append({
            **symbol_row(sym),
            "slice_size": len(blob),
            "priority": bool(PRIORITY_FUNCTION_PATTERNS.search(sym.name)),
            "calls": calls,
            "hex": blob.hex(" ").upper(),
            "hexdump": hexdump(blob, sym.file_offset),
            "disasm": disasm_lines,
        })
        if len(selected) >= 260:
            break
    return selected


def write_disasm_report(name: str, slices: list[dict[str, object]], out_path: Path, encryption: dict[str, int] | None = None) -> None:
    lines = [f"# {name} relevant ARM64 disassembly", ""]
    if encryption and encryption.get("cryptid"):
        lines.append(f"Mach-O code is FairPlay-encrypted: cryptoff={encryption.get('cryptoff')} cryptsize={encryption.get('cryptsize')} cryptid={encryption.get('cryptid')}.")
        lines.append("Symbols and string metadata are still useful, but function bytes in this IPA cannot be trusted for static disassembly.")
        out_path.write_text("\n".join(lines), encoding="utf-8")
        return
    if Cs is None:
        lines.append("Capstone is not installed; disassembly was skipped.")
        out_path.write_text("\n".join(lines), encoding="utf-8")
        return
    for item in slices:
        disasm = item.get("disasm") or []
        if not disasm:
            continue
        priority = " PRIORITY" if item.get("priority") else ""
        lines.append(f"## {item['name']}{priority}")
        lines.append(f"addr={item['addr']} file_offset={item['file_offset']} size={item['slice_size']} section={item['section']}")
        calls = item.get("calls") or []
        if calls:
            lines.append("calls:")
            for call in calls:
                symbol = call.get("symbol") or "?"
                lines.append(f"- {call['addr']} -> {call['target']} {symbol}")
        lines.append("```asm")
        lines.extend(disasm)
        lines.append("```")
        lines.append("")
    out_path.write_text("\n".join(lines), encoding="utf-8")


def extract_ascii_strings(data: bytes, min_len: int = 4) -> list[str]:
    # Keep Swift/mangled symbol punctuation. This catches cstrings plus many
    # embedded reflection names, without pretending to recover every string.
    pattern = rb"[\x20-\x7e]{%d,}" % min_len
    return [m.group(0).decode("utf-8", "replace") for m in re.finditer(pattern, data)]


def interesting(items: Iterable[str], keywords: Iterable[str] = KEYWORDS) -> list[str]:
    seen = set()
    out: list[str] = []
    lowered = [(k, k.lower()) for k in keywords]
    for item in items:
        low = item.lower()
        if any(k_low in low for _k, k_low in lowered):
            if item not in seen:
                out.append(item)
                seen.add(item)
    return out


def surrounding(strings: list[str], needle_re: re.Pattern[str], radius: int = 5) -> list[dict[str, object]]:
    hits = []
    for i, value in enumerate(strings):
        if needle_re.search(value):
            start = max(0, i - radius)
            end = min(len(strings), i + radius + 1)
            hits.append({"index": i, "hit": value, "context": strings[start:end]})
    return hits


def categorize(strings: Iterable[str]) -> dict[str, list[str]]:
    buckets: dict[str, list[str]] = defaultdict(list)
    seen: dict[str, set[str]] = defaultdict(set)
    for value in strings:
        for name, pattern in CATEGORY_PATTERNS.items():
            if pattern.search(value) and value not in seen[name]:
                buckets[name].append(value)
                seen[name].add(value)
    return dict(buckets)


def compact_mangled_report(symbols: list[str]) -> dict[str, object]:
    type_counts = Counter()
    interesting_symbols = interesting(symbols)
    for sym in symbols:
        for token in (
            "WearPacket",
            "WearSystem",
            "WearWiFiAP",
            "MIWBTReq",
            "MIWBTChannel",
            "MIWChannelPayload",
            "MIWChannelType",
            "MIWBTOpType",
            "MIWFlowEncrypt",
        ):
            if token in sym:
                type_counts[token] += 1
    return {
        "symbol_count": len(symbols),
        "interesting_symbol_count": len(interesting_symbols),
        "type_counts": dict(type_counts),
        "interesting_symbols": interesting_symbols[:500],
    }


def analyze_binary(name: str, path: Path, out_dir: Path) -> dict[str, object]:
    data = path.read_bytes()
    macho = parse_macho(path)
    strings = extract_ascii_strings(data)
    interesting_strings = interesting(strings)
    buckets = categorize(strings + macho.symbols)
    section_rows = [dataclasses.asdict(s) | {"label": s.label} for s in macho.sections]

    symbol_rows = [symbol_row(s) for s in macho.symbol_records]
    relevant_symbol_rows = [row for row in symbol_rows if any(k.lower() in row["name"].lower() for k in [kw.lower() for kw in KEYWORDS])]
    text_is_encrypted = bool(macho.encryption and macho.encryption.get("cryptid"))
    slices = [] if text_is_encrypted else function_slices(data, macho.symbol_records)

    report = {
        "name": name,
        "path": str(path),
        "size": len(data),
        "sections": section_rows,
        "encryption": macho.encryption,
        "symbol_summary": compact_mangled_report(macho.symbols),
        "relevant_symbols_with_offsets": relevant_symbol_rows[:1000],
        "function_slices": slices[:120],
        "string_count": len(strings),
        "interesting_string_count": len(interesting_strings),
        "categories": {k: v[:600] for k, v in buckets.items()},
        "contexts": {
            "wifi_ap": surrounding(strings, re.compile(r"wifi.?ap|WearWiFiAP|NEHotspot", re.I), 8)[:80],
            "channel_payload": surrounding(strings, re.compile(r"MIWChannelPayload|payloadData|transmissionData|MIWBTChannel"), 8)[:100],
            "encryption": surrounding(strings, re.compile(r"MIWFlowEncrypt|CryptoSwift|AES|encrypt|decrypt|appKey|deviceKey|IV", re.I), 8)[:100],
            "protobuf_name_map": surrounding(strings, re.compile(r"protobuf_nameMap|WearSystemV0D2ID|WearPacketV8TypeEnum"), 8)[:120],
        },
    }

    (out_dir / f"{name}.sections.tsv").write_text(tsv(section_rows), encoding="utf-8")
    (out_dir / f"{name}.symbols.txt").write_text("\n".join(macho.symbols), encoding="utf-8")
    (out_dir / f"{name}.symbols.tsv").write_text(tsv(symbol_rows), encoding="utf-8")
    (out_dir / f"{name}.relevant-symbols.tsv").write_text(tsv(relevant_symbol_rows), encoding="utf-8")
    (out_dir / f"{name}.function-slices.json").write_text(json.dumps(slices, ensure_ascii=False, indent=2), encoding="utf-8")
    write_disasm_report(name, slices, out_dir / f"{name}.disasm.txt", macho.encryption)
    (out_dir / f"{name}.strings.txt").write_text("\n".join(strings), encoding="utf-8")
    (out_dir / f"{name}.interesting.txt").write_text("\n".join(interesting_strings), encoding="utf-8")
    (out_dir / f"{name}.report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    return report


def tsv(rows: list[dict[str, object]]) -> str:
    if not rows:
        return ""
    keys = list(rows[0].keys())
    return "\t".join(keys) + "\n" + "\n".join("\t".join(str(row.get(k, "")) for k in keys) for row in rows)


def write_markdown_summary(reports: list[dict[str, object]], out_path: Path) -> None:
    lines = [
        "# BFA7 iOS IPA MIWBT Extraction",
        "",
        "This report is generated from local Xiaomi Glasses iOS IPA binaries. It is static analysis only; App Store FairPlay encryption may hide executable callsites.",
        "",
        "## High-Signal Findings",
        "",
    ]
    for report in reports:
        name = report["name"]
        lines.append(f"### {name}")
        lines.append("")
        lines.append(f"- size: {report['size']} bytes")
        if report.get("encryption"):
            enc = report["encryption"]
            lines.append(f"- encryption: cryptid={enc.get('cryptid')} cryptoff={enc.get('cryptoff')} cryptsize={enc.get('cryptsize')}")
        lines.append(f"- symbols: {report['symbol_summary']['symbol_count']}")
        lines.append(f"- interesting strings: {report['interesting_string_count']} / {report['string_count']}")
        counts = report["symbol_summary"]["type_counts"]
        if counts:
            lines.append("- symbol type counts: " + ", ".join(f"{k}={v}" for k, v in counts.items()))
        for category in ("wifi_ap", "wear_packet", "transport", "encryption", "crc", "swift_protobuf"):
            values = report["categories"].get(category, [])
            if values:
                lines.append(f"- {category}: {len(values)} hits")
                for value in values[:20]:
                    lines.append(f"  - `{value[:180]}`")
        lines.append("")

    lines.extend(
        [
            "## Interpretation",
            "",
            "- `MIWBTReq(timeOut:channel:package:)` and `MIWBTChannel/MIWChannelPayload` symbols confirm a Xiaomi transport layer above plain SwiftProtobuf bytes.",
            "- `MIWFlowEncrypt`/CryptoSwift hits indicate that command payloads may be encrypted after pairing/session setup.",
            "- `WearPacket(system,id:)` extension symbols in `MIWBTModule` suggest official packets set packet `type` and `id`, not just a oneof payload.",
            "- All App Store IPA Mach-O code sections are FairPlay-encrypted when `cryptid=1`; static disassembly from this IPA is intentionally skipped.",
            "- The useful static signal here is exported Swift/protobuf/MIWBT symbol metadata; exact implementation bytes require a decrypted on-device image or dynamic instrumentation.",
            "",
        ]
    )
    out_path.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ipa-root", default="/home/flavor/BFA7-ipa-analysis/extracted", help="Directory containing Payload/...")
    parser.add_argument("--out", default="/home/flavor/BFA7-ipa-analysis/ios-miwbt-extract", help="Output directory")
    args = parser.parse_args()

    root = Path(args.ipa_root)
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    reports = []
    for name, rel in DEFAULT_TARGETS.items():
        path = root / rel
        if path.exists():
            reports.append(analyze_binary(name, path, out_dir))
        else:
            print(f"missing: {path}")

    write_markdown_summary(reports, out_dir / "SUMMARY.md")
    (out_dir / "all-reports.json").write_text(json.dumps(reports, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Wrote {len(reports)} reports to {out_dir}")
    print(out_dir / "SUMMARY.md")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
