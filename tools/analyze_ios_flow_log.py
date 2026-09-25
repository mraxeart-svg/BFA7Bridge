#!/usr/bin/env python3
"""Summarize Xiaomi iOS Frida flow logs for BFA7 import research."""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from pathlib import Path


FLOW_RE = re.compile(
    r"\[BFA7-iOS-FLOW (?P<ts>[^\]]+)\] FLOW (?P<phase>.*?)"
    r"MIWFlowEncrypt\.(?P<op>encrypt|decrypt)\(data:\).*?"
    r"swiftdata-x1-slot\+16 candidate=[^ ]+ len=(?P<len>\d+) "
    r"(?P<hex>(?:[0-9A-F]{2} ?)+)\((?P<len2>\d+) bytes\) ascii=(?P<ascii>.*)$"
)
INLINE_RE = re.compile(
    r"\[BFA7-iOS-FLOW (?P<ts>[^\]]+)\] FLOW (?P<phase>.*?)"
    r"MIWFlowEncrypt\.(?P<op>encrypt|decrypt)\(data:\).*?"
    r"swiftdata-inline x0-le=(?P<hex>(?:[0-9A-F]{2} ?)+) ascii=(?P<ascii>.*?) "
)
CB_WRITE_RE = re.compile(
    r"\[BFA7-iOS-FLOW (?P<ts>[^\]]+)\] CB WRITE "
    r"characteristic=(?P<char>[A-F0-9/]+).*? len=(?P<len>\d+) "
    r"hex=(?P<hex>(?:[0-9A-F]{2} ?)+)\((?P<len2>\d+) bytes\) ascii=(?P<ascii>.*)$"
)
CB_NOTIFY_RE = re.compile(
    r"\[BFA7-iOS-FLOW (?P<ts>[^\]]+)\] CB NOTIFY .*?"
    r"characteristic=(?P<char>[A-F0-9/]+).*? len=(?P<len>\d+) "
    r"hex=(?P<hex>(?:[0-9A-F]{2} ?)+)\((?P<len2>\d+) bytes\) ascii=(?P<ascii>.*)$"
)
HOTSPOT_RE = re.compile(
    r"\[BFA7-iOS-FLOW (?P<ts>[^\]]+)\] HOTSPOT config ssid=.*?: (?P<ssid>.*?) "
    r"passphrase=.*?: (?P<passphrase>\S+)"
)


@dataclass
class Event:
    line: int
    ts: str
    kind: str
    length: int
    hex_text: str
    ascii_text: str
    tag: str


def normalize_hex(hex_text: str) -> str:
    return " ".join(hex_text.strip().split())


def classify(hex_text: str, ascii_text: str, kind: str) -> str:
    compact = normalize_hex(hex_text)
    if "Xiaomi AI Glasses" in ascii_text and "192.168.43.1" in ascii_text:
        return "wifi-credentials"
    if compact.startswith("08 0E 10 05 82 01 0E 2A 0C"):
        return "wifi-ap-trigger"
    if "LLHDR_" in ascii_text:
        return "media-file"
    if "AlipayGGlasses" in ascii_text or "PaySDK" in ascii_text:
        return "paysdk-noise"
    if "Europe/" in ascii_text:
        return "time-sync"
    if compact.startswith("A5 A5 03") and kind == "write":
        return "wrapped-write"
    if compact.startswith("A5 A5 01") and kind == "write":
        return "ack-write"
    return "other"


def truncate(value: str, limit: int = 120) -> str:
    value = value.replace("\r", "").replace("\n", "")
    if len(value) <= limit:
        return value
    return value[: limit - 3] + "..."


