# Independent Import: Evidence and Remaining Boundary

Updated 2026-10-02. This supersedes the earlier interpretation of the
type=14/id=5 packet as an AP trigger. It does NOT claim an independently
authenticated hardware import has passed.

## Confirmed AP Exchange

Source: user capture `11a0a068-9d09-4725-aaaa-6483ba25fc66/Pasted text.txt`,
SHA-256 `5236e2c62116843761bb0138707d4aa9f799f5b264210e2f055f6507746905e9`.

| Capture line | UTC time | Observation |
| --- | --- | --- |
| 392 | 2026-09-25 11:53:26.004 | Encryption input `08 02 10 58`, exactly 4 bytes, not 8 bytes padded from a register |
| 419 | 11:53:26.185 | Encryption output, 4 bytes |
| 434 | later BLE write | Same ciphertext in A5 type=3, PB channel `01 02`, FE95/005F; length and CRC16/ARC match |
| 1064 | 11:53:43.380 | Decrypted response type=2/id=88; field path `4/56/2` contains SSID/password/gateway in fields 1/2/3 |
| 1439 | 11:53:52.283 | Former type=14/id=5 candidate occurs AFTER credentials |
| 1487 | 11:53:54.519 | Outgoing type=2/id=89 with AP fields; Android schema names this DISABLE_WIFI_AP |

The local decompiled `SystemMessage.java` names SYSTEM command 88
`ENABLE_WIFI_AP`, command 89 `DISABLE_WIFI_AP`, result field 56 and AP field 57.
This agrees with the iOS capture. The AP result's code is 0. Actual credentials
are intentionally not checked in.

The capture supports using SYSTEM/88 for AP opening. It does not prove that
every firmware permits it without other prerequisites, nor that every later
packet is optional. In particular, do not replay SYSTEM/89 while downloading.

The previous `08 0D 10 06` + `08 0E 10 05 ...` sequence had no demonstrated
causal link to AP opening. It is no longer sent by ImportTool15. The payload
identity of type=14/id=5 remains unassigned here; a method name in a symbols
list alone cannot establish its field map.

Reproduce the redacted check locally:

```sh
python3 tools/audit_import_exchange.py /path/to/capture.txt
```

## Authentication Is a Separate Problem

Source: `4c439fd2-05cd-4f4e-a8d4-1ca931242489/Pasted text.txt`, SHA-256
`db8102d56af3b4143117c27ae3aea29f9eeb51167e208db4831a9e9241f4938f`.

The complete, CRC-valid plaintext exchange in this capture is:

| Account ID | Outgoing account field | Incoming account field | Android schema name |
| --- | --- | --- | --- |
| 16 | 9 | 10 | BOND_APPLY |
| 17 | 11 | 12 | BIND_START_V2 |
| 18 | 13 | 14 | BIND_VERIFY (PSK server/device verify) |
| 19 | 15 | 16 | BIND_CONFIRM (PSK app/device confirm) |
| 25 | 29 | 3 | BIND_RESULT_V2 |

The ID17 response explicitly contains `verifyMode=1` (SERVER_PSK) and
`oobMode=3`. The iOS framework has MIWPskBindOperator and network-proxy
bind methods. This is evidence of a server-assisted binding path, not an
observed token-only AUTH_VERIFY/AUTH_CONFIRM reconnect. It does not establish
that all future reconnects require the cloud.

ImportTool15 currently implements the Android-derived token-auth path:
ID26/27, HKDF-SHA256 with `miwear-auth`, HMAC verification, CCM companion
data, then MIWFlowEncrypt-compatible CTR. That path is STILL EXPERIMENTAL
for these glasses. No captured successful ID26/27 exchange has been found in
the supplied local logs. A successful bind trace is not a substitute for it.

The long-term pairing token, bindKey, session appKey and deviceKey must not
be interchanged. The corrected diagnostic hook reads only the complete
MIWBTPeripheralConfig.token property with a verified field offset. Empty,
unsupported and unreadable strings are reported explicitly; no Swift getter
is called through the C ABI. Hex text is a candidate until a fresh device
signature validates it. Heap-reader tests cannot prove device compatibility.

## Required Independent Flow

### Credential Source: New Static Evidence

The APK's `classes6.dex`, SHA-256
`c5f97dc73f368ad6c8159083f33fbff62173752d702b704ade06a3692ebc2050`,
contains `com.xiaomi.fit.device.extensions.DeviceModelExtKt.convert`
with a `MiWearSourceDevice` argument. Its DEX instructions explicitly call
`getDetail().getEncrypt_key()` and pass the result to
`com.xiaomi.wearable.core.DeviceInfo.setToken`. This was checked in bytecode,
not inferred from the similar field names in a decompiler listing.

`classes9.dex`, SHA-256
`282d0890e833fb4e29407453a93dea1df50df688e2ba8c20378ae438bf378bbc`,
contains the continuation:

