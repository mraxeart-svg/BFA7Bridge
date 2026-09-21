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


## 2026-09-21 BFA7 HFP route confirmed during recording

Source: tester-pasted `BFA7 Audio Route Report` generated while recording.

Observed:

- Status was `Идёт запись`.
- Current input was `Xiaomi AI Glasses BFA7 | BluetoothHFP | 04:34:C3:50:BF:A7-tsco`.
- Current output was `Xiaomi AI Glasses BFA7 | BluetoothHFP | 04:34:C3:50:BF:A7-tsco`.
- Available inputs were built-in iPhone microphone and BFA7 Bluetooth HFP.

Interpretation:

- iOS can use BFA7 as both push-to-talk microphone and voice-response speaker.
- The next diagnostic build records file duration, file size, average level, and peak level after `Stop recording` so we can confirm the captured audio is non-empty and coming through the selected route.


## 2026-09-21 non-empty BFA7 recording confirmed

Source: tester-pasted `BFA7 Audio Route Report` generated after stopping playback.

Observed:

- Current input and output were both `Xiaomi AI Glasses BFA7` over `BluetoothHFP`.
- The app recorded `push-to-talk-1789990420.m4a` with duration `5.15s` and size `81631B`.
- Metering showed signal in the file: average `-39.9 dB`, peak `-8.4 dB`.
- Xiaomi Glasses app push notifications reported that the microphone was occupied / recording was active, which matches BFA7 Bridge owning the HFP microphone during push-to-talk.

Interpretation:

- The iOS push-to-talk path is not just selecting a route; it is capturing non-empty audio from the glasses.
- Next implementation target is local/free command transcription through iOS Speech so the latest BFA7 recording can become the Ask command without using paid OpenAI API calls.


## 2026-09-21 BFA7 speech transcription confirmed

Source: tester report after installing the Speech build.

Observed:

- A spoken phrase recorded through the BFA7 Bluetooth HFP microphone was recognized correctly by iOS Speech.

Interpretation:

- The free/local command intake path is now proven through iOS system speech recognition: BFA7 mic -> app recording -> transcription -> Ask command text.
- The next UI refinement is a one-tap action that transcribes the latest recording and prepares the command/media payload for the free ChatGPT handoff.


## 2026-09-21 BFA7 media download confirmed

Source: tester screenshot after starting Import in the Xiaomi Glasses app, accepting the temporary `Xiaomi AI Glasses BFA7` Wi-Fi connection, then using BFA7 Bridge Capture.

Observed:

- `Download latest file` succeeded through `http://192.168.43.1:8080`.
- Latest downloaded file displayed as `VID_20260919220615`, size `22.4 MB`, downloaded.
- The file list included at least `VID_20260919220615` (`22.4 MB`) and `VID_20260919220316` (`445.4 MB`).
- A later file-list report confirmed `GET /v1/filelists` returns HTTP `200`, MIME `text/plain`, suggested filename `filelists.txt`, and JSON/plain payload bytes `2056`.
- The parsed photo entries used display names like `IMG_20260921151123206` while download paths used `filelists/LLHDR_20260921151123206_4032x3024_5`, with sizes around `31-35 MB`.

Interpretation:

- The media-transfer half is real when the glasses are put into Import mode by the official app.
- BFA7 Bridge should now infer media type from filename/MIME/file signature and offer a share/export route for the downloaded file.
- Remaining reverse-engineering target: identify the BLE command sequence that starts Import mode without opening the official Xiaomi Glasses app.


## 2026-09-21 Wi-Fi Probe build

Implementation note:

- Capture now includes an editable Wi-Fi Probe path list saved in `UserDefaults`, plus `Run probe` and `Copy probe report`.
- Probe results capture URL, HTTP status, MIME, suggested filename, byte count, signature, short preview, and errors.
- This is intended to reduce IPA churn: future endpoint experiments can be run from the installed app by editing paths on-device.


## 2026-09-21 HTTP 404 download guard

Tester screenshot showed a failed `/filelists/LLHDR...` request being saved as a tiny `.txt` "photo" because `URLSession.download` does not throw for HTTP 404.

Implementation note:

- Downloads now reject non-2xx HTTP statuses instead of saving error bodies as media.
- Download attempts now try fallback extensions for extensionless remote paths, such as `.jpg`, `.heic`, and `.jpeg` for photo entries.
- Failed download reports include every candidate URL plus HTTP status, MIME, byte count, signature, and body preview.


## 2026-09-21 Import Lab build

Implementation note:

- Lab now includes an `Import Lab` section for the next reverse-engineering milestone: finding the BLE/Wi-Fi trigger used by Xiaomi Glasses Import mode.
- The flow is `Start import experiment` -> switch to Xiaomi app -> press Import -> return and `Mark Xiaomi Import press` -> accept Wi-Fi -> `Run Wi-Fi probe` -> copy import and probe reports.
- The import report includes scoped BLE events, protocol activity grouped by characteristic, packet timeline, and capture-burst heuristics around the import mark.
- This is intended to identify candidate BLE notifications/writes before attempting replay presets.


