# BFA7 device test notes

## 2026-09-21 BLE diagnostic report

Source: Google Doc shared by tester, generated from BFA7 Bridge at 13:19:11.975 local device time.

Observed:

- Bluetooth permission/state worked and the app connected to Xiaomi AI Glasses BFA7.
- GATT discovery found 3 services.
- Notifications/indications were enabled on 6 characteristics.
- Writable characteristics included `FE95/005E`, `FE95/005F`, `AF00/AF07`, and `FD2D/FF11`-`FF13`; the original report duplicated them, so the app now de-duplicates writable entries.
- The named device advertised as `Xiaomi AI Glasses BFA7` with FE95 service data `13 59 81 5A 01 A7 BF 50 C3 34 04`.
- Incoming `005E` traffic uses many `A5 A5` frames. Examples around the experiment:
  - `A5 A5 01 28 00 00 00 00`
  - `A5 A5 01 29 00 00 00 00`
  - `A5 A5 01 2A 00 00 00 00`
  - `A5 A5 01 2B 00 00 00 00`
  - `A5 A5 01 2C 00 00 00 00`
  - `A5 A5 03 ...` payload-start frames, often followed by large continuation payload chunks.

Interpretation for the next build:

- The previous `Possible button/touch event` rule was too broad because every short packet under 16 bytes was marked as button-like.
- `A5 A5 01 NN 00 00 00 00` currently looks like a short control/counter frame, not a confirmed physical button event.
- The next test should rely on the new Protocol Lab frame summary and `Copy button candidates` report rather than the full diagnostic event log.
- Full payload bytes remain available through Lab JSON/CSV; the regular diagnostic report now uses compact previews so copied reports stay readable.