def parse_log(path: Path) -> tuple[list[Event], list[tuple[int, str, str, str]]]:
    events: list[Event] = []
    hotspots: list[tuple[int, str, str, str]] = []

    for line_no, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        if m := FLOW_RE.search(line):
            phase = m.group("phase").strip() or "ARG"
            kind = f"{phase} {m.group('op')}".strip()
            hex_text = normalize_hex(m.group("hex"))
            ascii_text = m.group("ascii")
            events.append(
                Event(
                    line_no,
                    m.group("ts"),
                    kind,
                    int(m.group("len")),
                    hex_text,
                    ascii_text,
                    classify(hex_text, ascii_text, kind),
                )
            )
            continue

        if m := INLINE_RE.search(line):
            phase = m.group("phase").strip() or "ARG"
            kind = f"{phase} {m.group('op')} inline".strip()
            hex_text = normalize_hex(m.group("hex"))
            ascii_text = m.group("ascii")
            if hex_text.startswith(("08 ", "F9 ")):
                events.append(
                    Event(
                        line_no,
                        m.group("ts"),
                        kind,
                        len(hex_text.split()),
                        hex_text,
                        ascii_text,
                        classify(hex_text, ascii_text, kind),
                    )
                )
            continue

        for regex, kind in ((CB_WRITE_RE, "write"), (CB_NOTIFY_RE, "notify")):
            m = regex.search(line)
            if not m:
                continue
            hex_text = normalize_hex(m.group("hex"))
            ascii_text = m.group("ascii")
            events.append(
                Event(
                    line_no,
                    m.group("ts"),
                    f"{kind} {m.group('char')}",
                    int(m.group("len")),
                    hex_text,
                    ascii_text,
                    classify(hex_text, ascii_text, kind),
                )
            )
            break

        if m := HOTSPOT_RE.search(line):
            hotspots.append((line_no, m.group("ts"), m.group("ssid"), m.group("passphrase")))

    return events, hotspots


def print_events(events: list[Event], tags: set[str], all_events: bool) -> None:
    for event in events:
        if not all_events and event.tag == "other":
            continue
        if tags and event.tag not in tags:
            continue
        print(f"L{event.line} {event.ts} [{event.tag}] {event.kind} len={event.length}")
        print(f"  HEX: {event.hex_text}")
        if event.ascii_text.strip(". "):
            print(f"  ASCII: {truncate(event.ascii_text)}")


def print_encrypt_pairs(events: list[Event], all_events: bool) -> None:
    pending: Event | None = None
    pairs: list[tuple[Event, Event]] = []

    for event in events:
        if "encrypt" not in event.kind:
            continue
        if "LEAVE" in event.kind:
            if pending and pending.length == event.length and event.line - pending.line < 40:
                pairs.append((pending, event))
            pending = None
        else:
            pending = event

    interesting = [
        (plain, cipher)
        for plain, cipher in pairs
        if all_events or plain.tag != "other" or "LLHDR_" in plain.ascii_text
    ]
    if not interesting:
        return

    print("\nEncrypt pairs:")
    for plain, cipher in interesting:
        print(f"L{plain.line}->L{cipher.line} [{plain.tag}] len={plain.length}")
        print(f"  PLAIN:  {plain.hex_text}")
        print(f"  CIPHER: {cipher.hex_text}")
        if plain.ascii_text.strip(". "):
            print(f"  ASCII:  {truncate(plain.ascii_text)}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path, help="Frida flow log path")
    parser.add_argument("--all", action="store_true", help="include unclassified payloads")
    parser.add_argument("--tag", action="append", default=[], help="filter by tag")
    args = parser.parse_args()

    events, hotspots = parse_log(args.log)
    tags = set(args.tag)

    print(f"log={args.log}")
    print(f"events={len(events)} hotspots={len(hotspots)}")

    if hotspots and not tags:
        print("\nHotspot configs:")
        for line, ts, ssid, passphrase in hotspots:
            print(f"L{line} {ts} ssid={ssid!r} passphrase={passphrase!r}")

    print("\nInteresting events:")
    print_events(events, tags, args.all)
    if not tags:
        print_encrypt_pairs(events, args.all)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