## 2026-09-21 Import full HEX reports

Implementation note:

- Import Lab now provides `Copy import full HEX`, `Copy replay candidates`, and `Copy import JSON`.
- Replay candidate reports are intentionally labeled as observed incoming BLE packets, not confirmed Xiaomi-app write commands.
- These reports preserve complete packet hex for the 73B/75B import-adjacent payloads that were previously truncated in the event log.


## 2026-09-21 Latest file URL and method probes

Implementation note:

- Capture now includes `Probe latest file URLs`, which refreshes `/v1/filelists`, takes the current first media entry, and probes its `remotePath`, extension fallbacks, and thumbnail candidates.
- Capture also includes editable `Method probe paths` plus `Run method probe`, testing `GET`, `HEAD`, `POST {}`, and `OPTIONS` for each path.
- This supports the three media routes: import-mode download, automatic latest-file fetch after capture/import, and live/alternate endpoint discovery.


## 2026-09-21 Fresh photo endpoint probes

Source: tester-pasted latest file and method probe reports generated around 16:24 local time.

Observed:

- `GET /v1/filelists` still returns a fresh JSON/plain list of current import-session photo entries.
- Direct fresh-photo candidates for `filelists/LLHDR_..._4032x3024_5`, `.jpg`, `.heic`, `.jpeg`, and thumbnail variants all returned HTTP `404`.
- `GET /v1/files` and `POST /v1/files` returned HTTP `405`; `OPTIONS /v1/files` returned HTTP `403` with `Invalid CORS request`.
- `GET /v1/media` remained `404`; `POST /v1/filelists` was `405`; `OPTIONS /v1/filelists` was `403`.

Interpretation:

- The photo list is reliable, but the photo payload is probably behind a route or request shape we have not found yet.
- The app now needs query-aware URL construction and a configurable latest-file template probe so we can test routes like `/v1/files?url={remote}` or `POST /v1/files | {json}` without shipping a new IPA for every hypothesis.


## 2026-09-21 Latest template probe result

Source: tester-pasted `BFA7 Latest Template Probe` generated at `2026-09-21T13:34:10Z`.

Observed:

- Query forms such as `/v1/files?url=...`, `/v1/files?path=...`, `/v1/files?name=...`, and `/v1/files?identifier=...` returned HTTP `405` because GET is not supported on `/v1/files`.
- `/v1/filelists/<LLHDR...>` and `/v1/filelists/<LLHDR...>.jpg` returned HTTP `200` but `0` bytes, so this route is likely a marker/prepare endpoint or an empty response, not the media payload.
- `/v1/files/<LLHDR...>` and `/v1/files/<LLHDR...>.jpg` did not return `404`; the probe saw `The network connection was lost`. This is now the strongest download candidate because the lightweight probe uses a short timeout and a Range request.

Implementation note:

- Real downloads now prioritize `/v1/files/<remoteLeaf>` and `/v1/files/<identifier>` before the older direct `filelists/...` candidates.
- Downloads reject empty successful responses so a `200`/`0 B` response cannot be saved as a fake media file.


## 2026-09-21 LLHDR bundle manifest decoded

Source: tester shared `LLHDR_20260921163246083_4032x3024_5.txt` from Yandex Disk.

Observed:

- The downloaded `.txt` is valid JSON, not a photo payload.
- It contains the contents of an LLHDR bundle folder: metadata/exif/icc sidecars and several `.heic` image parts.
- Largest media entries include HEIC files around `7.4 MB`, `7.39 MB`, `7.41 MB`, `5.0 MB`, and `2.79 MB`.

Interpretation:

- BFA7 photo entries from `/v1/filelists` are folders/bundles. Downloading `/v1/filelists/<LLHDR...>` yields the bundle manifest.
- The app should treat this manifest as an intermediate response, choose nested media files, and then download the inner HEIC payload candidates.


## 2026-09-21 LLHDR HEIC download confirmed

Source: tester-pasted `BFA7 File Download` generated at `2026-09-21T13:58:40Z`.

Confirmed working endpoint:

- `GET /v1/files/LLHDR_20260921162200811_4032x3024_5-ARCLLHDR_20260921162200811_4032x3024_ev0_4.heic`
- HTTP `200`
- MIME `image/heic`
- signature `ftypheic`
- downloaded size `7,786,908` bytes (`7.8 MB`)

Interpretation:

- The BFA7 photo flow is now proven on iPhone: `/v1/filelists` -> LLHDR bundle manifest -> inner HEIC through `/v1/files/<inner-heic-name>`.
- The successful inner file path is flat under `/v1/files/`, not nested as `/v1/files/<bundle>/<inner>`.
- Next product step is reducing the manual flow to one action: download latest glasses media and prepare the Ask payload.


