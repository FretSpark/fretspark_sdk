# FretSpark SDK

Official Flutter SDK for FretSpark smart-guitar fretboard firmware. Connect,
control LEDs, run the metronome, and upgrade firmware across all
FretSpark-compatible brands (FretSpark, AUPHY, Smiger, NATASHA, Bullfighter,
Deviser).

> **License**: MIT for open-source apps. Commercial brands that ship the SDK
> inside a closed-source app should obtain a commercial license — see
> [LICENSE](LICENSE).

## Installation

Add to your brand app's `pubspec.yaml`:

```yaml
dependencies:
  fretspark_sdk:
    git:
      url: https://github.com/fretspark/fretspark_sdk.git
      ref: v1.0.0
```

Or after the package is published to pub.dev:

```yaml
dependencies:
  fretspark_sdk: ^1.0.0
```

## Quick start

```dart
import 'package:fretspark_sdk/fretspark_sdk.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FretSpark.instance.initialize(brandId: 'auphy');

  final ok = await FretSpark.instance.connection.requestPermissions();
  if (!ok) return;

  FretSpark.instance.connection.scanResults.listen((r) async {
    if (r.name.startsWith('SCT-86PRO')) {
      await FretSpark.instance.connection.stopScan();
      final device = await FretSpark.instance.connection.connect(r.id);
      await FretSpark.instance.led.fillColor(device, FretColor.red);
    }
  });
  await FretSpark.instance.connection.startScan();
}
```

## Architecture

```
┌────────────────────────────────────────────────────┐
│                  Brand App (your code)             │
└──────────────────────┬─────────────────────────────┘
                       │ imports fretspark_sdk.dart
                       ▼
┌────────────────────────────────────────────────────┐
│              Public API (api/ + models/)           │
│  FretSpark  →  FretConnection / FretLED /          │
│                FretBrand / FretOTA / FretMetronome │
│  FretDevice  FretColor  FretNote  BrandConfig      │
└──────────────────────┬─────────────────────────────┘
                       │
        ┌──────────────┴──────────────┐
        ▼                             ▼
┌──────────────────┐         ┌────────────────────┐
│  transport/      │         │     core/          │
│  FretTransport   │         │  协议编解码        │
│  FlutterBlue     │         │  发送队列          │
│  (default impl)  │         │  批量传输          │
└──────────────────┘         │  通知分发(内部实现)│
                             └────────────────────┘
```

The protocol layer (`core/`) and the default transport implementation
(`transport/flutter_blue_transport.dart`) are **internal** — they are not
re-exported from `fretspark_sdk.dart`. Brand apps interact with the device
exclusively through the public API classes and the `FretSpark` singleton.

## Public API

### `FretSpark` (singleton)

| Method / getter | Description |
|---|---|
| `initialize({brandId, transport?, licenseKey?})` | One-time setup. Loads bundled brand list, sets the active brand, creates the default `FlutterBlueTransport` (or uses your custom transport). |
| `connection` | `FretConnection` — scan & connect. |
| `led` | `FretLED` — power / color / brightness / effects / chords / scales. |
| `brand` | `FretBrand` — brand config lookup. |
| `ota` | `FretOTA` — firmware upgrade. |
| `metronome` | `FretMetronome` — firmware metronome control. |
| `transport` | The underlying `FretTransport` (rarely needed directly). |

### `FretConnection`

| Method | Description |
|---|---|
| `requestPermissions()` | Request OS Bluetooth permissions (Android 12+: `bluetoothScan` + `bluetoothConnect`; Android ≤11: `location`). |
| `get isAdapterOn` | Whether the Bluetooth adapter is on. |
| `startScan({timeout})` / `stopScan()` | Scan lifecycle. |
| `scanResults` | Stream filtered by the active brand's `firmwarePatterns`. |
| `connect(deviceId)` | Connect + handshake. Returns `FretDevice`. |
| `disconnect()` | Disconnect the current device. |
| `current` | The currently-connected `FretDevice`, or `null`. |

### `FretLED`

