# Windows BFA7 prototype analysis

Source: `BFA7.zip` shared through Yandex Disk on 2026-09-21. The archive was inspected locally under `imports/yandex-bfa7/`; only text source/log files were extracted for analysis, and no prototype scripts were executed.

## What the Windows prototype proved

The working Windows flow was mostly built from standard host OS devices rather than a fully decoded glasses protocol:

- Camera capture used OpenCV/DirectShow: `cv2.VideoCapture(1, cv2.CAP_DSHOW)`.
- Microphone capture used `sounddevice` with `MIC_DEVICE = 14`.
- Voice playback used `sounddevice` with `DEVICE = 13`, apparently the Xiaomi AI Glasses Bluetooth audio route.
- Speech recognition used local `faster_whisper` (`small`, CPU, int8).
- Image + prompt was sent through the OpenAI Python SDK `client.responses.create(...)` with a base64 JPEG data URL.
- TTS tests used both Windows local `System.Speech` / Microsoft Irina and OpenAI TTS, then played the WAV through the BFA7 audio route.

No API key was embedded in the extracted source; scripts rely on `OPENAI_API_KEY` from the environment when OpenAI API is used.

## What ports directly to iOS

- Push-to-talk UX: record a short command, transcribe, pair it with latest capture, speak a short Russian answer.
- Audio route idea: if iOS routes Bluetooth audio to the glasses, `AVAudioSession` + `AVSpeechSynthesizer` can play responses through the active route.
- Local/free STT idea: the Windows prototype used local Whisper, so a future iOS build can evaluate on-device/local transcription instead of paid OpenAI transcription.
- Camera-device probe idea: Windows found the glasses as a system camera. The iOS app should explicitly test whether AVFoundation exposes BFA7 as a video capture device.

## What does not port one-to-one

- Windows DirectShow camera index `1` is not an iOS concept. iOS must use `AVCaptureDevice.DiscoverySession`.
- Windows `sounddevice` indexes `13` and `14` are not stable across platforms. iOS must use `AVAudioSession` current route and available inputs.
- Bluetooth RFCOMM/COM port probing does not map directly to public iOS APIs. iOS BLE via CoreBluetooth is available; arbitrary Bluetooth Classic/RFCOMM generally needs system profile support or MFi/External Accessory access.
- The OpenAI API part violates the project free-first constraint unless explicitly approved later. It is useful as a behavioral prototype, not as the default backend.

## Added iOS follow-up

The app now includes a System Capture diagnostic section in the Capture tab. It lists:

- AVFoundation video devices, including external devices if the OS exposes them.
- AVAudioSession available inputs.
- Current audio route outputs.

The next physical-device test should connect BFA7 over Bluetooth/USB as before, open Capture -> System Capture, tap `Request access`, then send the visible device list. If BFA7 appears as a video device, we can add a direct still-photo capture path. If it does not, the iOS media path remains BLE-trigger + Wi-Fi/AP media download.
