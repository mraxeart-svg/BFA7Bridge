# BFA7 A5 Protocol Analyzer

This note documents the local analyzer for copied BFA7 Bridge Protocol Lab reports.

## Why This Exists

The Xiaomi AI Glasses import path is not a single raw BLE payload. Public notes and our captures point to a layered flow:

```text
official app type=101/photo sync request
-> authenticated/encrypted Xiaomi transport envelope
-> glasses expose Wi-Fi AP
-> glasses return a Wi-Fi AP config response
-> phone joins AP and downloads media over HTTP
```

The analyzer helps separate evidence from guesses by turning copied reports into a repeatable table of A5A5 frames, lengths, sizes and likely AP credential candidates.

## Tool

```bash
python3 tools/bfa7_a5_analyzer.py path/to/pasted-report.txt
```

Write a markdown report:

```bash
python3 tools/bfa7_a5_analyzer.py path/to/pasted-report.txt -o /tmp/bfa7-a5.md
```

Write a machine-readable AP-flow candidate corpus:

```bash
python3 tools/bfa7_a5_analyzer.py report1.txt report2.txt \
  -o /tmp/bfa7-a5.md \
  --ap-json /tmp/bfa7-ap-corpus.json
```

The input can be:

- a focused Protocol Lab report;
- a paired import witness report;
- a full HEX report;
- a JSON export from Protocol Lab;
- messy pasted text containing `A5 A5 ...` lines.

## What It Extracts

- timeline rows such as `+1.024s | <- FE95/005E | 75 B | A5 A5 03 ...`;
- `HEX:` blocks from full reports;
- JSON `hex` fields;
- bare full A5 byte lines.

For A5A5 frames it parses:

- op/type byte;
- sequence byte;
- little-endian declared payload length;
- two-byte checksum/CRC field;
- payload, when full hex is available.

## High-Signal Candidate Rule

MentraOS notes for Xiaomi AI Glasses report a Wi-Fi AP configuration response after the app triggers photo sync/import. Our successful BFA7 imports repeatedly show the AP-flow response as:

```text
73B packet = 8B A5 header/checksum + 65B payload
A5 A5 03 seq 41 00 xx xx ...
```

Older/adjacent captures also showed a `75B / len=67` frame. Treat that as an alternate variant, not the only success marker.

The analyzer therefore boosts:

- incoming `005E` frames;
- `op=0x03` payload starts;
- declared length `65` as the primary AP-flow candidate;
- declared length `67` as an alternate AP-flow candidate;
- packet sizes `73B` and `75B`;
- rows where `byte_count == declared_length + 8`.

## Current Evidence

Running the analyzer across successful import reports now repeatedly finds:

```text
+2s | <- FE95/005E | 73B | seq varies | len=65 | A5 A5 03 seq 41 00 crc crc ...
```

That is the current primary AP-flow response candidate for this device/firmware. A previous `75B / len=67` frame remains useful historical evidence, but it is no longer required for a successful import.

The payload is noisy/encrypted-looking and changes across sessions, which is consistent with dynamic AP/session data inside an authenticated Xiaomi transport envelope.

## What It Does Not Prove

- A high-signal incoming candidate is not a replayable command.
- Header-only reports cannot decode payload entropy, protobuf fields or checksum variants.
- Encrypted payloads are expected to look noisy; the useful fact is the frame boundary and repeatability across successful sessions.
- The analyzer compares repeated `65B` payloads to show stable and variable byte positions.
- `--ap-json` exports only full-payload AP-flow candidates, so header-only timeline rows do not pollute the decryption corpus.

## Next Capture Format

For the next Xiaomi-app-triggered Import experiment, prefer copying:

1. `BFA7 Import Wi-Fi Credential Candidate Frames`
2. `BFA7 Import Full HEX Report`
3. `BFA7 Paired Import Witness Report`

Those give the analyzer full payload bytes instead of only the first 8 bytes.
