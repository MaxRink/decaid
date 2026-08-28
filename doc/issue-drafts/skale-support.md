# Skale support issue drafts

These drafts are intentionally split by behavior and grouped into bug fixes and
new features. They can be accepted, labeled, and implemented independently even
though the research branch demonstrates them together.

## Bug fixes

### Fix Skale weight decoding for current Atomax SDK frames

Filed as [decentespresso/decaid#712](https://github.com/decentespresso/decaid/issues/712).

#### Problem

Decaid decodes every Skale weight notification as a four-byte little-endian
integer divided by 2560. Current and legacy Atomax SDK binaries instead decode a
signed 24-bit little-endian mantissa followed by a signed base-10 exponent. The
existing decoder can therefore produce incorrect weights for SDK-format frames.

This is not a claim that normal readings are currently wrong on every Skale.
The observed R029 scale displays plausible values in Decaid, including shots of
about 40 g. Ordinary gram notifications appear to use exponent `-1`, the one
case where the inherited decoder produces the same result by coincidence. The
bug is that Decaid assumes that coincidence is the protocol and cannot correctly
handle another valid exponent if firmware or measurement mode emits one.

#### Proposed fix

- Decode five-byte SDK frames using the signed mantissa and exponent format.
- Retain the existing four-byte `/2560` decoder as a compatibility fallback for
  devices or captures using Decaid's historical representation.
- Ignore truncated notifications without changing existing connection policy.

#### Examples

For an SDK-format notification, byte 0 is not part of the number, bytes 1..3
are the signed little-endian mantissa, and byte 4 is the signed exponent:

| Frame | Mantissa | Exponent | Correct weight | Existing decoder |
|---|---:|---:|---:|---:|
| `00 D2 04 00 FE` | 1234 | -2 | 12.34 g | 123.4 g |
| `00 C9 FD FF FF` | -567 | -1 | -56.7 g | -56.7 g |
| `00 7B 00 00 01` | 123 | 1 | 1230 g | 12.3 g |

The exponent `-1` case happens to match because the old little-endian
four-byte interpretation shifts the mantissa by eight bits and then divides by
2560, which is equivalent to dividing by 10. That coincidence masks the bug for
common one-decimal frames—including the observed approximately 40 g shots—but
does not implement the SDK format.

The historical four-byte fallback remains independently testable: `00 0A 00
00` is integer 2560 little-endian and therefore remains 1.0 g under the legacy
decoder.

#### Acceptance criteria

- Positive, negative, fractional, and positive-exponent SDK frames decode
  correctly.
- Historical four-byte frames retain their current values.
- Existing tare, timer, display, and reconnect behavior is unchanged.

#### Evidence

- [de1app's exponent-`-1` Skale decoder](https://github.com/decentespresso/de1app/blob/24851f5b1b0faf77b92fdd837b2932a8d8e26e15/de1plus/bluetooth.tcl#L2997-L3001)
- [Current iOS SDK weight callback API](https://github.com/atomaxinc/SkaleKit/blob/624c07436a577706dcc26cb2d62ca76ad18f7da9/Distribution/SkaleKit.xcframework/ios-arm64/SkaleKit.framework/Headers/SKSkale.h#L43-L53)
- [Flutter SDK forwarding the native iOS weight callback](https://github.com/atomaxinc/SkaleKit-flutter/blob/7df4a9d9bd975367c3ac27502323225ac61b116d/ios/Classes/SkaleKitPlugin.swift#L252-L258)
- [Exact current iOS decoder artifact](https://github.com/atomaxinc/SkaleKit/blob/624c07436a577706dcc26cb2d62ca76ad18f7da9/Distribution/SkaleKit.xcframework/ios-arm64/SkaleKit.framework/SkaleKit)

Atomax distributes the native decoder as a binary rather than public source.
The mantissa/exponent layout is therefore derived from inspecting that exact
commit-pinned artifact; the public wrappers only expose the decoded float.

### Make Skale battery reporting nullable and refresh it while connected

Filed as [decentespresso/decaid#713](https://github.com/decentespresso/decaid/issues/713).

#### Problem

Skale battery data is currently initialized as `0%` and read only once. A failed
or unsupported read is therefore indistinguishable from an empty battery, and a
long-running connection never refreshes its value. Some Atomax firmware also
reports a fixed `100%`, so the value must remain explicitly device-reported.

Battery reporting does work on the observed R029 scale: the official Skale app
reported 82%, and Decaid reported 80% after reconnecting. The bug is therefore
not “R029 has no usable battery data”; it is Decaid's unavailable/error semantics
and lack of refresh during a long-lived connection. The historical fixed-`100%`
behavior should remain documented as firmware-generation-specific rather than
generalized to current units.

#### Proposed fix

- Represent unavailable battery data as `null`, not `0%`.
- Validate the Bluetooth Battery Level value as `0..100`.
- Read on connect and refresh every 30 minutes without overlapping reads.
- Clear connected-session battery metadata on disconnect.
- Treat read failures as best-effort metadata failures, not connection failures.

#### Acceptance criteria

- Failed, empty, and out-of-range reads do not publish a percentage.
- Valid reads appear in the Devices UI and nested REST/WebSocket `deviceInfo`.
- Battery metadata refreshes while connected and disappears on disconnect.

#### Evidence

- [iOS battery callback and read API](https://github.com/atomaxinc/SkaleKit/blob/624c07436a577706dcc26cb2d62ca76ad18f7da9/Distribution/SkaleKit.xcframework/ios-arm64/SkaleKit.framework/Headers/SKSkale.h#L26-L28)
- [iOS battery read method](https://github.com/atomaxinc/SkaleKit/blob/624c07436a577706dcc26cb2d62ca76ad18f7da9/Distribution/SkaleKit.xcframework/ios-arm64/SkaleKit.framework/Headers/SKSkale.h#L81-L85)
- [Android battery callback documentation](https://github.com/atomaxinc/SkaleKitAndroid/blob/faae8a96879f45c935712c11f25674e4d5dc9e82/README.md#L52-L62)
- [Android battery request documentation](https://github.com/atomaxinc/SkaleKitAndroid/blob/faae8a96879f45c935712c11f25674e4d5dc9e82/README.md#L99-L109)
- [de1app's historical fixed-100% firmware note](https://github.com/decentespresso/de1app/blob/24851f5b1b0faf77b92fdd837b2932a8d8e26e15/de1plus/bluetooth.tcl#L2645-L2652)

## New features

### Show connected Skale firmware revision

Filed as [decentespresso/decaid#714](https://github.com/decentespresso/decaid/issues/714).

#### Problem

The Skale exposes its firmware revision, but Decaid does not display or publish
it. This makes support and compatibility reports harder to diagnose.

#### Proposed scope

- Read the standard Device Information Firmware Revision String characteristic
  (`0x180A` / `0x2A26`) after connecting.
- Treat the value as an opaque device-provided string such as `R029`.
- Show it in the Devices UI and expose it in nested REST/WebSocket `deviceInfo`.
- Clear it on disconnect and do not persist it as remembered-device truth.

#### Acceptance criteria

- A connected Skale's firmware string appears in the UI and device inventory.
- Missing or malformed firmware data does not fail the connection.
- No firmware update or DFU behavior is introduced.

#### Firmware documentation limit

Atomax publishes SDK versions but no public scale-firmware catalog, firmware
changelog, image archive, or compatibility matrix. The official Android app
compares the hexadecimal suffix of `R0xx` with a private cloud manifest and can
perform Nordic DFU, but that is insufficient to implement a safe third-party
updater. Decaid should display the reported revision only.

#### Evidence

- [Bluetooth SIG Device Information Service firmware field](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/DIS_v1.2/out/en/index-en.html)
- [Bluetooth SIG assigned number for `0x2A26`](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Assigned_Numbers/out/en/index-en.html)
- [SkaleKit iOS client-SDK changelog](https://github.com/atomaxinc/SkaleKit/blob/624c07436a577706dcc26cb2d62ca76ad18f7da9/README.md#L157-L165)
- [SkaleKit Flutter client-SDK changelog](https://github.com/atomaxinc/SkaleKit-flutter/blob/7df4a9d9bd975367c3ac27502323225ac61b116d/CHANGELOG.md#L8-L54)
- [SkaleKit iOS releases](https://github.com/atomaxinc/SkaleKit/releases)

The official Android app is proprietary, so its updater code cannot be given a
public source deeplink. The reproducibility anchor for the local static analysis
is app version 2.3.0 (version code 13), base APK SHA-256
`b28c9e1f118a73a616007197a99127045316b501841028edb37d0d0ef59e7c2d`.
It reads `0x2A26`; its updater fetches `fw.plist`, compares `version_number`
against the hexadecimal suffix of `R0xx`, downloads `nrf51822.zip`, scans for
`DfuTarg`, and passes the image to Nordic's Android DFU library. This evidence
supports documenting the behavior, but not implementing an updater without a
public firmware contract.

### Add opt-in Skale physical-button actions

Filed as [decentespresso/decaid#715](https://github.com/decentespresso/decaid/issues/715).

#### Problem

Atomax exposes the Skale's circle and square button notifications, but Decaid
currently ignores them.

#### Proposed scope

- Map button value `1` to circle and value `2` to square.
- Make circle request the existing scale tare action.
- Add a default-off setting that lets square start espresso when idle and stop
  it while brewing.
- Keep these as application actions, not a new public button-event API.

#### Acceptance criteria

- Unknown button values are ignored safely.
- Circle uses the existing tare path.
- Square does nothing by default and toggles espresso only after opt-in.
- The setting persists and survives settings export/import.

#### Evidence

- [iOS button callback API](https://github.com/atomaxinc/SkaleKit/blob/624c07436a577706dcc26cb2d62ca76ad18f7da9/Distribution/SkaleKit.xcframework/ios-arm64/SkaleKit.framework/Headers/SKSkale.h#L43-L53)
- [Android button IDs 1 and 2](https://github.com/atomaxinc/SkaleKitAndroid/blob/faae8a96879f45c935712c11f25674e4d5dc9e82/README.md#L52-L62)
- [Android example's circle-button tare](https://github.com/atomaxinc/SkaleKitAndroid/blob/faae8a96879f45c935712c11f25674e4d5dc9e82/example/src/main/java/com/atomaxinc/skalekit/example/MainActivity.kt#L159-L165)
- [de1app's circle/square action mapping](https://github.com/decentespresso/de1app/blob/24851f5b1b0faf77b92fdd837b2932a8d8e26e15/de1plus/bluetooth.tcl#L3100-L3118)

### Add a manual USB-powered override for Skale

Filed as [decentespresso/decaid#716](https://github.com/decentespresso/decaid/issues/716).

#### Problem

No reviewed Atomax SDK exposes a reliable USB/external-power or charging signal.
Decaid therefore cannot autodiscover that a Skale is powered by USB, and battery
polling can display misleading information in that configuration.

#### Proposed scope

- Add a Skale-specific **Powered by USB** setting, default off.
- When enabled, suppress battery reads, clear any previous percentage, and
  report `usb` as the connected device's power source.
- When disabled during a connection, resume battery reading and refresh policy.

#### Acceptance criteria

- USB power is never claimed automatically.
- The override persists and survives settings export/import.
- UI and REST/WebSocket metadata distinguish manual USB mode from a
  device-reported battery percentage.

#### Evidence

No reviewed Atomax SDK exposes external-power or charging state:

- [Complete public iOS `SKSkale` interface](https://github.com/atomaxinc/SkaleKit/blob/624c07436a577706dcc26cb2d62ca76ad18f7da9/Distribution/SkaleKit.xcframework/ios-arm64/SkaleKit.framework/Headers/SKSkale.h#L56-L86)
- [Complete Android documented operation surface](https://github.com/atomaxinc/SkaleKitAndroid/blob/faae8a96879f45c935712c11f25674e4d5dc9e82/README.md#L41-L115)
- [Flutter public weight/button/battery/display interface](https://github.com/atomaxinc/SkaleKit-flutter/blob/7df4a9d9bd975367c3ac27502323225ac61b116d/lib/src/skale_kit.dart#L128-L310)
- [macOS operation and delegate surface](https://github.com/atomaxinc/SkaleKit-macOS/blob/0f20dc545a6ca5cd2b4821ac849b0443a3cb9798/README.md#L114-L164)
- [de1app's historical USB assumption](https://github.com/decentespresso/de1app/blob/24851f5b1b0faf77b92fdd837b2932a8d8e26e15/de1plus/bluetooth.tcl#L2645-L2652)

### Design cross-device battery and health warnings

Filed as [decentespresso/decaid#717](https://github.com/decentespresso/decaid/issues/717).

#### Problem

Decaid has no common peripheral low-battery warning policy. A Skale-only warning
would duplicate policy and would not extend cleanly to temperature sensors or
future battery-powered devices.

#### Planning scope

- Inventory which scales, temperature sensors, and other peripherals expose a
  trustworthy percentage, low-battery bit, charging state, or power source.
- Define a generic device-health model that distinguishes unavailable, stale,
  externally powered, charging, low, and critically low states.
- Decide device-specific thresholds and hysteresis instead of assuming one
  percentage works for every battery chemistry and firmware.
- Define notification ownership, deduplication, snooze/acknowledgement,
  reconnect behavior, and persistence.
- Decide how warnings appear in the Devices UI, app notifications, REST, and
  WebSocket APIs without making optional metadata look authoritative.
- Cover devices that report misleading fixed values and devices whose battery
  information is only available while connected.

#### Out of scope until the design is accepted

- A Skale-only warning or hard-coded global threshold.
- Background reconnects solely to poll a battery.
- Firmware update or DFU support.

#### Acceptance criteria for planning

- A device capability matrix covers at least supported scales and temperature
  sensors.
- Product behavior is specified for first warning, repeats, recovery, stale and
  unavailable data, and externally powered devices.
- API and persistence compatibility are described before implementation.
- Implementation can be split into independently testable follow-up work.

#### Evidence to collect during planning

- Device implementation links for every scale and temperature sensor in the
  capability matrix.
- Manufacturer documentation for battery semantics and thresholds where
  available.
- Existing Decaid tablet low-battery behavior as a UI/policy precedent, while
  keeping tablet power management separate from peripheral health.