| Method | Description |
|---|---|
| `setPower(device, {on})` | Turn the LED panel on or off. |
| `setBrightness(device, brightness)` | Set global brightness. Range 0–1000. |
| `setColor(device, FretHsl)` | Set the base color using HSL. |
| `fillColor(device, FretColor)` | Fill the entire fretboard with a solid RGB color. |
| `fillRange(device, {startIndex, colors})` | Fill a continuous LED range with per-LED colors in a single packet. ≤79 LEDs/call. Faster than `lightNotes` for contiguous segments. |
| `setMode(device, modeId)` | Switch to a built-in effect mode. `modeId` is 1-based. |
| `setMusicStyle(device, styleId)` | Switch to a music style. Independent of `setMode` and `setMusicMode`. Range 0–99. |
| `setSpeed(device, speed)` | Set effect speed. Range 0–255. |
| `setDirection(device, direction)` | Set effect direction. 0 = forward, 1 = reverse. |
| `setLinearLayout(device, {linear})` | Set the RGB physical layout. `true` = linear strip (WS2812/SK6812), `false` = matrix. Call before any rendering command. |
| `setLedCount(device, count)` | Override the total LED count. Use when the hardware strip length ≠ firmware default. Refresh via `device.queryLedConfig()` + `onLedCountChanged`. |
| `setTimer(device, {on, hour, minute, second, slot})` | Configure a scheduled power on/off timer. Requires `device.setRtcTime()` first. |
| `clearAll(device)` | Turn all LEDs off without an intermediate black-flash. |
| `lockSelection(device, ledIndices)` / `unlockSelection` | Lock/clear the active selection mask so subsequent commands only apply to the selected LEDs. |
| `lightNote(device, FretNote)` | Light a single note. |
| `lightNotes(device, List<FretNote>)` | Light multiple notes. Notes are de-duplicated by LED index. |
| `clearLearningLEDs(device)` | Clear all learning LEDs. |
| `showChord(device, {root, chordType, color})` | Light a chord across the fretboard using the built-in chord dictionary. |
| `showScale(device, {root, scale, color})` | Light a scale across the fretboard. |
| `leftHandedMode` / `setLeftHandedMode(bool)` | Persisted to `SharedPreferences`. When `true`, string indices are mirrored 0↔5. |
| `setMusicMode(device, MusicMode, {extraParams})` | High-level music mode (normal/metronome/looper/drums/bass). |
| `setMicSource(device, MicSource)` | Set the active microphone / pickup source. |
| `setVoiceMode(device, {on})` | Enable or disable voice-reactive mode. |
| `setVoiceSensitivity(device, value)` | Set voice-reactive sensitivity. Range 0–255. |
| `injectEnergy(device, volume)` | Inject a single audio-energy sample. `volume` is 16-bit. Call at 30–60 Hz while the APP captures audio. |
| `applyGroupFrame(device, {groupAssignments, groupColors})` | Render a full group-color frame in one batch. |
| `setGroupColor(device, groupId, FretColor)` | Set the color of a single group. Low-level escape hatch. |
| `applyGroupMap(device, baseIdx, groupIds)` | Assign LEDs to groups. Low-level escape hatch. |
| `clearGroupMap(device)` | Clear all group assignments and exit group-color mode. |
| `flushGroupImmediate(device)` | Trigger an immediate LED refresh in the group channel. Legacy. |
| `setDiyModeList(device, modeIds)` | Curate the user's DIY effect list (modes 1–117). |
| `queryDiyModeList(device)` | Query the current DIY mode list. Response via `FretDevice.onDiyModeList`. |
| `setLedIndexMode(device, {reversed})` | Set the LED index order (for newer hardware with reversed wiring). |

### `FretClassroom`

Classroom / local-teaching mode. Teacher's LED state is mirrored to all
students on the same classroom ID via a device-to-device broadcast
channel.

| Method | Description |
|---|---|
| `startTeacher(device)` | Begin broadcasting LED frames. |
| `startStudent(device)` | Begin listening for teacher broadcasts. |
| `stop(device)` | Exit classroom mode (either role). |

The brand APP is responsible for setting classroom IDs
(`FretDevice.setClassroomId`) and enforcing that only one device acts as
teacher per classroom.