## 2026-09-21 autonomy target: Xiaomi-free import mode

Current state:

- Media download is proven once Xiaomi Glasses App has started Import/AP mode.
- Closing Xiaomi Glasses App during transfer does not immediately stop the glasses Wi-Fi AP, suggesting the official app mainly sends the start-import trigger and iOS Wi-Fi join request.
- BFA7 Bridge can continue HTTP media transfer from the glasses while the AP remains up.

Remaining blocker:

- We do not yet know the BLE write command that starts Import/AP mode. Current Import Lab logs are BFA7 Bridge's incoming notifications from the glasses, not Xiaomi-app write traffic.

Implementation note:

- Lab now includes an `Import Trigger` write section with an explicit target characteristic and HEX candidate.
- `Write + Wi-Fi probe` writes the candidate and then refreshes `/v1/filelists`, giving a quick success/failure signal.
- Use this only with candidates captured from a real Xiaomi-app write source, such as Android Bluetooth HCI snoop, a BLE sniffer, or a Windows prototype log that includes outgoing writes.


## 2026-09-21 APK CreateWifiAP candidate

Source: static analysis of Xiaomi Glasses APK bundle supplied by tester. The bundle contains `com.xiaomi.superhexa.apk`; relevant classes were found in `classes6.dex` and `classes7.dex`.

Findings:

- The official app has a `SendCreateWifiAP` command strategy.
- `CreateWifiAP` command type bytes in enum `u1/d` are `00 02`.
- `SendCreateWifiAP.getContentData()` builds three bytes: `01 <wifiType> 01`.
- `SVBaseCommandStrategy.getData(seq)` prepends the command `seq` byte for encrypted commands, so the candidate payload shape is `<seq> 00 02 01 <wifiType> 01`.
- The Android seq generator starts at `0x80`; the first generated seq is `0x81`, then it increments and wraps.
- The BLE sender writes `command.d()` directly through Nordic `writeCharacteristic` with Android write type `2` (default/write-with-response). No extra packet wrapper was visible in the generic sender path.

Implementation note:

- Lab now includes an APK-derived CreateWifiAP candidate builder with editable `seq` and `wifiType` (`0...4`).
- This is still experimental: success is defined only by the glasses starting the Wi-Fi AP and `/v1/filelists` becoming reachable from BFA7 Bridge.
- Android hardware is not required for the next test; Windows GATT is also not required because the iPhone app can write the candidate over CoreBluetooth.


## 2026-09-21 Import Lab control fix

Tester observed that `Write APK CreateWifiAP + probe` becomes disabled after a failed/manual probe path because it is gated by `media.isBusy`. The BLE write itself should remain available while Wi-Fi probing is busy or stuck.

Implementation note:

- Split the APK-derived action into `Write APK only` and `Write APK + probe`.
- `Write APK only` is disabled only by the explicit safety toggle, so candidate testing can continue even when media probing is busy.
- `Write APK + probe` remains gated by `media.isBusy` because it starts an HTTP transfer/probe.


## 2026-09-21 APK trigger auto scanner

Rationale:

- Manual candidate testing is too slow and easy to mis-click, especially when Wi-Fi probing makes probe buttons temporarily disabled.
- The next experiment should rapidly test the APK-derived `CreateWifiAP` payload shape across likely write targets and `wifiType` values.

Implementation note:

- Import Lab now has an `Auto trigger scanner`.
- Default targets: `FE95/005E` and `FE95/005F`.
- Scan order per target: `wifiType` values `2, 3, 4, 1, 0`.
- Each attempt writes `<seq> 00 02 01 <wifiType> 01`, increments `seq`, waits a configurable delay, then performs a quick `/v1/filelists` check with a short timeout.
- Success means the BFA7 HTTP endpoint is reachable, even if the returned file list is empty. That proves Import/AP mode was started or already active.


## 2026-09-21 Broad import trigger scanner

Tester result: first automated scan over the APK-derived `apkSeq` payload on `FE95/005E` and `FE95/005F` finished with no matches.

Interpretation:

- The command may use a different writable characteristic. Known writable candidates include `AF00/AF07` and `FD2D/FF11`-`FF13`.
- The APK-derived command may require a slightly different payload shape than `<seq> 00 02 01 <wifiType> 01`.
- A higher-level channel/handshake may still be required, but a broader BLE write scan is the next cheapest experiment.

Implementation note:

- Auto scanner now defaults to `FE95/005E`, `FE95/005F`, `AF00/AF07`, `FD2D/FF11`, `FD2D/FF12`, and `FD2D/FF13`.
- The UI can replace the target list with currently discovered writable characteristics.
- Payload variants now include: `apkSeq`, `noSeq`, `seqNoTail`, `noSeqNoTail`, `seqTypeOnly`, and `noSeqTypeOnly`.
- The scan report keeps the latest attempt lines visible while retaining full success context if a match is found.
