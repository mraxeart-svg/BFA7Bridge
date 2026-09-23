# iOS IPA MIWBT Analysis

Generated from Xiaomi Glasses iOS IPA `com.xiaomi.superhexa` version `3.3.0`.

## What The IPA Confirms

- The Wi-Fi AP/import request exists in `MIWearPB` as `WearSystem.wifiApRequest`.
- The AP result exists as `WearSystem.wifiApResult` / `WearWiFiAP.Result`.
- The result model contains `wifiAp`, `ssid`, `password`, and `gateway`.
- The app uses `NEHotspotConfiguration` after the glasses expose the AP.
- The BLE command is not raw `WearPacket` bytes. It goes through `MIWBTCore.MIWBTReq(timeOut:channel:package:)`.
- The transport layer includes `MIWBTChannel`, `MIWChannelPayload`, `MIWChannelType`, and `MIWBTOpType`.
- The paired/session path includes `MIWFlowEncrypt(appKey:appIV:deviceKey:deviceIV:)`, `createAesContext`, `encrypt(data:)`, and `decrypt(data:)`.
- `MIWBTModule` includes auth/bind helpers such as `authAppConfirmToDevice(...)`, `MIWBTCryptoUtils.aesCCMEncrypt(...)`, and HKDF/AES references.

## What This Explains

Our plain candidates were structurally plausible but incomplete:

- raw protobuf `WearPacket(wifiApRequest)` was too low-level;
- A5-wrapped channel candidates were closer, but still did not include the authenticated/encrypted MIWBT session state;
- switching `005F` versus `005E` did not solve it because the problem is likely the session envelope, not only the characteristic.

## FairPlay Limitation

The App Store IPA binaries are FairPlay-encrypted:

- app `cryptid=1`
- `MIWBTCore` `cryptid=1`
- `MIWBTModule` `cryptid=1`
- `MIWearPB` `cryptid=1`
- `MIWWifiSDK` `cryptid=1`

That means symbol names and some metadata are useful, but function bytes from this IPA cannot be trusted for static disassembly. The extractor writes `.disasm.txt` warning files instead of pretending the encrypted code is valid ARM64.

## Generated Reports

Run:

```bash
/home/flavor/BFA7-ipa-analysis/.venv/bin/python tools/extract_ios_ipa_miwbt.py
```

Output directory:

```text
/home/flavor/BFA7-ipa-analysis/ios-miwbt-extract
```

Important files:

- `SUMMARY.md`
- `MIWBTCore.relevant-symbols.tsv`
- `MIWBTModule.relevant-symbols.tsv`
- `MIWearPB.relevant-symbols.tsv`
- `*.disasm.txt`


## Second Surface Pass

A compact surface pass over `Info.plist`, bundled plists/resources, and high-signal symbols found:

- URL schemes: `miGlasses://` and `aimiWear://` are registered, but no clear import/Wi-Fi deep-link route is exposed in plaintext metadata.
- `LSApplicationQueriesSchemes` is mostly third-party/social integrations; it does not expose a Xiaomi import helper app route.
- `NSLocalNetworkUsageDescription` says the app connects to the device to download captured files.
- `NSBonjourServices` contains `_mis._tcp`, but the known glasses media endpoint still appears to be direct HTTP after AP exposure.
- `MIWWifiSDK` contains the normal iOS join layer: `MIWWiFiManager.connect(ssid:password:)`, `getCurrentSSID`, and `MIWWIFINetworkValidator.validateConnection(expectedSSID:expectedIP:)`.
- Wi-Fi/AP protobuf metadata includes `WearWiFiAP.ssid`, `password`, `gateway`, `WearWiFiAP.Request.frequency`, and `WearWiFiAP.Result.code/wifiAp`.
- Mass/media transfer symbols exist (`MIWBTMassService`, CRC32, sync mass methods), but those look like Xiaomi's BLE/mass-transfer subsystem, not the HTTP `/v1/files/...` path we already got working.

This pass did not reveal a plaintext shortcut that bypasses the authenticated MIWBT request path. It strengthens the current model: official import is `BLE authenticated/encrypted AP request -> NEHotspotConfiguration join -> HTTP media download`.

## Next Practical Step

Do not continue blind BLE brute force. The next useful path is to get one of:

- a decrypted on-device iOS image of `MIWBTCore`/`MIWBTModule`;
- a runtime hook trace from Xiaomi app around `MIWBTReq(timeOut:channel:package:)`;
- a dynamic trace of arguments passed to `MIWFlowEncrypt` and `MIWBTSession.setEncrypt`.

Once we have that, BFA7 Bridge can implement the real request path instead of sending guesses.
