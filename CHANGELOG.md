## 1.4.0

Filled the remaining firmware command coverage gaps so that brand apps
can achieve **full feature parity with the official app**. The SDK now
exposes high-level APIs for every firmware command implemented by the
SCT-86Pro firmware (`0x01`–`0x2A`).

### Added — FretLED
- `setMusicStyle(device, styleId)` → `0x1B`. Triggers the firmware's
  independent music-style render pipeline (separate from `0x06` mode
  and `0x09` musicMode). **Required for APP parity** — without this,
  brand apps cannot reach the official app's music-style features.
- `setTimer(device, {on, hour, minute, second, slot})` → `0x0D`.
  Scheduled power on/off. Depends on `setRtcTime`.
- `setLedCount(device, count)` → `0x03`. Override the firmware's
  default LED count to match the actual strip length.
- `setLinearLayout(device, {linear})` → `0x02`. Switch between matrix
  and linear RGB layouts (for WS2812/SK6812 strips).
- `fillRange(device, {startIndex, colors})` → `0x14`. Fill a
  contiguous LED range in a single packet (≤79 LEDs/call). ~4–5×
  faster than the batched sparse path (`0x16`) for contiguous segments.

### Added — FretDevice (RTC & runtime queries)
- `setRtcTime(DateTime)` → `0x0B`. Sync the device RTC. **Required
  before `setTimer`** — the firmware uses its RTC as the reference
  clock for scheduled power on/off.
- `queryVersion()` → `0x1E`. Re-query firmware version at runtime
  (the SDK already queries once on `connect`; this method allows
  re-querying after a manual upgrade).
- `queryLedConfig()` → `0x1F`. Re-query LED count. Use after
  `setLedCount` or hardware hot-swap.
- `queryStatus()` → `0x0C`. Trigger the firmware to push its current
  status (battery, etc.) via notify. The firmware has no dedicated
  "query battery" command — this method sends `0x0C [0x01]`, which
  makes the firmware call `send_type_request(8)/(9)` internally.
  Subscribe to `onBatteryChanged` for the result.

### Added — FretAdvanced (escape hatch)
- New class `FretAdvanced` with `sendRaw(device, cmd, params)` and
  `sendRawFireAndForget(device, cmd, params)`. Provides a documented
  escape hatch for brand apps that need a firmware command the SDK
  does not wrap yet. Previously, developers had to reach for the
  `@visibleForTesting` `FretDevice.send` — that path is now
  documented and supported.
- Wraps `0x13` knob HSL (physical-knob scenario; rarely used by
  apps) via `FretAdvanced.sendRaw(device, FretCommand.knobHsl, [...])`.

### Deprecated
- `FretCommand.staticColor` (`0x10`). The firmware uses this single
  command for two conflicting purposes (set static color + inject
  APP-mic energy), and calling it forces `device_rgb_state` to mode 4,
  which disables the firmware's AI rhythm rendering. **Use
  `FretLED.fillColor` (`0x15`) + `FretLED.injectEnergy` (`0x26`)
  instead.** The constant is retained for advanced users who need to
  reproduce legacy behavior via `FretAdvanced.sendRaw`, but no
  high-level API wraps it.

### Documentation
- README now includes a full **firmware command coverage table**
  showing which of the 30 firmware commands (`0x01`–`0x2A`) are
  wrapped by which SDK API, which are exposed via `FretAdvanced`, and
  which are intentionally not exposed.
- The 1.1.0 changelog entry claimed "Complete firmware protocol
  coverage. All 30 commands (0x01 ~ 0x2A) now have public SDK APIs."
  This was inaccurate — `0x02`, `0x03`, `0x0B`, `0x0D`, `0x14`,
  `0x1B`, and `0x1C`/`0x1D` (used internally) were not exposed as
  high-level APIs. This release closes that gap.

## 1.3.0

Added cloud-based brand config sync and auto-detection.

### Added
- **FretBrand.syncFromCloudUrl(url, {timeout})**: fetches `partner.json`
  from your OTA server with caching + version checking (mirrors the OTA
  firmware downloader). Three-layer load: bundled fallback → local
  cache → cloud.
- **FretBrand.autoDetectFromDeviceName(deviceName)**: auto-detect the
  brand from a connected device's BLE advertised name. Switches and
  persists the active brand if it differs from the current one.
- **FretBrand.loadActiveFromCache()**: restores the previously-saved
  active brand from SharedPreferences on app restart.
- **FretConnection.onBrandAutoDetected** stream + `setBrandMatcher`
  callback: auto-detects brand on `connect()` and emits the matched
  `BrandConfig`. Wired automatically by `FretSpark.initialize`.
- **FretSpark.initialize** now accepts an optional `brandConfigUrl`
  parameter. When set, the SDK fetches + caches the brand config on
  init, and auto-detects the brand from the device name on every
  `connect()`.
- Brand config JSON format: `{"version": N, "list": [BrandConfig, ...]}`

## 1.2.0

Added an optional HTTP layer for OTA firmware distribution.

### Added
- **FretOTA.enterOtaMode(device, {rebootDelay})**: new method that
  sends the `0x01 [0x02, 0x01]` command to reboot a connected runtime
  device into OTA mode. Replaces the previous pattern of brand apps
  having to send raw protocol bytes via `device.send(0x01, [0x02, 0x01])`.