### `FretDevice` (RTC & runtime queries)

In addition to the auto-queried fields populated on `connect()`
(`firmwareVersion`, `ledCount`, `ledIndexReversed`, `classroomId`),
`FretDevice` exposes these runtime methods:

| Method | Description |
|---|---|
| `setRtcTime(DateTime)` | Sync the device RTC. **Required before `FretLED.setTimer`** — the firmware uses RTC for scheduled power on/off. |
| `queryVersion()` | Re-query firmware version. Result via `onFirmwareVersionQueried`. Use after a manual upgrade. |
| `queryLedConfig()` | Re-query LED count. Result via `onLedCountChanged`. Use after `setLedCount` or hardware hot-swap. |
| `queryStatus()` | Trigger the firmware to push its current status (battery, etc.) via notify. Result via `onBatteryChanged`. |

### `FretAdvanced` (escape hatch)

Static methods that bypass the high-level API and send raw firmware
commands. **Use only when `FretLED` / `FretMetronome` / `FretClassroom`
do not wrap the command you need.** See the class doc comment for the
full list of caveats.

| Method | Description |
|---|---|
| `FretAdvanced.sendRaw(device, cmd, params, {bypassQueue})` | Send a raw command via the normal send queue (coalescing still applies). Use `FretCommand.xxx` for `cmd`. |
| `FretAdvanced.sendRawFireAndForget(device, cmd, params)` | Same, but does not await the queue. For high-frequency animation frames where dropped packets are acceptable. |

### `FretFirmwareDownloader`

Optional HTTP layer for OTA firmware distribution. Fetches `manifest.json`
from your OTA server, picks the firmware entry for the active brand,
compares versions, downloads the file, and caches it on disk. Pairs
naturally with [FretOTA] for the actual BLE transfer.

```dart
await FretSpark.instance.initialize(
  brandId: 'auphy',
  manifestUrl: 'https://your-ota.com/ota_firmware/manifest.json',
);

// After connecting a device:
final device = await FretSpark.instance.connection.connect(deviceId);

// One-shot: check → compare → download (if newer).
final path = await FretSpark.instance.firmware.checkAndDownload(
  manifestUrl: FretSpark.instance.manifestUrl!,
  brandId: device.brandId,
  currentVersion: device.firmwareVersion,
  onProgress: (p) => print('下载 ${(p * 100).toInt()}%'),
);
if (path == null) {
  print('已是最新版本或检查失败');
  return;
}

// Read the cached bytes and hand them to FretOTA.
final bytes = await FretSpark.instance.firmware.readLocalFirmwareBytes(
  brandId: device.brandId,
);
if (bytes == null) return;

// Enter OTA mode + scan + upgrade (see FretOTA section above).
await FretSpark.instance.ota.enterOtaMode(device);
final otaDevice = await FretSpark.instance.ota.scanOtaDevice('AUPHY-OTA');
await FretSpark.instance.ota.upgrade(otaDevice!.id, bytes);
```

| Method | Description |
|---|---|
| `checkForUpdate({manifestUrl, brandId, force})` | Fetch manifest, return `FretFirmwareInfo?` for the brand. 24h throttle by default. |
| `download({manifestUrl, brandId, onProgress})` | Download the firmware file to local cache. Returns path or `null`. |
| `checkAndDownload({...})` | One-shot: check + version-compare + download-if-newer. |
| `getLocalFirmwarePath({brandId})` / `getLocalFirmwareVersion` | Inspect the local cache. |
| `readLocalFirmwareBytes({brandId})` | Read cached file as bytes (for passing to `FretOTA.upgrade`). |
| `deleteLocalFirmware()` | Wipe the cache (call after successful upgrade or on brand switch). |
| `compareVersions(a, b)` | Static 4-segment semver compare. Returns `>0` if `a` newer. |
| `onStatusChanged` | Stream of `FretFirmwareStatus` (idle / checking / upToDate / updateAvailable / downloading / downloadComplete / downloadFailed / ...). |

The downloader refuses to install a firmware file whose `brandId` does
not match the manifest entry — preventing cross-brand mismatches
(e.g. flashing AUPHY firmware onto a Smiger device).

