# BFA7 Bridge Chat Context

This file preserves useful conclusions extracted from the user-provided ChatGPT share links so the project does not depend on those URLs remaining available.

## Button / BLE Experiment

Source share: `https://chatgpt.com/share/6aada2e3-d6d4-83eb-ad9f-97d4038f8fae`

Goal: read the protocol before sending commands to the glasses.

Known observations:

- After connecting BFA7 in the app, the important incoming stream appears on characteristic `005E`.
- Previous camera-button testing showed a large exchange after a physical button press, with packet sizes like `66 B`, `23 B`, `81 B`, `8 B`, `37 B`, repeated `495 B`, then `146 B`.
- The likely frame pattern includes `A5 A5 ...`, but the exact meaning of command/event/sequence/length is not confirmed yet.

Required test flow:

1. Open BFA7 Bridge on iPhone.
2. Connect glasses and read GATT.
3. Confirm `Services`, `Notify/Indicate`, and incoming packets on `005E`.
4. Leave the app connected and idle for about 10 seconds.
5. Press the physical camera button once.
6. Do not press anything else and wait about 15 seconds.
7. Copy the full diagnostic report.

Project implication:

- Add a dedicated Button Experiment mode that marks baseline, marks the physical button press, and exports a focused report around that timestamp.
- Do not use Raw Write during this experiment.

## Wi-Fi Import / Media Transfer

Source share: `https://chatgpt.com/share/6ab0263c-cf5c-83eb-b53b-d3261f4de955`

Correct architecture:

```text
USB-C cable to PC does not expose the iPhone <-> BFA7 Wi-Fi Import traffic.

BFA7 <---- temporary Wi-Fi / Wi-Fi Direct ----> iPhone
                 during Import
```

Important conclusions:

- USB-C to Windows/ZENDUO is not enough to observe the Wi-Fi traffic between iPhone and BFA7.
- Xiaomi appears to use Bluetooth for discovery/coordination and Wi-Fi Direct or a temporary Wi-Fi link for actual media transfer.
- The next reverse-engineering target is the network architecture during Import, not USB, COM4, keyboard, or raw BLE writes.

Data to capture during Import:

1. BFA7 SSID.
2. BFA7 IP address.
3. iPhone IP address.
4. Gateway.
5. DNS if present.
6. Open TCP/UDP ports.
7. Actual protocol: HTTP/TCP/UDP and endpoints.

Preferred test route:

- Passive Wi-Fi capture with a second adapter/monitor if possible.
- Alternative: make Windows a controlled intermediary/hotspot only if the Xiaomi app accepts that topology.

Project implication:

- `MediaTransfer` should remain experimental and endpoint-configurable until real Import network facts are captured.
- If the transfer is HTTP/TCP with file list + metadata + JPEG/MP4 endpoints, implement it directly in BFA7 Bridge and stop relying on Xiaomi Glasses App for import.