- **FretFirmwareDownloader** (new class): fetches `manifest.json` from
  an OTA server, resolves the firmware entry for the active brand,
  compares versions, downloads the file with progress reporting, and
  caches it under `getApplicationSupportDirectory()/fretspark_ota_firmware/`.
  - `checkForUpdate({manifestUrl, brandId, force})` → `FretFirmwareInfo?`
  - `download({manifestUrl, brandId, onProgress})` → local file path
  - `checkAndDownload({manifestUrl, brandId, currentVersion, onProgress, force})`
    one-shot "check + download if newer"
  - `getLocalFirmwarePath` / `getLocalFirmwareVersion` /
    `readLocalFirmwareBytes` / `deleteLocalFirmware` for cache management
  - `compareVersions(a, b)` static helper (4-segment semver)
  - `onStatusChanged` stream + `FretFirmwareStatus` enum
- **FretSpark.initialize** now accepts an optional `manifestUrl`
  parameter; when set, brand apps can call `FretSpark.instance.firmware.*`
  without re-passing the URL each time.
- New public type: `FretFirmwareInfo`, `FretFirmwareStatus`.
- New dependencies: `http ^1.2.0`, `path_provider ^2.1.0`, `path ^1.9.0`.

### Manifest format
```json
{
  "version": "3.1.3.4",
  "brands": [
    {"id": "auphy", "version": "3.1.3.4",
     "file": "firmware.auphy.3.1.3.4.hex16", "size": 245760,
     "otaNamePrefix": "AUPHY-OTA"}
  ]
}
```
Legacy single-file manifests (top-level `file`/`size`/`version` without
a `brands` array) are still accepted for backwards compatibility.

## 1.1.0

Complete firmware protocol coverage. All 30 commands (0x01 ~ 0x2A) now
have public SDK APIs.

### Added
- **FretLED — Voice / mic mode**:
  - `setMusicMode(device, MusicMode, {extraParams})` → `0x09`
  - `setMicSource(device, MicSource)` → `0x0F`
  - `setVoiceMode(device, {on})` → `0x11` (hides firmware's inverted 0x00=on)
  - `setVoiceSensitivity(device, value)` → `0x12`
  - `injectEnergy(device, volume)` → `0x26` (16-bit, for APP-mic reactive LEDs)
- **FretLED — Group-color channel**:
  - `applyGroupFrame(device, {groupAssignments, groupColors})` — composite
    batched helper (`0x1C`→`0x19`→`0x1A`×N→`0x1D`)
  - `setGroupColor` / `applyGroupMap` / `clearGroupMap` / `flushGroupImmediate`
    low-level escape hatches
- **FretLED — DIY mode list**: `setDiyModeList` (`0x29`) / `queryDiyModeList` (`0x2A`)
- **FretLED — Hardware config**: `setLedIndexMode` (`0x27`)
- **FretClassroom** (new class): teacher/student/stop for Nordic-PPP
  local-teaching mode (`0x23` / `0x24` / `0x25`).
- New enums: `MicSource`, `MusicMode`.

## 1.0.0

Initial public release of FretSpark SDK.

### Core Modules
- **FretConnection**: BLE scan / connect / disconnect with automatic brand filtering.
  Auto-negotiates MTU, discovers FFF0/FFF3/FFF4/FFF6 services, queries firmware
  version (0x1E), LED config (0x1F), and LED index mode (0x28) on connect.
- **FretLED**: High-level fretboard lighting API.
  - `setPower` / `setBrightness` / `fillColor` / `clearAll`
  - `setMode` (117 built-in modes) / `setSpeed` / `setDirection`
  - `lightNote` / `lightNotes` (guitar-semantic: string + fret + color)
  - `showChord` (built-in chord dictionary, 60+ chords)
  - `showScale` (built-in scale dictionary, 10+ scale types)
  - `lockSelection` / `unlockSelection`
  - Automatic left-handed mirror, multi-packet batching, coalescing
- **FretOTA**: Firmware upgrade with 16-packet group retransmission.
  Auto-scans OTA devices by brand prefix, handles partition info, retries.
- **FretBrand**: Brand configuration management.
  Cloud `partner.json` sync with local `brands_fallback.json` fallback.
  Firmware name regex matching for automatic brand activation.
- **FretMetronome**: Hardware metronome control (0x20/0x21).
  BPM + time signature, syncs with on-device LED.

### Supported Brands (out of the box)
FretSpark, AUPHY, Smiger, NATASHA, Bullfighter, Deviser.

### Supported Firmware Protocols
Commands 0x01 ~ 0x2A (see README for full table).

### Platform Support
- Android 5.0+ (API 21+)
- iOS 11.0+
- Web (via flutter_blue_plus web shim, experimental)

### BLE Constraints Handled Internally
- MTU 247, max 244 bytes per `writeWithoutResponse`
- Max 59 LEDs per packet (auto-splits via 0x1C+0x16+0x1D)
- No Queued Write (avoids firmware stack corruption)
- Coalescing for high-frequency commands (0x04/0x05/0x08/0x12/0x22)
- Batch transfer lock (prevents 0x1C/0x16/0x1D interleaving)