#### Manifest format

```json
{
  "version": "3.1.3.4",
  "releaseNotes": "Fix BLE reconnection stability, add energy injection API.",
  "brands": [
    {
      "id": "auphy",
      "version": "3.1.3.4",
      "file": "firmware.auphy.3.1.3.4.hex16",
      "size": 245760,
      "otaNamePrefix": "AUPHY-OTA",
      "releaseNotes": "Brand-specific notes (optional)."
    },
    {
      "id": "smiger",
      "version": "3.1.3.2",
      "file": "firmware.smiger.3.1.3.2.hex16",
      "size": 245760,
      "otaNamePrefix": "SMIGER-OTA"
    }
  ]
}
```

Each brand MUST have its own `version` field (different brands may ship
at different paces). Legacy single-file manifests (top-level
`file`/`size`/`version` without a `brands` array) are still accepted
for backwards compatibility.

### `FretOTA`

| Method | Description |
|---|---|
| `enterOtaMode(device, {rebootDelay})` | Tell a connected runtime device to reboot into OTA mode. Waits 2 s for the device to start advertising its OTA name. |
| `scanOtaDevice(prefix, {timeout})` | Scan for an OTA-mode device whose advertised name starts with the brand's `otaNamePrefix`. |
| `upgrade(deviceId, fileBytes)` | Run the full OTA protocol: connect → start → partition info → 16-packet bursts with ACK retransmission → reboot. |
| `onProgress` | Stream of `FretOtaProgress` events (`{phase, sentBytes, totalBytes}`). |

The OTA implementation uses `flutter_blue_plus` directly because the OTA
GATT service is separate from the runtime command service.

### `FretMetronome`

| Method | Description |
|---|---|
| `start(device, {bpm, timeSignature})` | Start the metronome. `bpm` 40–240. |
| `stop(device)` | Stop the metronome. |

### `FretBrand`

| Method | Description |
|---|---|
| `loadFallback()` | Load the bundled `assets/brands_fallback.json`. Called automatically by `FretSpark.initialize`. |
| `syncFromCloud(jsonPayload)` | Replace the in-memory brand list with a cloud-fetched payload. |
| `setActive(brandId)` | Set the active brand. |
| `matchByFirmwareName(name)` | Find the brand whose `firmwarePatterns` match a BLE advertised name. |
| `activeBrand` / `allBrands` | Getters. |

## Brand onboarding

To add a new brand:

1. **Add a `BrandConfig` entry** to `assets/brands_fallback.json`:
   ```json
   {
     "id": "yourbrand",
     "display_name": "YourBrand",
     "device_model": "YB-86",
     "email": "support@yourbrand.com",
     "ota_name_prefix": "YB-86 OTA",
     "firmware_patterns": [
       "^YB-86-[A-Z0-9]{4}$",
       "^YB-86[ -_]?OTA$"
     ],
     "enabled": true
   }
   ```
2. **Build a brand app** that calls `FretSpark.instance.initialize(brandId: 'yourbrand')`.
3. **Test scan filtering**: your app should only see devices whose advertised name matches one of your `firmware_patterns`.
4. **OTA**: ensure your firmware advertises the OTA-mode name (`ota_name_prefix`) when rebooted into OTA mode.

For closed-source brand apps, obtain a commercial license from
support@fretspark.com before publishing.

## Example

See `example/` for a minimal Flutter app that scans, connects, lights a
C-major chord, and upgrades firmware.

## Firmware command coverage

The full firmware protocol uses 30 command codes (`0x01`–`0x2A`). The
table below shows which commands are wrapped by a high-level SDK API,
which are exposed only via `FretAdvanced.sendRaw`, and which are
intentionally not exposed.

