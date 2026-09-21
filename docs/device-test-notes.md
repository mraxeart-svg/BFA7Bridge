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


## 2026-09-21 physical button experiment at 13:45

Source: tester-pasted Button Experiment report generated at 13:45:54.647.

Observed around the manual button mark at `2026-09-21T10:45:38Z`:

- Before the mark, the app saw a small baseline group on `005E` near `-8.735s`: payload-start `seq=0xCA`, short control `seq=0xAD`, and payload-start `seq=0xCB`.
- After the physical button mark, a much larger packet burst starts at about `+0.232s` and runs until about `+0.999s`.
- The burst includes sequential payload-start frames `0xCC...0xD5` and many 495-byte continuation chunks, plus 146-byte tail chunks.
- A later short control frame appears at `+1.130s`: `A5 A5 01 B1 00 00 00 00`; this looks more like a counter/ack after the burst than the physical button itself.
- Smaller follow-up frames appear around `+4.233s` and `+9.235s`.

Interpretation:

- The physical camera button probably does not emit a single obvious BLE button event on `005E`. Instead, it appears to trigger a capture/media payload burst within roughly 250ms.
- For the next build, Protocol Lab should detect and summarize capture-sized bursts around the manual mark. This gives us a better reverse-engineering target than treating every short `A5 A5 01 NN` frame as a button event.
- Next test target: copy `Capture Burst Report`, `Focused Report`, and JSON/CSV only if we need full payload reconstruction.


## 2026-09-21 iOS System Capture test with USB/Bluetooth

Source: tester screenshots from the iPhone app Capture -> System Capture while BFA7 was connected by USB and Bluetooth.

Observed:

- iOS video device list showed only built-in iPhone cameras: back, front, ultra wide, telephoto, dual, dual wide, and triple cameras.
- No `Xiaomi AI Glasses BFA7` or external video camera appeared in AVFoundation.
- Audio input showed `Xiaomi AI Glasses BFA7` with port type `BluetoothHFP`.
- Audio output also showed `Xiaomi AI Glasses BFA7` with port type `BluetoothHFP`.

Interpretation:

- The Windows DirectShow camera path does not currently port directly to iOS, even with USB attached. The iOS app cannot yet treat BFA7 as an AVFoundation camera.
- The BFA7 voice path is confirmed on iOS: the glasses are available as both microphone and speaker through Bluetooth HFP.
- Next implementation target: make Ask explicitly prefer the BFA7 audio route, provide a route report, test voice playback through the glasses, and continue media capture through BLE-trigger + Wi-Fi/AP file transfer.
