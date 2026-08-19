# FretSpark SDK — API Reference

Version 1.4.0

The official Flutter SDK for FretSpark smart guitar fretboard firmware. Connect, control LEDs, and upgrade firmware across all FretSpark-compatible brands (FretSpark, AUPHY, Smiger, NATASHA, Bullfighter, Deviser).

This document is the sole API reference for the SDK. It documents every public class, method, model, enum, transport interface, and firmware command constant, with exact signatures, parameter ranges, firmware command mappings, and code examples.

---

## Table of Contents

- [FretSpark (Singleton)](#fretspark-singleton)
- [FretConnection](#fretconnection)
- [FretDevice](#fretdevice)
- [FretLED](#fretled)
- [FretOTA](#fretota)
- [FretMetronome](#fretmetronome)
- [FretClassroom](#fretclassroom)
- [FretFirmwareDownloader](#fretfirmwaredownloader)
- [FretBrand](#fretbrand)
- [FretAdvanced](#fretadvanced)
- [Models](#models)
  - [FretColor / FretHsl](#fretcolor--frethsl)
  - [FretNote / NoteName / ScaleType](#fretnote--notename--scaletype)
  - [BrandConfig](#brandconfig)
  - [FretBattery / FretFirmwareVersion / FretNotify](#fretbattery--fretfirmwareversion--fretnotify)
  - [FretOtaProgress / FretOtaPhase](#fretotaprogress--fretotaphase)
- [Enums](#enums)
  - [MicSource / MusicMode / FretTimeSignature / FretFirmwareStatus](#enums)
- [Transport Interfaces](#transport-interfaces)
  - [FretTransport / FretBleDevice](#frettransport--fretbledevice)
  - [FretOtaTransport](#fretotatransport)
  - [WebBluetoothTransport](#webbluetoothtransport)
- [FretCommand Constants](#fretcommand-constants)

---

## FretSpark (Singleton)

Top-level singleton entry point for the FretSpark SDK.

Brand apps call `initialize` once at startup, then access the various sub-APIs through the getters. The singleton is intentionally a single-instance class: most brand apps only manage one brand and one device at a time.

**How to access:**

```dart
await FretSpark.instance.initialize(brandId: 'auphy');
final device = await FretSpark.instance.connection.connect(deviceId);
FretSpark.instance.led.fillColor(device, FretColor.red);
```

### Properties

| Property | Returns | Description |
|---|---|---|
| `instance` | `FretSpark` | The shared singleton instance. |
| `isInitialized` | `bool` | Whether `initialize` has been called. |
| `manifestUrl` | `String?` | The default manifest URL configured at `initialize`, or `null`. |
| `brandConfigUrl` | `String?` | The default brand-config URL configured at `initialize`, or `null`. |

### Sub-API Getters

All getters throw `StateError` if `initialize` has not been called.

| Getter | Returns | Description |
|---|---|---|
| `brand` | `FretBrand` | Brand configuration. |
| `connection` | `FretConnection` | Connection / scan. |
| `led` | `FretLED` | LED control. |
| `ota` | `FretOTA` | OTA firmware upgrade. |
| `metronome` | `FretMetronome` | Firmware metronome. |
| `classroom` | `FretClassroom` | Classroom / local-teaching mode. |
| `firmware` | `FretFirmwareDownloader` | Firmware downloader (HTTP manifest + file cache). |
| `transport` | `FretTransport` | The underlying transport, exposed for advanced brand apps that need to access BLE-specific operations. |

### Methods

| Method | Parameters | Returns | Description |
|---|---|---|---|
| `initialize` | `brandId: String` (required), `transport: FretTransport?`, `licenseKey: String?`, `manifestUrl: String?`, `brandConfigUrl: String?` | `Future<void>` | Initialize the SDK. `brandId` is the `BrandConfig.id` (e.g. `auphy`). Loads bundled `brands_fallback.json`, optionally fetches cloud brand config, restores the cached active brand (or falls back to `brandId`), and wires the sub-APIs. Throws `StateError` if already initialized. |
| `dispose` | none | `Future<void>` | Reset the singleton to its pre-initialize state. Disconnects the active device and closes the OTA controller. Mostly useful in tests. |

### Code Example

```dart
import 'package:fretspark_sdk/fretspark_sdk.dart';

await FretSpark.instance.initialize(
  brandId: 'auphy',
  manifestUrl: 'https://ota.auphygt.com/manifest.json',
  brandConfigUrl: 'https://ota.auphygt.com/brands.json',
);

print(FretSpark.instance.isInitialized); // true
print(FretSpark.instance.brand.activeBrand?.displayName); // 'AUPHY GT'
```

---

## FretConnection

Scans for and connects to FretSpark devices.

`FretConnection` wraps a `FretTransport` (default BLE transport implementation) and:
- Filters scan results by the active brand's `BrandConfig.firmwarePatterns`.
- On connect, performs the initial handshake (firmware version, LED count, LED index mode, classroom ID).
- Tracks the currently-connected `FretDevice` so the brand app can access it without holding the reference itself.

**How to access:** `FretSpark.instance.connection`

### Properties

| Property | Returns | Description |
|---|---|---|
| `activeBrand` | `BrandConfig?` | Active brand, used to filter scan results. Set by `FretSpark.initialize`. |
| `current` | `FretDevice?` | Currently-connected device, or `null` if disconnected. |
| `onBrandAutoDetected` | `Stream<BrandConfig>` | Emits the auto-detected `BrandConfig` when a device is connected whose advertised name matches a different brand than the current `activeBrand`. |
| `onCurrentDeviceStateChanged` | `Stream<bool>` | Stream of connection-state changes for the active device. Emits `false` if the device disconnects unexpectedly. Returns an empty stream when no device is current. |
| `scanResults` | `Stream<FretScanResult>` | Stream of scan results, filtered by the active brand's firmware patterns. If no active brand is set, all named devices are emitted. |

### Methods

| Method | Parameters | Returns | Description |
|---|---|---|---|
| `requestPermissions` | none | `Future<bool>` | Returns `true` if the OS grants Bluetooth scan/connect permissions. |
| `isAdapterOn` | none (getter) | `Future<bool>` | Returns `true` if the device's Bluetooth adapter is on. |
| `startScan` | `timeout: Duration = Duration(seconds: 10)` | `Future<void>` | Start a BLE scan. Results are filtered by `BrandConfig.firmwarePatterns` when an active brand is set. Emits results on `scanResults`. Stops automatically after `timeout`. |
| `stopScan` | none | `Future<void>` | Stop an in-flight scan. |
| `connect` | `deviceId: String` | `Future<FretDevice>` | Connect to a device by its BLE id. Performs BLE connect + MTU negotiation + service discovery, firmware version query, LED config query, LED index mode query, and classroom ID read. Auto-detects the brand from the device's BLE advertised name. Throws `FretTransportException` if the BLE connection fails. If a query times out (3s per query), the corresponding field remains at its default. |
| `disconnect` | none | `Future<void>` | Disconnect the current device. |

### Connect Handshake

On `connect`, the SDK runs these handshake queries in parallel (each with a 3-second timeout):

1. Firmware version query — fills `FretDevice.firmwareVersion` (default `''`).
2. LED config query — fills `FretDevice.ledCount` (default `90`).
3. LED index mode query — fills `FretDevice.ledIndexReversed` (default `0`).
4. Classroom ID read — fills `FretDevice.classroomId` (default `0`).

### Code Example

```dart
final connection = FretSpark.instance.connection;

if (!await connection.isAdapterOn) {
  throw StateError('Bluetooth is off');
}
final ok = await connection.requestPermissions();
if (!ok) throw StateError('Permissions denied');

final sub = connection.scanResults.listen((r) {
  print('Found: ${r.name} (${r.id}) rssi=${r.rssi}');
});
await connection.startScan(timeout: const Duration(seconds: 10));
await sub.cancel();

final device = await connection.connect(scanResultId);
print('Connected: ${device.displayName}, fw=${device.firmwareVersion}');

connection.onCurrentDeviceStateChanged.listen((connected) {
  if (!connected) print('Device disconnected');
});

await connection.disconnect();
```

---

## FretDevice

A connected FretSpark device.

Returned by `FretSpark.connection.connect(...)`. Brand apps hold a reference to this object and pass it to `FretSpark.led.*`, `FretSpark.ota.*`, etc. Brand apps do not construct `FretDevice` directly.

On connect, the SDK automatically queries firmware version, LED config, LED index mode, and reads the classroom ID.

**How to access:** returned by `FretSpark.instance.connection.connect(...)`; also available as `FretSpark.instance.connection.current`.

### Properties

| Property | Returns | Description |
|---|---|---|
| `id` | `String` | BLE device id. |
| `name` | `String` | BLE advertised name. |
| `displayName` | `String` | Display name (may differ from `name` if the brand app set a custom one). |
| `brandId` | `String` | Brand that owns this device (matches `BrandConfig.id`). |
| `firmwareVersion` | `String` | Firmware version string (e.g. `1.2.3.4`). Empty until the query completes or times out. |
| `ledCount` | `int` | Total LED count on this device (e.g. 84 for a 14-fret board, 126 for 21). |
| `maxFret` | `int` | Maximum fret index (`ledCount ~/ 6 - 1`). For 14-fret board: 13. For 21-fret board: 20. |
| `ledIndexReversed` | `int` | LED index mode: 0 = normal order, 1 = reversed (newer hardware). |
| `classroomId` | `int` | Classroom ID read from the classroom-ID characteristic (0-9999, 0 = not set). |
| `batteryLevel` | `int` | Latest battery level (0-100). Stale until the first notify. |
| `batteryVoltageMv` | `int` | Latest battery voltage in mV. Stale until the first notify. |
| `mtu` | `int` | Negotiated MTU. |
| `isConnected` | `bool` | Whether the device is currently connected. |

### Streams

| Stream | Element Type | Description |
|---|---|---|
| `onBatteryChanged` | `FretBattery` | Emits when the firmware pushes a battery notify. |
| `onFirmwareVersionQueried` | `FretFirmwareVersion` | Emits when a firmware version query response arrives. |
| `onLedCountChanged` | `int` | Emits when an LED config query response arrives. |
| `onLedIndexModeChanged` | `int` | Emits when an LED index mode query response arrives. |
| `onDiyModeList` | `List<int>` | Emits when a DIY mode list query response arrives. |

### `onUnknownNotify`

```dart
void Function(FretNotify notify)? onUnknownNotify;
```

Catch-all for firmware notify commands not handled by the typed streams. Use this to access experimental/new commands added by future firmware. Brand apps inspect `notify.cmd` to decide how to interpret `notify.data`. Configure via `setUnknownNotifyHandler`.

### Methods

| Method | Parameters | Returns | Description |
|---|---|---|---|
| `setClassroomId` | `id: int` | `Future<void>` | Set the classroom ID (4-byte big-endian uint32 written to the classroom-ID characteristic). `id` must be 0..9999. Throws `ArgumentError` otherwise. |
| `setRtcTime` | `time: DateTime` | `Future<void>` | Sync the device's RTC to the given `time`. Required before `FretLED.setTimer`. Maps to firmware command 0x0B. Payload: `[yearH, yearL, month, day, hour, minute, second]`. Year must be 0..65535. Note: the firmware currently only reads year/month/day/hour/minute (second is sent but unused). |
| `queryVersion` | none | `Future<void>` | Re-query the firmware version at runtime. Result is delivered via `onFirmwareVersionQueried`. The future completes when the query command has been queued (not when the notify arrives). Maps to 0x1E. |
| `queryLedConfig` | none | `Future<void>` | Re-query the LED config (LED count) at runtime. Result is delivered via `onLedCountChanged`. Maps to 0x1F. |
| `queryStatus` | none | `Future<void>` | Trigger the firmware to push its current status (battery, config) via notify. Sends command 0x0C `[0x01]`, which makes the firmware internally call `send_type_request(8)` and `send_type_request(9)` to re-push its status. Subscribe to `onBatteryChanged` for the result. |
| `setUnknownNotifyHandler` | `handler: void Function(FretNotify)?` | `void` | Configure the catch-all notify handler. |
| `send` | `cmd: int`, `params: List<int>` | `Future<void>` | **Internal method; brand apps should not call it directly.** Use the high-level APIs instead. Throws `StateError` if the device has been disposed. |
| `attachQueriedInfo` | `firmwareVersion: String`, `ledCount: int`, `ledIndexReversed: int`, `classroomId: int` | `void` | **Internal method.** Apply the queried device info after the connect handshake. |
| `dispose` | none | `Future<void>` | Disconnect and release all resources. |

### Code Example

```dart
final device = await FretSpark.instance.connection.connect(deviceId);

print('Firmware: ${device.firmwareVersion}');
print('LEDs: ${device.ledCount} (max fret ${device.maxFret})');

// Sync the RTC before scheduling a timer.
await device.setRtcTime(DateTime.now());

// Listen for battery updates.
device.onBatteryChanged.listen((b) {
  print('Battery: ${b.level}% (${b.voltageMv} mV)');
});

// Manually trigger a status push.
await device.queryStatus();

// Catch experimental notify commands.
device.setUnknownNotifyHandler((notify) {
  print('Unknown notify: 0x${notify.cmd.toRadixString(16)}');
});
```

---

## FretLED

High-level LED control API for a connected `FretDevice`.

Each method is safe to call fire-and-forget from UI event handlers. The SDK internally handles serialization, coalescing, left-handed mirroring, and tracks group-control state so it can automatically clean up when exiting group control.

Left-handed mode is persisted to `SharedPreferences` and shared across all devices through the `FretSpark` singleton. When left-handed mode is on, string indices are mirrored 0↔5 before being sent to the firmware, so callers always use right-handed numbering. Fret indices are never mirrored.

**How to access:** `FretSpark.instance.led`

### Properties

| Property | Returns | Description |
|---|---|---|
| `leftHandedMode` | `bool` | Whether left-handed (mirrored) mode is active. |

### Methods — Power / Brightness / Color

| Method | Parameters | Returns | Description |
|---|---|---|---|
| `setPower` | `device: FretDevice`, `on: bool` (required, named) | `Future<void>` | Turn the LED panel on or off. Maps to 0x01. |
| `setBrightness` | `device: FretDevice`, `brightness: int` | `Future<void>` | Set global brightness. Range 0-1000. Throws `ArgumentError` otherwise. Maps to 0x05. Payload: `[briH, briL, 0, 0, 0, 0]`. |
| `setColor` | `device: FretDevice`, `hsl: FretHsl` | `Future<void>` | Set the base color using HSL. Hue: 0-360, Saturation: 0-1000. Maps to 0x04. Payload: `[hueH, hueL, satH, satL, 0, 0]`. Clears group and selection first. |
| `fillColor` | `device: FretDevice`, `color: FretColor` | `Future<void>` | Fill the entire fretboard with a solid RGB color. Maps to 0x15. Payload: `[0, r, 0, g, 0, b]`. Clears group and selection first. |

### Methods — Effect Mode

| Method | Parameters | Returns | Description |
|---|---|---|---|
| `setMode` | `device: FretDevice`, `modeId: int` | `Future<void>` | Switch to a built-in effect mode. `modeId` is 1-based. Maps to 0x06. Payload: `[modeH, modeL]`. Clears selection first. |
| `setSpeed` | `device: FretDevice`, `speed: int` | `Future<void>` | Set effect speed. Range 0-255. Throws `ArgumentError` otherwise. Maps to 0x08. |
| `setDirection` | `device: FretDevice`, `direction: int` | `Future<void>` | Set effect direction. 0 = forward, 1 = reverse. Throws `ArgumentError` otherwise. Maps to 0x07. |

### Methods — Hardware Layout

| Method | Parameters | Returns | Description |
|---|---|---|---|
| `setLinearLayout` | `device: FretDevice`, `linear: bool` (required, named) | `Future<void>` | Set the RGB layout mode. `linear=false` (default): matrix layout. `linear=true`: linear layout (WS2812/SK6812 strips). Maps to 0x02. Must be called before any LED rendering command if the device uses a non-default layout. |
| `setLedCount` | `device: FretDevice`, `count: int` | `Future<void>` | Override the total LED count the firmware drives. Range 1-65535. Throws `ArgumentError` otherwise. Maps to 0x03. Note: `FretDevice.ledCount` is NOT automatically updated; subscribe to `onLedCountChanged` or call `queryLedConfig` to refresh. |
| `setLedIndexMode` | `device: FretDevice`, `reversed: bool` (required, named) | `Future<void>` | Set the LED index order. Pass `true` to reverse the firmware's LED indexing (for newer hardware revisions where the LED strip is wired right-to-left). The SDK transparently handles left-handed mirroring on top of this. Query result and confirmations are delivered via `FretDevice.onLedIndexModeChanged`. Maps to 0x27. |

### Methods — Music Style

| Method | Parameters | Returns | Description |
|---|---|---|---|
| `setMusicStyle` | `device: FretDevice`, `styleId: int` | `Future<void>` | Set the music style. This triggers a render pipeline independent of `setMode` (0x06) and `setMusicMode` (0x09). Firmware internally calls `apply_music_style(styleId)`. Style IDs >= 100 are reset to 0 by the firmware. Range 0-99 for app-defined styles. Throws `ArgumentError` otherwise. Maps to 0x1B. |

### Methods — Timer (Scheduled Power On/Off)

| Method | Parameters | Returns | Description |
|---|---|---|---|
| `setTimer` | `device: FretDevice`, `on: bool` (required), `hour: int` (required), `minute: int` (required), `second: int` (required), `slot: int = 0` | `Future<void>` | Configure a scheduled power on/off timer. Requires `FretDevice.setRtcTime` first. `on=true` schedules power-on, `false` schedules power-off. `hour`/`minute`/`second` are 24-hour format trigger time. `slot` is timer slot index (firmware-reserved, default 0). Maps to 0x0D. Payload: `[slot, onOff, hour, minute, second, 0x00]`. Validated ranges: hour 0-23, minute 0-59, second 0-59, slot 0-255. |

### Methods — Range Fill (Continuous LED Segment)

| Method | Parameters | Returns | Description |
|---|---|---|---|
| `fillRange` | `device: FretDevice`, `startIndex: int` (required), `colors: List<FretColor>` (required) | `Future<void>` | Fill a continuous range of LEDs with individual colors in a single packet. `startIndex`: first LED index (0-based, APP numbering, 0-255). `colors`: per-LED colors, length must be <= 79 (`FretCommand.maxLedsPerFillRangePacket`). For longer ranges, call in chunks. Maps to 0x14. Payload: `[startIndex, r1,g1,b1, r2,g2,b2, ...]`. ~4-5x faster than batched sparse writes for the same LED count. If `leftHandedMode` is on, `startIndex` is mirrored by the firmware. |

### Methods — Selection Mask

| Method | Parameters | Returns | Description |
|---|---|---|---|
| `lockSelection` | `device: FretDevice`, `ledIndices: List<int>` | `Future<void>` | Lock the active selection mask so subsequent effect/color commands only apply to `ledIndices`. Indices must be 0-399. Pass an empty list to clear. Maps to 0x18. |
| `unlockSelection` | `device: FretDevice` | `Future<void>` | Clear the active selection mask. Effects then apply to all LEDs. Maps to 0x18. |

### Methods — Single / Multiple Learning LEDs

| Method | Parameters | Returns | Description |
|---|---|---|---|
| `lightNote` | `device: FretDevice`, `note: FretNote` | `Future<void>` | Light a single note. `note.string` is 0-5 from high E to low E. `note.fret` is 0-indexed (0 = open). Maps to 0x22. Payload: `[0x01, index, r, g, b]`. Out-of-bounds notes are silently ignored. |
| `lightNotes` | `device: FretDevice`, `notes: List<FretNote>` | `Future<void>` | Light multiple notes. Notes are de-duplicated by LED index; the last write wins (matches firmware's per-pixel overwrite semantics). Uses batched sparse indexing internally. Maps to 0x22 (multi) wrapped in 0x1C/0x1D batch transfer. |
| `clearLearningLEDs` | `device: FretDevice` | `Future<void>` | Clear all learning LEDs. Maps to 0x22. Payload: `[0x00]`. |

### Methods — Chord / Scale (Compositional Helpers)

| Method | Parameters | Returns | Description |
|---|---|---|---|
| `showChord` | `device: FretDevice`, `root: NoteName` (required), `chordType: String` (required), `color: FretColor = FretColor.white` | `Future<void>` | Light a chord across the fretboard using the built-in chord dictionary. The root note selects the pitch; `chordType` selects the chord quality (e.g. `maj`, `min`, `7`). All lit positions use `color`. Previously-lit learning LEDs are cleared first. Throws `ArgumentError` if the chord is unknown. |
| `showScale` | `device: FretDevice`, `root: NoteName` (required), `scale: ScaleType` (required), `color: FretColor = FretColor.white` | `Future<void>` | Light a scale across the fretboard. The root note selects the key; `scale` selects the scale type. Lights one octave on each string. Throws `ArgumentError` if the scale is unknown. |

### Methods — Voice / Mic Mode

| Method | Parameters | Returns | Description |
|---|---|---|---|
| `setMusicMode` | `device: FretDevice`, `mode: MusicMode`, `extraParams: List<int> = const []` | `Future<void>` | Switch the firmware to a high-level music mode. `mode` selects the music mode; `extraParams` is an optional list of mode-specific parameters (tempo, time signature, etc.) whose layout is defined by the firmware spec. Distinct from AI rhythm LED effects (modes 124-135), which use `setMode`. Maps to 0x09. |
| `setMicSource` | `device: FretDevice`, `source: MicSource` | `Future<void>` | Set the active microphone / pickup source. Pass `MicSource.off` to disable. Maps to 0x0F. |
| `setVoiceMode` | `device: FretDevice`, `on: bool` (required) | `Future<void>` | Enable or disable voice-reactive mode. Maps to 0x11. Payload: `[0x00]` when on, `[0xFF]` when off. |
| `setVoiceSensitivity` | `device: FretDevice`, `value: int` | `Future<void>` | Set voice-reactive sensitivity. Range 0-255. Higher values make the LED react to quieter sounds. Rapid calls are safe; only the latest value is sent. Maps to 0x12. |
| `injectEnergy` | `device: FretDevice`, `volume: int` | `Future<void>` | Inject a single audio-energy sample from the APP microphone. `volume` is a 16-bit unsigned value (0-65535) representing the current RMS / peak amplitude. The firmware uses it to drive LED brightness when `MicSource.appMic` is active. Call at ~30-60 Hz. Maps to 0x26. Payload: `[volumeH, volumeL]`. |

### Methods — Group-Color Channel

The firmware exposes a second render channel ("group channel") where LEDs are partitioned into named groups and each group is assigned a single color. The SDK tracks per-device group state so any non-group command automatically emits a cleanup frame first.

| Method | Parameters | Returns | Description |
|---|---|---|---|
| `applyGroupFrame` | `device: FretDevice`, `groupAssignments: Map<int, int>` (required), `groupColors: Map<int, FretColor>` (required) | `Future<void>` | Render a complete group-color frame in a single batched transaction. `groupAssignments` maps each LED index (0-based, after left-handed mirroring) to a group ID in 1..255. LEDs not in the map (or mapped to 0) render black. `groupColors` maps each group ID to its color; missing groups default to black. No intermediate black flash. Empty `groupAssignments` clears the group map. |
| `setGroupColor` | `device: FretDevice`, `groupId: int`, `color: FretColor` | `Future<void>` | Set the color of a single group. Low-level escape hatch. `groupId` 0-255. Use only to update one group's color without re-sending the entire group map. The firmware must already be in group-color mode. The panel is NOT refreshed until `flushGroupImmediate` or batch end. Maps to 0x1A. |
| `applyGroupMap` | `device: FretDevice`, `baseIdx: int`, `groupIds: List<int>` | `Future<void>` | Assign LEDs to groups. Low-level escape hatch. `groupIds[i]` is the group ID of the LED at `baseIdx + i`. `baseIdx` 0-399, each `groupId` 0-255. A groupId of 0 means "no group" (renders black). Maps to 0x19. |
| `clearGroupMap` | `device: FretDevice` | `Future<void>` | Clear all group assignments and exit group-color mode. Maps to 0x19 (with empty payload). |
| `flushGroupImmediate` | `device: FretDevice` | `Future<void>` | Trigger an immediate LED refresh in the group channel. Legacy primitive. Exposed for compatibility with older firmware that may not implement the batch protocol. Maps to 0x17. |

### Methods — DIY Mode List

| Method | Parameters | Returns | Description |
|---|---|---|---|
| `setDiyModeList` | `device: FretDevice`, `modeIds: List<int>` | `Future<void>` | Set the user's "DIY" mode list. `modeIds` must contain values in 1..117. The list is sent as a single packet; if it exceeds `FretCommand.bleRxFrameMaxLen - 1` (249) it is silently truncated. Pass an empty list to reset to firmware default. Maps to 0x29. Payload: `[count, ...modeIds]`. |
| `queryDiyModeList` | `device: FretDevice` | `Future<void>` | Query the current DIY mode list. The firmware responds asynchronously via `FretDevice.onDiyModeList`. Subscribe before calling. Maps to 0x2A. |

### Methods — Power Shortcuts

| Method | Parameters | Returns | Description |
|---|---|---|---|
| `setAllOn` | `device: FretDevice` | `Future<void>` | Turn all LEDs on. Equivalent to `setMode(device, 2)` (rainbow effect). Clears group and selection first. |
| `clearAll` | `device: FretDevice` | `Future<void>` | Turn all LEDs off. Transitions directly from the previous image to black without an intermediate black-flash. Clears group and selection, then sends `batchBegin [0]` + `batchEnd`. |

### Methods — Left-Handed Mode

| Method | Parameters | Returns | Description |
|---|---|---|---|
| `setLeftHandedMode` | `enabled: bool` | `Future<void>` | Enable or disable left-handed mode. Persisted to `SharedPreferences` and applied to all subsequently-sent LED commands. |
| `loadPersistedState` | none | `Future<void>` | Load the persisted left-handed mode flag. Called once during `FretSpark.initialize`. |

### Code Examples

```dart
final led = FretSpark.instance.led;
final device = FretSpark.instance.connection.current!;

// Power and brightness.
await led.setPower(device, on: true);
await led.setBrightness(device, 500);          // 0-1000

// Solid color fill.
await led.fillColor(device, FretColor.red);

// HSL base color.
await led.setColor(device, FretHsl(120, 1000)); // green

// Built-in effect.
await led.setMode(device, 5);
await led.setSpeed(device, 128);               // 0-255
await led.setDirection(device, 0);             // 0=forward, 1=reverse

// Left-handed mode (persisted).
await led.setLeftHandedMode(true);

// Light a single note (high E, 3rd fret, red).
await led.lightNote(device, FretNote(string: 0, fret: 3, color: FretColor.red));

// Light a C-major chord across the fretboard.
await led.showChord(
  device,
  root: NoteName.c,
  chordType: 'maj',
  color: FretColor.white,
);

// Light a C-major scale.
await led.showScale(
  device,
  root: NoteName.c,
  scale: ScaleType.major,
);

// Continuous range fill (5 LEDs starting at index 0).
await led.fillRange(
  device,
  startIndex: 0,
  colors: [FretColor.red, FretColor.green, FretColor.blue, FretColor.white, FretColor.black],
);

// Selection mask (only light LEDs 0..5).
await led.lockSelection(device, [0, 1, 2, 3, 4, 5]);
await led.unlockSelection(device);

// Group-color frame: group 1 = red, group 2 = blue.
await led.applyGroupFrame(
  device,
  groupAssignments: {0: 1, 1: 1, 2: 2, 3: 2},
  groupColors: {1: FretColor.red, 2: FretColor.blue},
);

// Scheduled power-off at 23:30:00 (sync RTC first).
await device.setRtcTime(DateTime.now());
await led.setTimer(
  device,
  on: false,
  hour: 23,
  minute: 30,
  second: 0,
);

// Voice-reactive mode with APP mic.
await led.setMicSource(device, MicSource.appMic);
await led.setVoiceMode(device, on: true);
await led.setVoiceSensitivity(device, 128);
// Feed 30-60 Hz energy samples:
// await led.injectEnergy(device, 32000);

// Clear everything.
await led.clearAll(device);
await led.setPower(device, on: false);
```

---

## FretOTA

OTA firmware upgrade API.

FretSpark devices use a dedicated Nordic-style OTA service separate from the runtime command service. To upgrade:

1. The runtime device is notified to enter OTA mode via the runtime command service. The device reboots into OTA mode and starts advertising with the brand's OTA name prefix (e.g. `SCT-86PRO OTA`).
2. The app scans for the OTA-mode device and connects.
3. The app sends the firmware image in 20-byte packets, with a 16-packet burst window followed by an ACK from the device. Bad-data responses trigger a rollback + retry (up to 3).
4. On completion, the device reboots into normal mode.

The BLE GATT operations are abstracted behind `FretOtaTransport`. The default implementation `FlutterBlueOtaTransport` wraps `flutter_blue_plus`.

**How to access:** `FretSpark.instance.ota`

### Constants

| Constant | Type | Value | Description |
|---|---|---|---|
| `serviceUuid` | `String` | `5833ff01-9b8b-5191-6142-22a4536ef123` | OTA service UUID (PPlus/pHUB compatible). |
| `cmdUuid` | `String` | `5833ff02-9b8b-5191-6142-22a4536ef123` | OTA command characteristic UUID. |
| `rspUuid` | `String` | `5833ff03-9b8b-5191-6142-22a4536ef123` | OTA response characteristic UUID. |
| `dataUuid` | `String` | `5833ff04-9b8b-5191-6142-22a4536ef123` | OTA data characteristic UUID. |
| `burstSize` | `int` | `16` | Burst window: 16 packets per ACK. |
| `packetSize` | `int` | `20` | Bytes per packet. |
| `maxRetries` | `int` | `3` | Maximum burst retries. |
| `cmdStartOta` | `int` | `0x01` | Start OTA command. |
| `cmdPartitionInfo` | `int` | `0x02` | Partition info command. |
| `cmdReboot` | `int` | `0x04` | Reboot command. |
| `rspStartOta` | `int` | `0x81` | Start OTA response. |
| `rspOtaComplete` | `int` | `0x83` | OTA complete response. |
| `rspPartitionInfo` | `int` | `0x84` | Partition info response. |
| `rspPartitionComplete` | `int` | `0x85` | Partition complete response. |
| `rspBlockBurst` | `int` | `0x87` | Block burst ACK response. |
| `rspReboot` | `int` | `0x8a` | Reboot response. |
| `rspError` | `int` | `0xff` | Error response. |
| `errSuccess` | `int` | `0` | Success error code. |
| `errBadData` | `int` | `104` | Bad-data error code. |

### Properties

| Property | Returns | Description |
|---|---|---|
| `onProgress` | `Stream<FretOtaProgress>` | Emits progress updates during `upgrade`. Subscribe before calling `upgrade`. |

### Methods

| Method | Parameters | Returns | Description |
|---|---|---|---|
| `FretOTA` (constructor) | `transport: FretOtaTransport?` | `FretOTA` | Construct an OTA driver. Defaults to `FlutterBlueOtaTransport`. Inject a custom transport for tests or alternative BLE stacks. |
| `enterOtaMode` | `device: FretDevice`, `rebootDelay: Duration = Duration(seconds: 2)` | `Future<void>` | Tell a connected runtime device to reboot into OTA mode. Sends `[0x02, 0x01]` via the runtime command service. After `rebootDelay`, the device is expected to be advertising in OTA mode. `device` must already be connected via `FretConnection.connect`. Maps to 0x01 (`enterOta`). |
| `scanOtaDevice` | `prefix: String`, `timeout: Duration = Duration(seconds: 15)` | `Future<FretScanResult?>` | Scan for an OTA-mode device whose advertised name starts with `prefix`. Returns the first match, or `null` if `timeout` elapses. |
| `upgrade` | `deviceId: String`, `fileBytes: Uint8List` | `Future<void>` | Connect to the OTA-mode device at `deviceId`, then upgrade its firmware with `fileBytes`. The device must already be in OTA mode. Throws `FretOtaException` on any failure. Progress is emitted via `onProgress`. Throws `FretOtaException` if `fileBytes` is empty. |
| `dispose` | none | `void` | Release resources. After disposal, `upgrade` will throw. |

### OTA Protocol

`upgrade` drives this sequence:

1. Connect + discover OTA service + enable rsp notifications.
2. Send `START_OTA` `[0x01, 0x02, 0x01]`, wait for `rspStartOta`.
3. Send `PARTITION_INFO` `[0x02, 0x00, lenH, lenH, lenM, lenL, lenL]` (single partition), wait for `rspPartitionInfo`.
4. Stream data in 16-packet bursts (each packet padded to 20 bytes). Wait for `rspBlockBurst` ACK. On `errBadData`, rollback to the burst start and retry (up to `maxRetries`).
5. Wait for `rspOtaComplete` or `rspPartitionComplete`.
6. Send `REBOOT` `[0x04, 0x00]`. The device disconnects.
7. Disconnect the transport.

### Code Example

```dart
final ota = FretSpark.instance.ota;
final device = FretSpark.instance.connection.current!;

final sub = ota.onProgress.listen((p) {
  print('${p.phase.name}: ${p.percent}% (${p.sentBytes}/${p.totalBytes})');
});

try {
  // 1. Tell the runtime device to reboot into OTA mode.
  await ota.enterOtaMode(device);

  // 2. Scan for the OTA-mode device.
  final otaDevice = await ota.scanOtaDevice('SCT-86PRO OTA');
  if (otaDevice == null) {
    print('OTA device not found');
    return;
  }

  // 3. Load firmware bytes (e.g. via FretFirmwareDownloader).
  final bytes = await FretSpark.instance.firmware.readLocalFirmwareBytes(
    brandId: 'auphy',
  );
  if (bytes == null) {
    print('No firmware file cached');
    return;
  }

  // 4. Upgrade.
  await ota.upgrade(otaDevice.id, bytes);
  print('OTA upgrade complete');
} on FretOtaException catch (e) {
  print('OTA failed: $e');
} finally {
  await sub.cancel();
  ota.dispose();
}
```

---

## FretMetronome

Firmware metronome control.

The firmware has a built-in metronome that emits a click on the LED panel. Brand apps start/stop it via this class; the actual beat scheduling lives in the firmware.

**How to access:** `FretSpark.instance.metronome`

### Methods

| Method | Parameters | Returns | Description |
|---|---|---|---|
| `start` | `device: FretDevice`, `bpm: int` (required), `timeSignature: FretTimeSignature = FretTimeSignature.fourFour` | `Future<void>` | Start the metronome. `bpm` 40-240 (throws `ArgumentError` otherwise). Maps to 0x20. Payload: `[bpmH, bpmL, timeSig]`. |
| `stop` | `device: FretDevice` | `Future<void>` | Stop the metronome. Maps to 0x21. |

### Code Example

```dart
final metronome = FretSpark.instance.metronome;
final device = FretSpark.instance.connection.current!;

await metronome.start(
  device,
  bpm: 120,
  timeSignature: FretTimeSignature.fourFour,
);

// ... later
await metronome.stop(device);
```

---

## FretClassroom

Classroom / local-teaching mode API.

Syncs LED state across devices via a dedicated broadcast channel between devices: a single "teacher" device can push its current LED state to one or more "student" devices (a side channel outside BLE GATT). Suitable for classroom scenarios where the teacher wants every student's fretboard to mirror their own fretboard in real time.

The SDK only exposes the start/stop primitives; the brand APP is responsible for:
- Coordinating classroom IDs (see `FretDevice.classroomId` / `FretDevice.setClassroomId`) so teacher and students share the same channel.
- UI for role selection (teacher vs student).
- Calling `stop` on every device when the session ends.

All three commands take no parameters. The firmware handles channel negotiation, packet framing, and retransmission internally.

**How to access:** `FretSpark.instance.classroom`

### Methods

| Method | Parameters | Returns | Description |
|---|---|---|---|
| `startTeacher` | `device: FretDevice` | `Future<void>` | Start broadcasting LED state as a teacher. After this call, the firmware enters teacher broadcast mode and pushes each rendered LED frame to the classroom channel identified by the device's classroom ID. Only one device in a classroom should call this. Maps to 0x23. |
| `startStudent` | `device: FretDevice` | `Future<void>` | Start listening for teacher broadcasts as a student. After this call, the firmware enters student listener mode and overwrites its own LED state with whatever the teacher broadcasts on the same classroom ID. Local LED commands sent to this device are ignored until `stop` is called. Maps to 0x24. |
| `stop` | `device: FretDevice` | `Future<void>` | Stop classroom mode. Works for both teacher and student roles. After this call the firmware returns to normal BLE-driven rendering and the device stops broadcasting / listening on the classroom channel. Maps to 0x25. |

### Code Example

```dart
final classroom = FretSpark.instance.classroom;
final teacher = await FretSpark.instance.connection.connect(teacherId);
final student = await FretSpark.instance.connection.connect(studentId);

// Both devices must share the same classroom ID.
await teacher.setClassroomId(1234);
await student.setClassroomId(1234);

// Teacher broadcasts; student mirrors.
await classroom.startTeacher(teacher);
await classroom.startStudent(student);

// ... teach ...

await classroom.stop(teacher);
await classroom.stop(student);
```

---

## FretFirmwareDownloader

Optional helper that downloads firmware images from an OTA server and caches them on disk.

The FretSpark SDK deliberately keeps network concerns out of the core `FretOTA` class — `FretOTA` only handles the BLE transfer. This class provides the missing HTTP layer:

1. Fetches `manifest.json` from the OTA server.
2. Resolves the firmware file for the active brand.
3. Compares the cloud version against the device version.
4. Downloads the file with progress reporting.
5. Caches it under `getApplicationSupportDirectory()/fretspark_ota_firmware/`.
6. Cleans up old versions automatically.

Brand apps that already have their own download infra can ignore this class and call `FretOTA.upgrade` directly with bytes they obtained some other way.

**How to access:** `FretSpark.instance.firmware`. Requires `initialize`'s optional `manifestUrl` parameter to be set; otherwise brand apps must pass `manifestUrl` explicitly to each downloader method.

### Constants

| Constant | Type | Value | Description |
|---|---|---|---|
| `checkInterval` | `Duration` | `Duration(hours: 24)` | Re-check the cloud manifest at most once per 24 hours. Brand apps can override by passing `force: true` to `checkForUpdate`. |

### Properties

| Property | Returns | Description |
|---|---|---|
| `onStatusChanged` | `Stream<FretFirmwareStatus>` | Emits status transitions. Subscribe to drive UI labels / spinners. |
| `isChecking` | `bool` | Whether a manifest check is in progress. |
| `isDownloading` | `bool` | Whether a firmware download is in progress. |
| `downloadProgress` | `double` | Current download progress in `0.0..1.0`. Resets to `0` at the start of each download. |

### Manifest Format

```json
{
  "version": "3.1.3.4",
  "releaseNotes": "...",
  "brands": [
    {
      "id": "auphy",
      "version": "3.1.3.4",
      "file": "firmware.auphy.3.1.3.4.hex16",
      "size": 245760,
      "otaNamePrefix": "AUPHY-OTA"
    }
  ]
}
```

For backwards compatibility, a single-file manifest without a `brands` array is also accepted (in which case `brandId` is ignored and the top-level `file`/`size`/`version` fields are used).

### Methods

| Method | Parameters | Returns | Description |
|---|---|---|---|
| `checkForUpdate` | `manifestUrl: String` (required), `brandId: String` (required), `force: bool = false` | `Future<FretFirmwareInfo?>` | Fetch the manifest from `manifestUrl` and resolve the firmware entry for `brandId`. `force` bypasses the 24-hour throttle. Returns `FretFirmwareInfo`, or `null` if the fetch failed or `brandId` is not in the manifest. The manifest is cached on disk so subsequent calls work without network. |
| `download` | `manifestUrl: String` (required), `brandId: String` (required), `onProgress: void Function(double)?` | `Future<String?>` | Download the firmware file for `brandId` to the local cache directory. `manifestUrl` is the base URL; the file name from the manifest is appended. Returns the absolute path of the downloaded file, or `null` on failure. Skips if the same version is already on disk. |
| `checkAndDownload` | `manifestUrl: String` (required), `brandId: String` (required), `currentVersion: String?`, `onProgress: void Function(double)?`, `force: bool = false` | `Future<String?>` | One-shot "check + download if needed". When `currentVersion` is non-empty, the SDK only downloads when the cloud version is strictly newer. Wipes the cache if the brand changed since last download. Returns the local file path if a download happened or a matching file was already on disk, otherwise `null`. Inspect `onStatusChanged` to distinguish up-to-date / check-failed / download-failed. |
| `getLocalFirmwarePath` | `brandId: String` (required) | `Future<String?>` | Path to a previously-downloaded firmware file matching `brandId`. Returns `null` if no cached file exists or the cached manifest does not contain an entry for `brandId`. |
| `getLocalFirmwareVersion` | `brandId: String` (required) | `Future<String?>` | Version string of the locally-cached firmware for `brandId`, or `null` if no cache exists. |
| `readLocalFirmwareBytes` | `brandId: String` (required) | `Future<Uint8List?>` | Read the locally-cached firmware file as bytes. Convenience for passing straight to `FretOTA.upgrade`. |
| `deleteLocalFirmware` | none | `Future<void>` | Delete all cached firmware files and the local manifest. Call after a successful OTA upgrade to reclaim space, or when the user switches brands. |
| `compareVersions` (static) | `a: String`, `b: String` | `int` | Compare two `major.minor.revision.sub` version strings. Returns positive if `a` is newer, `0` if equal, negative if `b` is newer. Missing segments and non-numeric segments default to `0`. |
| `dispose` | none | `void` | Release resources. Safe to call multiple times. |

### Code Example

```dart
final fw = FretSpark.instance.firmware;
final device = FretSpark.instance.connection.current!;

final sub = fw.onStatusChanged.listen((status) {
  print('Firmware status: $status');
});

final path = await fw.checkAndDownload(
  manifestUrl: 'https://ota.auphygt.com/manifest.json',
  brandId: 'auphy',
  currentVersion: device.firmwareVersion,
  onProgress: (p) => print('Download: ${(p * 100).round()}%'),
);

if (path != null) {
  final bytes = await fw.readLocalFirmwareBytes(brandId: 'auphy');
  // ... pass bytes to FretOTA.upgrade ...
}

await sub.cancel();
fw.dispose();
```

---

## FretBrand

Brand configuration loader with cloud sync.

Resolves the active brand's `BrandConfig` at app startup. Loading strategy (mirrors the OTA firmware downloader):

1. **Built-in fallback** (`assets/brands_fallback.json`) — always available, ships with the SDK. Contains the six FretSpark-compatible brands (FretSpark, AUPHY, Smiger, NATASHA, Bullfighter, Deviser).
2. **Local cache** (SharedPreferences) — the last successfully-fetched cloud config. Survives app restarts.
3. **Cloud** (`syncFromCloudUrl`) — fresh config from your OTA server (e.g. `partner.json`). Version-checked; skipped if the version number hasn't changed.

Brand apps typically call `FretSpark.initialize(brandConfigUrl: ...)` and the SDK runs all three layers automatically.

**How to access:** `FretSpark.instance.brand`

### Properties

| Property | Returns | Description |
|---|---|---|
| `allBrands` | `Map<String, BrandConfig>` | All known brands, keyed by `BrandConfig.id`. Unmodifiable. |
| `activeBrand` | `BrandConfig?` | The currently-active brand. Set by `setActive` or by `FretSpark.initialize`. |

### Methods

| Method | Parameters | Returns | Description |
|---|---|---|---|
| `loadFallback` | none | `Future<void>` | Load the bundled `brands_fallback.json` into `allBrands`. Safe to call multiple times; later calls replace the map. |
| `syncFromCloud` | `jsonPayload: String` | `Future<void>` | Replace the in-memory brand list with a cloud-fetched payload. The payload must match the `brands_fallback.json` schema: `{ "version": int, "list": [ {id, display_name, ...}, ... ] }`. |
| `syncFromCloudUrl` | `url: String`, `timeout: Duration = Duration(seconds: 5)` | `Future<bool>` | Fetch brand config from `url`, with caching and version checking. Returns `true` if the cloud config was freshly applied, `false` if the version was unchanged or the fetch failed (in which case the cache/fallback remains active). |
| `setActive` | `brandId: String` | `Future<void>` | Set the active brand by id. Throws `ArgumentError` if the brand is not in `allBrands`; throws `StateError` if the brand is disabled. Persists the choice to SharedPreferences. |
| `loadActiveFromCache` | none | `Future<void>` | Load the previously-saved active brand from SharedPreferences. Called by `FretSpark.initialize`. |
| `matchByFirmwareName` | `firmwareName: String` | `BrandConfig?` | Find the brand whose `BrandConfig.firmwarePatterns` match `firmwareName`. Returns `null` if no brand matches. |
| `autoDetectFromDeviceName` | `deviceName: String` | `Future<BrandConfig?>` | Auto-detect the brand from a connected device's BLE advertised name. If a matching brand is found AND differs from the current `activeBrand`, switches `activeBrand` to the matched brand and persists the choice. Returns the matched brand (or `null`). Called by `FretConnection.connect` after the BLE connection is established. |

### Bundled Brands (`brands_fallback.json`)

| `id` | `displayName` | `deviceModel` | `otaNamePrefix` |
|---|---|---|---|
| `fretspark` | FretSpark | FS-86 PRO | `FS-86 OTA` |
| `auphy` | AUPHY GT | SCT-86 PRO | `SCT-86PRO OTA` |
| `smiger` | Smiger | Smiger | `Smiger OTA` |
| `natasha` | NATASHA | NATASHA | `NATASHA-X OTA` |
| `bullfighter` | Bullfighter | DNS-L01 | `DNS-L01 OTA` |
| `deviser` | Deviser | Deviser | `Deviser OTA` |

### Code Example

```dart
final brand = FretSpark.instance.brand;

print('Active: ${brand.activeBrand?.displayName}');
for (final b in brand.allBrands.values) {
  print('  - ${b.id}: ${b.displayName} (${b.deviceModel})');
}

// Match a discovered BLE name against known brands.
final match = brand.matchByFirmwareName('SCT-86PRO-AB12');
print('Matched: ${match?.displayName}'); // 'AUPHY GT'

// Sync from cloud.
final applied = await brand.syncFromCloudUrl(
  'https://ota.auphygt.com/brands.json',
);
print('Cloud applied: $applied');
```

---

## FretAdvanced

Escape hatch for advanced users who need to send firmware commands that the SDK's high-level API (`FretLED`, `FretMetronome`, `FretClassroom`, ...) does not wrap.

> **Warning**: this is an "escape hatch", not a regular API. Sending raw commands via this class bypasses the SDK's state-machine optimizations and may cause:
>
> - Group-control state not cleaned up → rendering anomaly
> - Batch transfer (0x1C/0x16/0x1D) timing disorder → LED data corruption
> - High-frequency commands not coalesced → BLE queue overflow → packet loss
> - Out of sync with SDK internal state → subsequent high-level API behaves unexpectedly
>
> Before using, confirm:
> 1. The SDK's high-level API really does not have an equivalent method.
> 2. You have read the `FretCommand` code comments and understand the parameter format and firmware behavior.
> 3. You will manage subsequent state yourself (e.g. after sending 0x1C you must send 0x1D to finalize).

**How to access:** all methods are static; call them directly on `FretAdvanced`. The class has a private constructor and is not instantiated.

### Methods (all static)

| Method | Parameters | Returns | Description |
|---|---|---|---|
| `sendRaw` | `device: FretDevice`, `cmd: int`, `params: List<int>`, `bypassQueue: bool = false` | `Future<void>` | Send a raw firmware command without going through the high-level API. `cmd` must be one of the `FretCommand` constants. `params` is the command payload (without the BC/55 frame delimiters — the SDK adds those automatically). The command is queued through `FretDevice`'s normal send queue, so it respects coalescing rules. Throws `StateError` if the device has been disposed. Throws `UnimplementedError` if `bypassQueue` is `true` (reserved for future use — for OTA writes use `FretOTA.*`, for normal commands leave `bypassQueue=false`). |
| `sendRawFireAndForget` | `device: FretDevice`, `cmd: int`, `params: List<int>` | `void` | Send a raw firmware command and return immediately without waiting for the send queue to flush. Useful for fire-and-forget scenarios where the brand app does not need to confirm the command reached the firmware (e.g. high-frequency animation frames). More dangerous than `sendRaw`: the caller completely loses visibility into send ordering. Errors are swallowed silently. |

### Code Example

```dart
import 'package:fretspark_sdk/fretspark_sdk.dart';

final device = FretSpark.instance.connection.current!;

// Send a custom music style the SDK doesn't wrap yet.
await FretAdvanced.sendRaw(
  device,
  FretCommand.musicStyle, // 0x1B
  <int>[42],
);

// Fire-and-forget (e.g. animation refresh).
FretAdvanced.sendRawFireAndForget(
  device,
  FretCommand.brightness,
  <int>[0x01, 0xF4, 0, 0, 0, 0],
);
```

---

## Models

### FretColor / FretHsl

`FretColor` is an RGB color used for fretboard LEDs. `FretHsl` is an HSL color, used by the firmware's color command.

#### FretColor

Immutable. RGB channels are 0-255.

| Member | Signature | Description |
|---|---|---|
| `r`, `g`, `b` | `final int` | Red, green, blue components (0-255). |
| `FretColor` (constructor) | `const FretColor(int r, int g, int b)` | Construct an RGB color. |
| `black` | `static const FretColor = FretColor(0, 0, 0)` | Black (off). |
| `white` | `static const FretColor = FretColor(255, 255, 255)` | Pure white. |
| `red` | `static const FretColor = FretColor(255, 0, 0)` | Pure red. |
| `green` | `static const FretColor = FretColor(0, 255, 0)` | Pure green. |
| `blue` | `static const FretColor = FretColor(0, 0, 255)` | Pure blue. |
| `magenta` | `static const FretColor = FretColor(255, 0, 255)` | Magenta. |
| `cyan` | `static const FretColor = FretColor(0, 255, 255)` | Cyan. |
| `yellow` | `static const FretColor = FretColor(255, 255, 0)` | Yellow. |
| `fromRgbInt` | `factory FretColor(int value)` | Construct from a 0xRRGGBB integer. |
| `toRgbInt` | `int toRgbInt()` | Convert to a 0xRRGGBB integer. |
| `==` / `hashCode` | inherited | Value equality based on `(r, g, b)`. |
| `toString` | `String toString()` | Returns `FretColor(#RRGGBB)`. |

#### FretHsl

Immutable. Hue: 0-360, Saturation: 0-1000.

| Member | Signature | Description |
|---|---|---|
| `hue` | `final int` | Hue (0-360). |
| `saturation` | `final int` | Saturation (0-1000). |
| `FretHsl` (constructor) | `const FretHsl(int hue, int saturation)` | Construct an HSL color. |
| `red` | `static const FretHsl = FretHsl(0, 1000)` | Red. |
| `green` | `static const FretHsl = FretHsl(120, 1000)` | Green. |
| `blue` | `static const FretHsl = FretHsl(240, 1000)` | Blue. |

### Code Example

```dart
final c = FretColor(255, 128, 0);            // orange
final same = FretColor.fromRgbInt(0xFF8000); // 0xRRGGBB
print(c == same);                            // true
print(c.toRgbInt());                         // 16744448

final hsl = FretHsl(30, 1000);               // orange-ish
await FretSpark.instance.led.setColor(device, hsl);
```

### FretNote / NoteName / ScaleType

#### FretNote

A single lit note on the fretboard.

| Member | Signature | Description |
|---|---|---|
| `string` | `final int` | String index, 0-indexed from highest pitch (high E = 0) to lowest (low E = 5). Mirrored to `5 - string` before being sent to the firmware if left-handed mode is on. Asserts `0 <= string <= 5`. |
| `fret` | `final int` | Fret index, 0-indexed (0 = open string, 1 = first fret). Maximum valid value is `device.maxFret`. Asserts `fret >= 0`. |
| `color` | `final FretColor` | Color of the LED. Defaults to `FretColor.white`. |
| `FretNote` (constructor) | `const FretNote({required int string, required int fret, FretColor color = FretColor.white})` | Construct a note. |
| `==` / `hashCode` | inherited | Value equality based on `(string, fret, color)`. |
| `toString` | `String toString()` | Returns `FretNote(string=..., fret=..., color=...)`. |

#### NoteName

Music note names used for chord/scale root lookup.

| Member | Description |
|---|---|
| `c`, `cSharp`, `d`, `dSharp`, `e`, `f`, `fSharp`, `g`, `gSharp`, `a`, `aSharp`, `b` | The twelve chromatic notes. |

`NoteNameParser` extension provides:

| Member | Signature | Description |
|---|---|---|
| `parse` (static) | `static NoteName? parse(String name)` | Parse a note name (case-insensitive). Accepts sharps (`C#`) and flats (`DB` = C-sharp, etc.). Returns `null` if unknown. |
| `semitone` | `int get semitone` | The semitone offset (0-11), equal to the enum index. |

#### ScaleType

Scale types supported by `FretLED.showScale`.

| Member | Description |
|---|---|
| `major` | Major (Ionian). |
| `naturalMinor` | Natural minor (Aeolian). |
| `harmonicMinor` | Harmonic minor. |
| `melodicMinor` | Melodic minor (ascending). |
| `majorPentatonic` | Major pentatonic. |
| `minorPentatonic` | Minor pentatonic. |
| `blues` | Blues scale. |
| `dorian` | Dorian mode. |
| `mixolydian` | Mixolydian mode. |
| `chromatic` | Chromatic scale. |

### Code Example

```dart
final n = FretNote(string: 0, fret: 3, color: FretColor.red);
print(n); // FretNote(string=0, fret=3, color=...)

final root = NoteNameParser.parse('C#') ?? NoteName.c;
print(root.semitone); // 1

await FretSpark.instance.led.showScale(
  device,
  root: NoteName.a,
  scale: ScaleType.minorPentatonic,
);
```

### BrandConfig

A FretSpark-compatible brand configuration.

Brand apps must call `FretSpark.initialize(brandId: ...)` with one of the IDs returned by `BrandConfig.id`. The SDK uses `firmwarePatterns` to filter BLE scan results so a brand's app only sees its own devices.

| Member | Type | Description |
|---|---|---|
| `id` | `String` | Brand unique identifier (lowercase English, e.g. `fretspark`, `smiger`). |
| `displayName` | `String` | Display name shown in the brand app's UI. |
| `deviceModel` | `String` | Device model label (e.g. `FS-86 PRO`, `SCT-86 PRO`). |
| `email` | `String` | Customer support email. Defaults to `auphy@auphymusic.com`. |
| `firmwarePatterns` | `List<String>` | Regex patterns that match this brand's firmware BLE advertising names. Patterns are case-insensitive. The first matching brand in the list wins. |
| `otaNamePrefix` | `String?` | Prefix used by the firmware when advertising in OTA mode (e.g. `SCT-86PRO OTA`). Used by `FretOTA.scanOtaDevice`. |
| `enabled` | `bool` | Whether this brand is currently enabled in the cloud config. Defaults to `true`. |

#### Methods

| Method | Signature | Description |
|---|---|---|
| `BrandConfig` (constructor) | `const BrandConfig({required String id, required String displayName, required String deviceModel, String email = 'auphy@auphymusic.com', required List<String> firmwarePatterns, String? otaNamePrefix, bool enabled = true})` | Construct a brand config. |
| `fromJson` | `factory BrandConfig.fromJson(Map<String, dynamic> json)` | Construct from JSON. Accepts both `device_model` and `product_model` keys for the device model. |
| `toJson` | `Map<String, dynamic> toJson()` | Serialize to JSON. |
| `matches` | `bool matches(String firmwareName)` | Test whether `firmwareName` matches any of `firmwarePatterns`. Case-insensitive. Returns `false` for an empty name. |
| `toString` | `String toString()` | Returns `BrandConfig(id=..., displayName=..., deviceModel=...)`. |

### FretBattery / FretFirmwareVersion / FretNotify

#### FretBattery

Latest battery reading parsed from a firmware notify frame.

| Member | Type | Description |
|---|---|---|
| `level` | `int` | Battery level (0-100). |
| `voltageMv` | `int` | Battery voltage in millivolts. |
| `FretBattery` (constructor) | `const FretBattery({required int level, required int voltageMv})` | Construct. |
| `toString` | `String toString()` | Returns `FretBattery(N%, MmV)`. |

#### FretFirmwareVersion

Firmware version parsed from a firmware notify frame.

| Member | Type | Description |
|---|---|---|
| `major`, `minor`, `revision`, `subCode` | `int` | Version segments. |
| `FretFirmwareVersion` (constructor) | `const FretFirmwareVersion({required int major, required int minor, required int revision, required int subCode})` | Construct. |
| `formatted` | `String get` | Dot-separated version string (e.g. `1.2.3.4`). |
| `toString` | `String toString()` | Returns `FretFirmwareVersion(1.2.3.4)`. |

#### FretNotify

A parsed firmware notification frame. Emitted by `FretDevice.onUnknownNotify` for firmware commands not handled by the typed streams.

| Member | Type | Description |
|---|---|---|
| `cmd` | `int` | Firmware command id. |
| `data` | `List<int>` | Payload bytes (excluding the frame delimiters and length byte). |
| `FretNotify` (constructor) | `FretNotify({required int cmd, required List<int> data})` | Construct. |
| `toString` | `String toString()` | Returns `FretNotify(cmd=0xNN, data=N bytes)`. |

### FretOtaProgress / FretOtaPhase

#### FretOtaProgress

Progress event emitted by `FretOTA.onProgress`.

| Member | Type | Description |
|---|---|---|
| `phase` | `FretOtaPhase` | Current OTA phase. |
| `sentBytes` | `int` | Bytes sent so far. |
| `totalBytes` | `int` | Total bytes to send. |
| `FretOtaProgress` (constructor) | `const FretOtaProgress({required FretOtaPhase phase, required int sentBytes, required int totalBytes})` | Construct. |
| `fraction` | `double get` | Progress as 0.0-1.0. |
| `percent` | `int get` | Progress as 0-100 (rounded). |
| `toString` | `String toString()` | Returns `FretOtaProgress(phase, sentBytes/totalBytes = percent%)`. |

#### FretOtaException

Thrown by `FretOTA.upgrade` on protocol or transport errors.

| Member | Signature | Description |
|---|---|---|
| `message` | `final String` | Error message. |
| `FretOtaException` (constructor) | `const FretOtaException(String message)` | Construct. |
| `toString` | `String toString()` | Returns `FretOtaException: message`. |

---

## Enums

### MicSource

Audio input source for voice-reactive LED mode. Used by `FretLED.setMicSource`. Maps to firmware command 0x0F.

| Value | Code | Description |
|---|---|---|
| `appMic` | `0x00` | APP-side microphone. Requires the brand APP to capture audio and feed energy samples via `FretLED.injectEnergy` at 30-60 Hz. |
| `localMic` | `0x01` | Device-local microphone (built into the guitar hardware). |
| `vibration` | `0x06` | Vibration / pickup sensor (piezo) on the hardware. |
| `off` | `0xFF` | Disable voice input entirely. |

Each value exposes a `final int code`.

### MusicMode

High-level music mode. Used by `FretLED.setMusicMode`. Maps to firmware command 0x09. Distinct from the AI rhythm LED effects (modes 124-135), which are sent via the standard `FretLED.setMode` command.

| Value | Code | Description |
|---|---|---|
| `normal` | `0x00` | Normal operation — no special music mode active. |
| `metronome` | `0x01` | Built-in metronome. Extra params: `[bpmH, bpmL, timeSig]`. |
| `looper` | `0x02` | Looper mode. Extra params: firmware-defined. |
| `drums` | `0x03` | Drum machine mode. Extra params: firmware-defined. |
| `bass` | `0x04` | Bass accompaniment mode. Extra params: firmware-defined. |

Each value exposes a `final int code`.

### FretTimeSignature

Time signatures accepted by the firmware metronome. Used by `FretMetronome.start`. Maps to firmware command 0x20.

| Value | Beats | Description |
|---|---|---|
| `twoFour` | `2` | 2/4 time. |
| `threeFour` | `3` | 3/4 time. |
| `fourFour` | `4` | 4/4 time. |
| `sixEight` | `6` | 6/8 time. |

Each value exposes a `final int beats`.

### FretFirmwareStatus

Status of the firmware-update pipeline. Brand apps can listen to `FretFirmwareDownloader.onStatusChanged` and map each value to a localized UI string.

| Value | Description |
|---|---|
| `idle` | Idle — no operation in progress. |
| `checking` | Fetching the manifest from the OTA server. |
| `checkDone` | Manifest fetched successfully. Brand apps usually transition to `updateAvailable` or `upToDate` based on version comparison. |
| `upToDate` | The device is already running the latest firmware available on the server. No download required. |
| `updateAvailable` | A newer firmware version is available on the server. |
| `checkFailed` | Manifest fetch failed (network error, non-200 status, etc.). |
| `downloading` | Firmware file is being downloaded. |
| `downloadComplete` | Download completed successfully and the file is ready on disk. |
| `downloadFailed` | Download failed (network error, disk full, etc.). |
| `ready` | A previously-downloaded firmware file is already on disk and matches the requested brand. No re-download required. |

### FretOtaPhase

OTA upgrade phase. Used by `FretOtaProgress`.

| Value | Description |
|---|---|
| `idle` | Idle. |
| `connecting` | Connecting to the OTA-mode device. |
| `starting` | Sending START_OTA. |
| `transferring` | Streaming firmware data. |
| `rebooting` | Sending REBOOT. |
| `success` | Upgrade succeeded. |
| `failed` | Upgrade failed. |

---

## Transport Interfaces

### FretTransport / FretBleDevice

#### FretTransport

Abstraction over the BLE transport layer.

The SDK ships a default `FlutterBlueTransport` implementation. Brand apps that use a different BLE stack (React Native, native iOS/Android, Web Bluetooth) can provide their own implementation and inject it via `FretSpark.initialize(transport: ...)`. All methods are async and may throw `FretTransportException`.

| Member | Signature | Description |
|---|---|---|
| `requestPermissions` | `Future<bool> requestPermissions()` | Request OS-level permissions (Bluetooth scan/connect, location on Android <= 11). Returns `true` if all required permissions are granted. |
| `isAdapterOn` | `Future<bool> get isAdapterOn` | Returns `true` if the device's Bluetooth adapter is on and ready. |
| `startScan` | `Future<void> startScan({Duration timeout = const Duration(seconds: 10), String? serviceUuid})` | Start a BLE scan. Results are emitted on `scanResults`. If `serviceUuid` is non-null, the scan is filtered to that service. |
| `stopScan` | `Future<void> stopScan()` | Stop an in-flight scan. |
| `scanResults` | `Stream<FretScanResult> get` | Stream of scan results discovered during `startScan`. Each result is emitted once per device id. |
| `connect` | `Future<FretBleDevice> connect(String deviceId)` | Connect to a device. Performs MTU negotiation and service discovery. Throws if connection fails after retries. |
| `disconnect` | `Future<void> disconnect(String deviceId)` | Disconnect from a device. |
| `connectionStates` | `Stream<FretConnectionState> get` | Stream of connection-state changes per device. |

#### FretScanResult

A single BLE scan result.

| Member | Type | Description |
|---|---|---|
| `id` | `String` | BLE device id. |
| `name` | `String` | BLE advertised name. |
| `rssi` | `int` | RSSI value. |
| `FretScanResult` (constructor) | `const FretScanResult({required String id, required String name, required int rssi})` | Construct. |
| `toString` | `String toString()` | Returns `FretScanResult(name, id, rssi=...)`. |

#### FretConnectionState

Connection-state change event.

| Member | Type | Description |
|---|---|---|
| `deviceId` | `String` | BLE device id. |
| `isConnected` | `bool` | Whether the device is connected. |
| `FretConnectionState` (constructor) | `const FretConnectionState({required String deviceId, required bool isConnected})` | Construct. |

#### FretBleDevice

A connected BLE device with the runtime command service configured. The SDK owns the write/notify subscriptions. Brand apps interact with the device via `FretDevice` (returned by `FretSpark.connection.connect`), not via this raw transport interface.

| Member | Signature | Description |
|---|---|---|
| `id` | `String get` | BLE device id. |
| `name` | `String get` | BLE advertised name. |
| `negotiatedMtu` | `int get` | Negotiated MTU. |
| `write` | `Future<void> write(Uint8List payload)` | Write a payload to the command-write characteristic without response. Falls back to with-response write if the platform rejects the no-response variant. |
| `notifyStream` | `Stream<List<int>> get` | Stream of notify frames from the notify characteristic (raw bytes, as delivered by the OS). |
| `readClassroomId` | `Future<int?> readClassroomId()` | Read the 4-byte big-endian classroom ID from the classroom-ID characteristic. Returns `null` if the characteristic is missing or the read times out. |
| `writeClassroomId` | `Future<void> writeClassroomId(int id)` | Write the 4-byte big-endian classroom ID to the classroom-ID characteristic. |
| `disconnect` | `Future<void> disconnect()` | Disconnect and release all resources. |

#### FretTransportException

| Member | Signature | Description |
|---|---|---|
| `message` | `final String` | Error message. |
| `FretTransportException` (constructor) | `const FretTransportException(String message)` | Construct. |
| `toString` | `String toString()` | Returns `FretTransportException: message`. |

### FretOtaTransport

Abstraction over the BLE operations `FretOTA.upgrade` needs to drive the Nordic-style OTA service.

The default implementation `FlutterBlueOtaTransport` wraps `flutter_blue_plus` calls; tests inject a fake to script the full OTA protocol. Brand apps with a non-flutter_blue_plus BLE stack can provide their own implementation.

| Member | Signature | Description |
|---|---|---|
| `connect` | `Future<void> connect(String deviceId, {required Duration timeout})` | Connect to the OTA-mode device at `deviceId`. Should retry on transient failures. Throws on unrecoverable failure. |
| `discoverOtaService` | `Future<void> discoverOtaService({required Duration timeout})` | Discover GATT services and resolve the OTA service's cmd / rsp / data characteristics. Throws `FretOtaException` if the OTA service or any of the three characteristics are missing. |
| `setRspNotifyValue` | `Future<void> setRspNotifyValue(bool enable, {required Duration timeout})` | Enable or disable notifications on the rsp characteristic. |
| `writeCmd` | `Future<void> writeCmd(Uint8List data)` | Write `data` to the cmd characteristic with response. |
| `writeData` | `Future<void> writeData(Uint8List data, {required bool withoutResponse})` | Write `data` to the data characteristic. The implementation must respect the platform's write-without-response queue. |
| `rspNotifyStream` | `Stream<List<int>> get` | Stream of byte buffers arriving on the rsp characteristic. Each emission is a complete notify payload as delivered by the OS. |
| `disconnect` | `Future<void> disconnect({required Duration timeout})` | Disconnect from the device and release GATT resources. Implementations should swallow errors so callers can use this in a `finally` block. |

#### FlutterBlueOtaTransport

Default `FretOtaTransport` backed by `flutter_blue_plus`. Wraps `BluetoothDevice.fromId` + `connect` + `discoverServices` + `BluetoothCharacteristic.write/setNotifyValue/Value` so that `FretOTA.upgrade` can be unit-tested against a fake transport.

Construct with `FlutterBlueOtaTransport()`. Connection retries up to 3 times with a 1-second delay between attempts. `setRspNotifyValue` is best-effort (some platforms reject `setNotifyValue` when already subscribed; the notify stream is still wired).

### WebBluetoothTransport

A `FretTransport` implementation backed by the Web Bluetooth API. Only available on the Web platform. On Android, iOS, macOS, Windows, and Linux, constructing it throws `UnsupportedError` (via the conditional export stub).

**How to access:** construct directly and pass to `FretSpark.initialize(transport: ...)`.

```dart
await FretSpark.instance.initialize(
  brandId: 'auphy',
  transport: WebBluetoothTransport(),
);
```

#### Web Bluetooth Limitations

1. **No background scanning.** The browser shows a device-picker dialog and the user manually selects a device. Call `startScan` to trigger the picker; the selected device is emitted on `scanResults`.
2. **No RSSI.** All scan results report `rssi=0`.
3. **No MTU negotiation.** MTU is fixed at `23`. The SDK's packet codec already splits payloads into <=20-byte frames, so this is not an issue.
4. **User gesture required.** `startScan` must be called from a user gesture (e.g. a button tap).
5. **HTTPS required.** Web Bluetooth only works on HTTPS (or localhost).
6. **Browser support.** Chrome, Edge, Opera. Not Firefox or Safari.

The `startScan` device picker filters by the name prefixes `SCT-86PRO`, `FretSpark`, and `AUPHY`, with `0000fff0-...` as an optional service.

#### GATT UUIDs (used internally)

| Constant | Value |
|---|---|
| Service | `0000fff0-0000-1000-8000-00805f9b34fb` |
| Write | `0000fff3-0000-1000-8000-00805f9b34fb` |
| Notify | `0000fff4-0000-1000-8000-00805f9b34fb` |
| Classroom ID | `0000fff6-0000-1000-8000-00805f9b34fb` |

The default `FlutterBlueTransport` uses the same UUIDs.

---

## FretCommand Constants

Firmware command codes (0x01 ~ 0x2A). These constants are internal to the SDK. Public API classes wrap each command with guitar-semantic methods; brand apps should never need to reference these codes directly except when using `FretAdvanced.sendRaw`.

### Packet Format

```
APP -> firmware:  [0xBC, cmd, paramsLen, ...params, 0x55]
firmware -> APP:  [0xCC, cmd, len, ...data, 0xAA]
```

### Frame Delimiters

| Constant | Value | Description |
|---|---|---|
| `kFrameStartAppTo_FW` | `0xBC` | App-to-firmware frame start. |
| `kFrameEndAppToFW` | `0x55` | App-to-firmware frame end. |
| `kFrameStartFWToApp` | `0xCC` | Firmware-to-app frame start. |
| `kFrameEndFWToApp` | `0xAA` | Firmware-to-app frame end. |

### Power / Brightness / Color

| Constant | Value | Payload | Description |
|---|---|---|---|
| `power` | `0x01` | `[0x01=on / 0x00=off]` | Power on/off. |
| `enterOta` | `0x01` | `[0x02, 0x01]` | Tell the device to reboot into OTA mode (sent via the runtime command service). Reuses the `power` 0x01 byte but with different params. |
| `linearLayout` | `0x02` | `[0/1]` | RGB layout mode (0 = matrix layout, 1 = linear layout). Adapts to hardware with different LED arrangements such as WS2812/SK6812. |
| `ledCount` | `0x03` | `[countH, countL]` | Set the LED count (uint16 big-endian). Used by the APP to dynamically adjust the number of LEDs the firmware drives. |
| `color` | `0x04` | `[hueH, hueL, satH, satL, 0, 0]` | Set the base HSL color. |
| `brightness` | `0x05` | `[briH, briL, 0, 0, 0, 0]` | Set brightness (0-1000). |
| `mode` | `0x06` | `[modeH, modeL]` | Set effect mode. |
| `direction` | `0x07` | `[dir]` | Set effect direction. |
| `speed` | `0x08` | `[speed]` | Set effect speed. |
| `musicMode` | `0x09` | AI rhythm, compound params | Set the high-level music mode. |

### Notify / RTC / Query

| Constant | Value | Payload | Description |
|---|---|---|---|
| `batteryNotify` | `0x0A` | `[level, mvH, mvL]` | Battery notify (firmware-pushed). |
| `rtcTime` | `0x0B` | `[yyH, yyL, MM, dd, HH, mm, ss]` (7 bytes) | Sync the RTC time (firmware uses this as the reference clock for the 0x0D scheduled power on/off). |
| `queryStatus` | `0x0C` | `[0x01]` | Trigger the firmware to proactively report its status. Firmware internally calls `send_type_request(8)` and `send_type_request(9)`. |
| `timer` | `0x0D` | `[slot, onOff, HH, mm, ss, 0x00]` | Set scheduled power on/off (depends on the RTC time synced via 0x0B). `slot`: timer slot index. `onOff`: 0 = scheduled power-off, non-zero = scheduled power-on. The reserved byte is fixed at 0. |

### Voice / Mic

| Constant | Value | Payload | Description |
|---|---|---|---|
| `micSource` | `0x0F` | `[0=appMic / 1=localMic / 6=vibration / 0xFF=off]` | Set the active microphone / pickup source. |
| `staticColor` | `0x10` | legacy | **Deprecated.** Serves two conflicting duties in the firmware — "static color" and "APP mic energy injection" (it pins `device_rgb_state` to 4, disabling AI rhythm rendering). The SDK has replaced it with `fillColor` (0x15) + `energyInject` (0x26). Brand apps should avoid this command. |
| `voiceMode` | `0x11` | `[0x00=on / 0xFF=off]` | Enable / disable voice-reactive mode. |
| `voiceSensitivity` | `0x12` | `[value]` | Set voice-reactive sensitivity. |
| `knobHsl` | `0x13` | `[valH, valL]` | Physical knob HSL report (firmware-pushed notify; the APP may also simulate knob input). `val` is a uint16 (0-360). Rarely used on the APP side; kept for advanced developers. |

### Drawing / Fill

| Constant | Value | Payload | Description |
|---|---|---|---|
| `fillRange` | `0x14` | `[start, r,g,b, r,g,b, ...]` | Custom continuous-segment LED colors (writes N consecutive LEDs starting at `start_index`). `len` (the LEN field in the BLE frame) = `1 + 3N`. Single-packet N <= 79. Difference from `batchData` (0x16): 0x14 is a contiguous segment refreshed in a single frame (high performance); 0x16 is a sparse segment (each LED index specified independently) and must be wrapped by 0x1C/0x1D batch transfer. |
| `fillColor` | `0x15` | `[0, r, 0, g, 0, b]` | Fill the entire fretboard with a solid RGB color. |
| `batchData` | `0x16` | `[seq, count, idx, r, g, b, ...]` | Sparse LED data (used by `lightNotes`). |
| `groupEnd` | `0x17` | `[]` | Immediate group-channel refresh (legacy). |
| `selectionMask` | `0x18` | `[50-byte bitmap]` or `[]` | Lock / clear the active selection mask. |
| `groupMap` | `0x19` | `[baseIdx, ...groupIds]` or `[]` | Set / clear the group assignment map. |
| `groupColor` | `0x1A` | `[gid, r, g, b]` | Set a single group's color. |
| `musicStyle` | `0x1B` | `[styleId]` | Set the music style (a style system independent of `mode` 0x06 and `musicMode` 0x09). Firmware internally calls `apply_music_style(styleId)`. `styleId` is a single byte (0-255); values >= 100 are reset to 0 by the firmware (protection logic used when switching the pickup source). |
| `batchBegin` | `0x1C` | `[packetCount]` (0 = state-only) | Begin a batched transfer transaction. |
| `batchEnd` | `0x1D` | `[]` | End a batched transfer transaction and refresh. |

### Query (Notify Response)

| Constant | Value | Response | Description |
|---|---|---|---|
| `queryVersion` | `0x1E` | `[major, minor, rev, sub]` | Query firmware version. |
| `queryLedConfig` | `0x1F` | `[ledCountH, ledCountL]` | Query LED config (LED count). |

### Metronome

| Constant | Value | Payload | Description |
|---|---|---|---|
| `metronomeStart` | `0x20` | `[bpmH, bpmL, timeSig]` | Start the metronome. |
| `metronomeStop` | `0x21` | `[]` | Stop the metronome. |

### Learning LED

| Constant | Value | Payload | Description |
|---|---|---|---|
| `learningLed` | `0x22` | `[0=clear / 1=single / 2=multi, ...]` | Light / clear learning LEDs. |

### Classroom (Nordic PPP)

| Constant | Value | Payload | Description |
|---|---|---|---|
| `teacherTxStart` | `0x23` | `[]` | Start broadcasting LED state as a teacher. |
| `studentRxStart` | `0x24` | `[]` | Start listening for teacher broadcasts as a student. |
| `classroomStop` | `0x25` | `[]` | Stop classroom mode. |

### Energy Injection (App Mic)

| Constant | Value | Payload | Description |
|---|---|---|---|
| `energyInject` | `0x26` | `[eH, eL]` | Inject a single audio-energy sample from the APP microphone. |

### LED Index Mode

| Constant | Value | Payload | Description |
|---|---|---|---|
| `setLedIndexMode` | `0x27` | `[0=normal / 1=reversed]` | Set the LED index order. |
| `queryLedIndexMode` | `0x28` | `[0/1]` | Query the LED index mode. |

### DIY Mode List

| Constant | Value | Payload | Description |
|---|---|---|---|
| `setDiyModeList` | `0x29` | `[count, ...modeIds]` | Set the user's DIY mode list. |
| `queryDiyModeList` | `0x2A` | list | Query the current DIY mode list. |

### Coalesce / Limits

| Constant | Value | Description |
|---|---|---|
| `coalesceCommands` | `{color, brightness, speed, voiceSensitivity, learningLed}` | Commands that should be coalesced in the send queue (only the latest param wins). High-frequency commands that would otherwise flood the firmware `BLE_RX_QUEUE_DEPTH=4`. |
| `maxLedsPerPacket` | `59` | Max LEDs per single packet (protocol constraint). Frame = `[0xBC, 0x22, len, 0x02, count, idx, r, g, b x N, 0x55]` = `7 + 4N`. MTU=247 → writeWithoutResponse max 244 → N <= 59. |
| `maxLedsPerFillRangePacket` | `79` | Max LEDs per `fillRange` (0x14) single packet. Frame = `[0xBC, 0x14, len, start, r,g,b x N, 0x55]` = `6 + 3N`. MTU=247 → N <= 79. |
| `bleRxFrameMaxLen` | `250` | Firmware `BLE_RX_FRAME_MAX_LEN`. Single packets must not exceed this. |

---

## End-to-End Example

A complete flow from initialization to OTA upgrade.

```dart
import 'package:fretspark_sdk/fretspark_sdk.dart';

Future<void> main() async {
  // 1. Initialize the SDK for the AUPHY brand.
  await FretSpark.instance.initialize(
    brandId: 'auphy',
    manifestUrl: 'https://ota.auphygt.com/manifest.json',
    brandConfigUrl: 'https://ota.auphygt.com/brands.json',
  );

  final connection = FretSpark.instance.connection;
  final led = FretSpark.instance.led;
  final metronome = FretSpark.instance.metronome;
  final firmware = FretSpark.instance.firmware;
  final ota = FretSpark.instance.ota;

  // 2. Request permissions and scan.
  if (!await connection.requestPermissions()) {
    throw StateError('Bluetooth permissions denied');
  }
  final scanSub = connection.scanResults.listen((r) {
    print('Found: ${r.name} (${r.id})');
  });
  await connection.startScan(timeout: const Duration(seconds: 10));
  await scanSub.cancel();

  // 3. Connect to the first discovered device.
  final device = await connection.connect(deviceId);

  // 4. Drive the LEDs.
  await led.setPower(device, on: true);
  await led.fillColor(device, FretColor.red);
  await led.showChord(device, root: NoteName.c, chordType: 'maj');
  await led.clearAll(device);

  // 5. Run the metronome.
  await metronome.start(device, bpm: 120, timeSignature: FretTimeSignature.fourFour);
  await Future<void>.delayed(const Duration(seconds: 5));
  await metronome.stop(device);

  // 6. Check for a firmware update.
  final sub = firmware.onStatusChanged.listen((s) => print('FW: $s'));
  final path = await firmware.checkAndDownload(
    manifestUrl: FretSpark.instance.manifestUrl!,
    brandId: 'auphy',
    currentVersion: device.firmwareVersion,
  );
  await sub.cancel();

  // 7. If a newer firmware was downloaded, run OTA.
  if (path != null) {
    final bytes = await firmware.readLocalFirmwareBytes(brandId: 'auphy');
    if (bytes != null) {
      final progressSub = ota.onProgress.listen((p) {
        print('OTA: ${p.phase.name} ${p.percent}%');
      });
      try {
        await ota.enterOtaMode(device);
        final otaDevice = await ota.scanOtaDevice('SCT-86PRO OTA');
        if (otaDevice != null) {
          await ota.upgrade(otaDevice.id, bytes);
        }
      } on FretOtaException catch (e) {
        print('OTA failed: $e');
      } finally {
        await progressSub.cancel();
        ota.dispose();
      }
    }
  }

  // 8. Tear down.
  await FretSpark.instance.dispose();
}
```