| Cmd | Firmware function | SDK high-level API | Notes |
|---|---|---|---|
| 0x01 | Power on/off | `FretLED.setPower` | |
| 0x02 | RGB layout (matrix/linear) | `FretLED.setLinearLayout` | For WS2812/SK6812 strips. |
| 0x03 | LED count override | `FretLED.setLedCount` | Refresh via `device.queryLedConfig()`. |
| 0x04 | HSL color | `FretLED.setColor` | |
| 0x05 | Brightness | `FretLED.setBrightness` | |
| 0x06 | Effect mode | `FretLED.setMode` | |
| 0x07 | Direction | `FretLED.setDirection` | |
| 0x08 | Speed | `FretLED.setSpeed` | |
| 0x09 | Music mode | `FretLED.setMusicMode` | |
| 0x0A | Battery notify | `FretDevice.onBatteryChanged` | Firmware-pushed; re-request via `device.queryStatus()`. |
| 0x0B | RTC sync | `FretDevice.setRtcTime` | **Required before `setTimer`.** |
| 0x0C | Trigger status push | `FretDevice.queryStatus` | Triggers `send_type_request(8)/(9)` in firmware. |
| 0x0D | Scheduled power on/off | `FretLED.setTimer` | Depends on `setRtcTime`. |
| 0x0E | — | — | Reserved by firmware. |
| 0x0F | MIC source | `FretLED.setMicSource` | |
| 0x10 | Static color + energy inject | **Deprecated.** Use `FretLED.fillColor` (0x15) + `FretLED.injectEnergy` (0x26). | Replaced; see CHANGELOG. |
| 0x11 | Voice mode | `FretLED.setVoiceMode` | |
| 0x12 | Voice sensitivity | `FretLED.setVoiceSensitivity` | |
| 0x13 | Knob HSL | `FretAdvanced.sendRaw(device, FretCommand.knobHsl, [valH, valL])` | Physical-knob scenario; rarely used by apps. |
| 0x14 | Fill continuous range | `FretLED.fillRange` | ≤79 LEDs/call. Faster than 0x16 batched. |
| 0x15 | Fill all LEDs | `FretLED.fillColor` | |
| 0x16 | Batch data (sparse) | internal `LedBatchSender` (used by `lightNotes`) | |
| 0x17 | Immediate refresh | `FretLED.flushGroupImmediate` | Legacy. |
| 0x18 | Selection mask | `FretLED.lockSelection` / `unlockSelection` | |
| 0x19 | Group map | `FretLED.applyGroupMap` / `clearGroupMap` | |
| 0x1A | Group color | `FretLED.setGroupColor` / `applyGroupFrame` | |
| 0x1B | Music style | `FretLED.setMusicStyle` | Independent of 0x06/0x09. **Required for APP parity.** |
| 0x1C | Batch begin | internal `LedBatchSender` | |
| 0x1D | Batch end | internal `LedBatchSender` | |
| 0x1E | Query version | `FretDevice.queryVersion` | Auto-run on connect; re-query with this method. |
| 0x1F | Query LED config | `FretDevice.queryLedConfig` | Auto-run on connect; re-query with this method. |
| 0x20 | Metronome start | `FretMetronome.start` | |
| 0x21 | Metronome stop | `FretMetronome.stop` | |
| 0x22 | Learning LED | `FretLED.lightNote` / `lightNotes` / `clearLearningLEDs` | |
| 0x23 | Teacher mode | `FretClassroom.startTeacher` | |
| 0x24 | Student mode | `FretClassroom.startStudent` | |
| 0x25 | Classroom stop | `FretClassroom.stop` | |
| 0x26 | Energy inject | `FretLED.injectEnergy` | |
| 0x27 | LED index mode | `FretLED.setLedIndexMode` | |
| 0x28 | Query LED index mode | `FretDevice.queryLedIndexMode` via connect | (Currently only auto-run on connect; re-query via `FretAdvanced.sendRaw(device, FretCommand.queryLedIndexMode, [])`.) |
| 0x29 | Set DIY mode list | `FretLED.setDiyModeList` | |
| 0x2A | Query DIY mode list | `FretLED.queryDiyModeList` | |

**Coverage**: 29/30 commands have a high-level SDK API. The remaining
command (0x13 knob HSL) is exposed via `FretAdvanced.sendRaw` because
it is a physical-knob scenario rarely used by brand apps. The reserved
0x0E is not implemented by the firmware.

If you find a command missing here that you need, file an issue — the
SDK is designed so that all 30 firmware commands can be wrapped.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
