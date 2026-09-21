# BFA7Bridge

iOS 17 bridge lab for Xiaomi AI Glasses BFA7.

## Current milestone

BFA7 Bridge is now structured around the free-first plan:

- `GlassesTransport`: BLE scan/connect, GATT explorer, notifications, diagnostic logging, Button Experiment reports, and opt-in HEX command writes.
- `MediaTransfer`: local Wi-Fi/AP media listing and download through the experimental `/v1/filelists` flow.
- `SystemCaptureProbe`: checks whether iOS exposes BFA7 as a system camera/microphone/audio route, based on the Windows DirectShow/sounddevice prototype.
- `CommandSession`: combines a command such as `Опиши что передо мной?` with the latest captured media.
- `AIProvider`: keeps paid OpenAI API disabled and exposes a free ChatGPT handoff feasibility gate.
- `VoiceIO`: push-to-talk audio recording plus Russian voice playback over the active iOS audio route.
- `BFA7AppIntents`: local App Intents for opening Ask/Describe/Stop flows.
- `ProtocolLab`: structured BLE packet capture, `005E` filtering, A5 frame decoding, focused timeline reports, button-candidate reports, JSON/CSV export.
- `WiFiImportLab`: persistent checklist for SSID/IP/ports/protocol notes during Xiaomi Glasses App Import.

## Free-backend gate

This build intentionally does not call the OpenAI API. The free ChatGPT path currently prepares the prompt, copies it to the pasteboard, and opens the ChatGPT app when available. iOS 17 does not provide a public free ChatGPT API that can accept media and return an answer to this app automatically, so the app reports that blocker instead of faking an integration or silently billing API usage.

## First device tests

1. Install on an iPhone with Bluetooth and local network permissions.
2. Use **Device** to find BFA7, connect, read GATT, and capture notifications/button events.
3. For button reverse engineering, run **Button Experiment**: start baseline, wait about 10 seconds, press the physical camera button once, wait about 15 seconds, then copy the experiment report.
4. Use **Lab** to filter `005E`, inspect decoded frames, copy the focused/button-candidate reports, and export JSON/CSV when full payloads are needed.
5. Connect the phone to the glasses Wi-Fi/AP when media transfer is active.
6. Use **Capture** to call `/v1/filelists` and download the latest photo/video.
7. Use **Ask** to prepare `Опиши что передо мной?` with the latest media and run the free gate.

See `docs/chat-context.md` for the preserved reverse-engineering notes from prior ChatGPT sessions, `docs/device-test-notes.md` for findings from real-device diagnostics, and `docs/windows-prototype-analysis.md` for the Windows prototype import analysis.