- `MiWearDeviceDetail` has SEPARATE `encrypt_key` and `token` properties.
- `BleConnection.getToken()` decodes `DeviceInfo.token` as hexadecimal via
  `ByteUtil.stringToBytes`, then passes those bytes into authentication.
- `WearAuthV2.verify()` uses that key as HKDF input, with the two nonces as
  salt and `miwear-auth` as info.
- The cloud-record converter does not set `appDeviceId`. `WearAuthV2` only
  emits that field when provided. ImportTool15 no longer invents a vendor
  UUID for this identity. Local/OOB authentication is not implemented.

The other `convert(WearableDeviceInfo)` overload branches on device type:
Huami uses `authKey`, local devices use `token`, and other devices use
`encryptKey`. Do NOT generalize one branch to all Xiaomi products.

This identifies the key source in the APK's cloud-record path. It does NOT
prove that a public account API will return this owner's O95 record, that
this path was taken in an iOS capture, or that ID26/27 has passed on hardware.
The selected record still needs a device HMAC check. No real persistent key
has been recovered or verified in this iteration.

ImportTool15 can now load a JSON source record (or `list` / `code,data,list`
envelope) using the Files picker. It accepts exactly one
`miwear.phovideo.o95cn` record and a 16-byte `detail.encrypt_key`, with no
fallback to token, appKey or deviceKey. It never logs the credential. Loading
a record does not authenticate or write to Bluetooth. Validated keys are
stored by CoreBluetooth peripheral UUID, not shared between devices. Old
unscoped Keychain entries are intentionally not automatically migrated,
because their device identity is unknown.

The offline verifier is an additional check, not a token extractor:

```sh
python3 -m pip install -r tools/requirements-import-analysis.txt
python3 tools/verify_miwear_auth.py capture.txt --record private-device-record.json
```

For several O95 entries select one with `--device-id <sid>`. Keep the JSON
private and out of source control. No account password is required by this
tool; it has no network access. It verifies both HMACs, the companion CCM
tag, and a subsequent successful DeviceConfirm. It reassembles split A5
frames and checks CRCs. Reports contain statuses and line numbers, not keys,
nonces, device IDs or decrypted companion information. Missing data returns
unverified, not success. Dynamic-code/OOB mode is explicitly unsupported.

Running the parser on the original binding capture found IDs 16/17/18/19/25
and zero token-auth attempts. The AP capture likewise contained no complete
AUTH26/27 attempt. Synthetic successful/negative tests are not hardware
proof and are clearly separated from these results.

Related public implementations checked:
[Gadgetbridge auth](https://github.com/Freeyourgadget/Gadgetbridge/blob/master/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/xiaomi/XiaomiAuthService.java)
independently uses the same nonce/HKDF/HMAC structure for supported Xiaomi
wearables. [huami-token](https://github.com/argrento/huami-token/blob/master/huami_token/xiaomi.py)
implements Xiaomi account login with SID `miothealth` and a health source-list
endpoint. Neither is proof of an O95 account retrieval contract. Do not
present a watch-cloud login as a verified glasses solution. No code from
these projects was copied into the app.

### Runtime Sequence

1. Obtain/provision this device's persistent pairing material. Offline first
   binding is not established; this is distinct from removing Xiaomi from
   everyday imports.
2. Open FE95, subscribe to 005E, establish and verify a fresh session through
   005F. Never reuse another connection's encrypted packet or temporary key.
3. Encrypt SYSTEM/88 using that session; handle A5 fragments, ACKs and timeout.
4. Accept only a successful SYSTEM/88 result and its structured AP credentials.
5. Request the iOS hotspot connection, then transfer files via the observed
   HTTP service on port 8080. ImportTool15 now probes `/v1/filelists` on that
   port instead of guessing port-80 endpoints. It is still a probe, not an
   end-to-end downloader.
6. Only close the AP after transfers finish. Persist validated pairing
   material in Keychain for reconnects, not in logs or hardcoded frames.

Release acceptance: complete this sequence with Xiaomi force-closed, then
repeat after Bluetooth disconnect, app restart and glasses restart; no
Frida, jailbreak or manually supplied session key during these tests.

## Verification Added

- Redacted capture audit verifies the enable request's encryption output
  against the BLE write and CRC, and exposes binding IDs without secrets.
- Python tests check inline Swift Data length and malformed protobuf.
- Node tests cover the token reader's bounds, exact-string matching, layout
  check and duplicate class aliases. They do not execute on an iPhone.
- macOS CI builds the iOS15.5 app and checks Swift AP parsing, negative cases,
  fragment assembly and a two-block NIST CTR vector. Synthetic vectors from
  an independent Python cryptography implementation check HKDF, HMAC and
  CCM serialization; they do not validate the glasses' authentication path.
- Transport now waits for notification subscription, queues BLE fragments,
  observes backpressure and reports stage timeouts. It does not yet implement
  complete negotiated L1 retransmission/window semantics.
