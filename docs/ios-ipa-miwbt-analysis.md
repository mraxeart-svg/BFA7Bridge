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

## Next Practical Step

Do not continue blind BLE brute force. The next useful path is to get one of:

- a decrypted on-device iOS image of `MIWBTCore`/`MIWBTModule`;
- a runtime hook trace from Xiaomi app around `MIWBTReq(timeOut:channel:package:)`;
- a dynamic trace of arguments passed to `MIWFlowEncrypt` and `MIWBTSession.setEncrypt`.

Once we have that, BFA7 Bridge can implement the real request path instead of sending guesses.
