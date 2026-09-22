# Windows USB Inspection

This is a diagnostic path for the Xiaomi AI Glasses BFA7 project. It helps identify what the glasses expose to Windows over USB/Bluetooth/network so we can compare it with the iOS bridge path.

## Run

1. Connect Xiaomi AI Glasses BFA7 to the Windows PC over USB.
2. Keep Bluetooth paired if that was part of the working PowerShell flow.
3. Open PowerShell.
4. Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\bfa7-windows-collector.ps1
```

The script creates a folder and zip on the Desktop:

```text
Desktop\BFA7-Windows-Report\<timestamp>
Desktop\BFA7-Windows-Report\<timestamp>.zip
```

Send the zip/report back into the chat.

## What We Are Looking For

- Whether the glasses expose MTP/PTP camera storage, mass storage, ADB, serial, HID, RNDIS/network, or only Bluetooth audio/BLE.
- USB VID/PID and interface classes.
- Whether a Windows-only media path exists that explains the earlier working PowerShell prototype.
- Any network adapter/IP route that could reveal a USB equivalent of the Wi-Fi media API.

## Important

This collector reads device metadata. It does not copy photos/videos by default.
