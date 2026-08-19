# FretSpark SDK Developer Integration Guide

This guide helps third-party developers quickly integrate the FretSpark SDK to enable BLE connection, LED control, firmware upgrade, and other features for smart guitar fretboard devices.

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Platform Configuration](#platform-configuration)
  - [Android](#android)
  - [iOS](#ios)
  - [Web (Chrome / Edge / Opera)](#web-chrome--edge--opera)
- [Quick Start](#quick-start)
- [Core API Overview](#core-api-overview)
- [Device Connection](#device-connection)
- [LED Control](#led-control)
- [Fretboard Learning](#fretboard-learning)
- [Classroom Mode](#classroom-mode)
- [Metronome](#metronome)
- [OTA Firmware Upgrade](#ota-firmware-upgrade)
- [Firmware Downloader](#firmware-downloader)
- [Brand Configuration](#brand-configuration)
- [Advanced Usage](#advanced-usage)
- [Error Handling](#error-handling)
- [FAQ](#faq)
- [Troubleshooting](#troubleshooting)

---

## Requirements

| Item | Minimum Version |
|---|---|
| Flutter | 3.24.0 |
| Dart SDK | 3.5.0 |
| Android minSdkVersion | 21 |
| iOS | 12.0 |

---

## Installation

Add the dependency in `pubspec.yaml`:

```yaml
dependencies:
  fretspark_sdk:
    git:
      url: https://github.com/FretSpark/fretspark_sdk.git
      ref: main  # Or specify a version tag, e.g. v1.4.0
```

Then run:

```bash
flutter pub get
```

---

## Platform Configuration

### Android

Add BLE permissions in `android/app/src/main/AndroidManifest.xml`:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <!-- BLE scan permission -->
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN"
        android:usesPermissionFlags="neverForLocation" />
    <!-- BLE connect permission -->
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
    <!-- Required to scan on Android 11 and below -->
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />

    <!-- BLE hardware declaration -->
    <uses-feature android:name="android.hardware.bluetooth_le" android:required="true" />

    <application>
        <!-- ... -->
    </application>
</manifest>
```

### iOS

Add the Bluetooth usage descriptions in `ios/Runner/Info.plist`:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Bluetooth permission is required to connect and control the guitar fretboard device</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>Bluetooth permission is required to connect and control the guitar fretboard device</string>
```

### Web (Chrome / Edge / Opera)

The SDK ships a built-in `WebBluetoothTransport` backed by the **Web
Bluetooth API**. No extra packages or file copying needed — the `web`
dependency is already included in the SDK's `pubspec.yaml`.

**Browser support:** Chrome (macOS/Windows/Linux/Android), Edge, Opera.
**Not supported:** Firefox, Safari (as of 2026).

#### 1. Inject the Web Bluetooth transport

```dart
import 'package:fretspark_sdk/fretspark_sdk.dart';

await FretSpark.instance.initialize(
  brandId: 'auphy',
  transport: WebBluetoothTransport(),
);
```

On non-Web platforms, `WebBluetoothTransport()` throws `UnsupportedError`
when constructed — use the default `FlutterBlueTransport` (automatic) on
mobile/desktop.

#### 2. Trigger the device picker (user gesture required)

Web Bluetooth does not support background scanning. The browser shows a
device-picker dialog when you call `startScan()`. This **must** be triggered
by a user gesture (e.g. a button tap):

```dart
ElevatedButton(
  onPressed: () async {
    await FretSpark.instance.connection.startScan();
  },
  child: const Text('Select Device'),
)
```

#### Web Bluetooth limitations

| Feature | Mobile (Android/iOS) | Web |
|---|---|---|
| Background scanning | Yes | No — user picks device |
| RSSI | Yes | No — always 0 |
| MTU negotiation | Yes (up to 247) | No — fixed at 23 |
| OTA firmware upgrade | Yes | Requires custom `FretOtaTransport` |
| User gesture required | No | Yes — for device selection |
| HTTPS required | No | Yes (or localhost) |

> **Note:** The SDK's packet codec already splits payloads into ≤20-byte
> frames, so the fixed MTU of 23 on Web does not cause issues for the
> runtime command service. OTA upgrade on Web requires implementing a
> custom `FretOtaTransport` (the default uses `flutter_blue_plus`).

#### Web Platform Limitations

The Web Bluetooth API imposes several constraints that differ from native (Android/iOS) BLE stacks. Brand apps targeting the Web platform must account for the following.

##### 1. Browser Support

Web Bluetooth is supported only by Chromium-based browsers:

| Browser | Supported | Minimum Version |
|---|---|---|
| Chrome (macOS / Windows / Linux / Android) | Yes | 56+ |
| Edge (Chromium) | Yes | 79+ |
| Opera | Yes | 43+ |
| Firefox | No | — |
| Safari (macOS / iOS) | No | — |

On unsupported browsers, `WebBluetoothTransport()` returns `false` from `requestPermissions()` and `isAdapterOn`, and `startScan()` throws `FretTransportException`. Brand apps should feature-detect via `FretSpark.instance.connection.isAdapterOn` (returns `false` when `navigator.bluetooth` is unavailable) and guide the user to a supported Chromium-based browser.

##### 2. HTTPS Requirement

The Web Bluetooth API is available only in **secure contexts**:

- Production: served over **HTTPS**.
- Development: `localhost` and `127.0.0.1` are treated as secure contexts for local development.

Calling `startScan()` from an insecure origin (e.g. plain `http://example.com`) causes the browser to reject the request with a `SecurityError`, surfaced by the SDK as a `FretTransportException`. Ensure your hosting provider terminates TLS before the page is served.

##### 3. User Gesture Requirement

`startScan()` (which internally calls `navigator.bluetooth.requestDevice()`) **must** be triggered by a user gesture — typically a button click, tap, or keyboard activation. Calling `startScan()` from a background timer, `initState`, `Future.delayed`, or any non-gesture code path causes the browser to reject the request with a `FretTransportException` ("Device selection cancelled or failed").

Recommended pattern:

```dart
ElevatedButton(
  onPressed: () async {
    await FretSpark.instance.connection.startScan();
  },
  child: const Text('Select Device'),
)
```

##### 4. No Background Scanning

Unlike native BLE, the browser does **not** continuously scan for devices. Calling `startScan()` opens a modal device-picker dialog (managed by the browser) and the user manually selects one device. There is no way to:

- Enumerate nearby devices programmatically.
- Observe BLE advertisements passively.
- Detect a device entering or leaving range.

The SDK emits the single user-selected device on `scanResults` with `rssi=0`. `stopScan()` is effectively a no-op on Web (the picker is modal and closes itself when the user picks or cancels).

##### 5. No RSSI

Web Bluetooth does not expose signal strength. All `FretScanResult` instances emitted on the Web platform report `rssi=0`. Brand apps must **not** use RSSI for proximity estimation, "device is close" gates, or triangulation on the Web platform. Use the device's own UI (e.g. ask the user to press its power button) for proximity feedback.

##### 6. No MTU Negotiation

Web Bluetooth uses a fixed ATT MTU of **23 bytes**. The SDK's packet codec already splits every command payload into ≤20-byte frames (the maximum payload for a 23-byte MTU minus the 3-byte ATT header), so runtime command functionality (LED control, metronome, classroom, etc.) is fully preserved.

The implication is throughput: with a 23-byte MTU, the maximum write-per-frame is 20 bytes versus 244 bytes on a negotiated 247-byte MTU. Brand apps doing high-frequency animation (e.g. 60 Hz `fillRange` calls) should expect lower effective throughput on Web. The `lightNotes` and `fillRange` methods automatically chunk their payloads to respect this limit.

##### 7. No OTA Firmware Upgrade

OTA firmware upgrade uses a separate Nordic-style GATT service (UUIDs `5833ff01-...` / `5833ff02-...` / `5833ff03-...` / `5833ff04-...`) and is driven by `FlutterBlueOtaTransport`, which wraps `flutter_blue_plus` directly. `flutter_blue_plus` does not implement Web Bluetooth, so **OTA upgrade is not available on the Web platform by default**.

To enable OTA on Web, a brand app must implement a custom `FretOtaTransport` that uses Web Bluetooth GATT operations (`writeValueWithResponse` / `startNotifications` on the OTA service characteristics), then construct `FretOTA(transport: myWebOtaTransport)` and pass it to `FretSpark.initialize`. The SDK does not ship such an implementation because the OTA protocol's 20-byte packet / 16-packet burst window was tuned for native BLE stacks.

##### 8. Single-Device Selection

The browser's device picker lets the user select **exactly one** device per `requestDevice()` call. Multi-device scanning (e.g. discovering a classroom of student devices, or scanning for both a runtime device and an OTA-mode device at the same time) is not possible on Web. Brand apps requiring multi-device workflows must use the native (Android/iOS) build.

##### 9. Connection Lifecycle

The browser owns the GATT connection:

- If the user closes the tab, navigates away, or the page is backgrounded long enough for the browser to suspend Web Bluetooth, the GATT connection is dropped and the device reverts to its disconnected state.
- `FretConnection.onCurrentDeviceStateChanged` emits `false` when this happens, subject to browser event delivery — some browsers coalesce or drop events on tab close.
- There is **no auto-reconnect** on Web; the user must invoke `startScan()` + `connect()` again from a fresh user gesture.

Brand apps should listen to `onCurrentDeviceStateChanged` and disable LED control UI when the device disconnects, prompting the user to re-select the device via a button click.

---

## Quick Start

Implement the full flow of "scan device -> connect -> light up chord" in 5 minutes:

```dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:fretspark_sdk/fretspark_sdk.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: HomePage());
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<FretScanResult> _results = [];
  FretDevice? _device;
  StreamSubscription<FretScanResult>? _scanSub;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    // Cancel the scan subscription to prevent memory leaks.
    _scanSub?.cancel();
    // Dispose the SDK singleton when the app shuts down.
    // FretSpark.instance.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    // 1. Initialize the SDK (pass in your brandId)
    try {
      await FretSpark.instance.initialize(brandId: 'auphy');

      // 2. Request Bluetooth permissions
      final ok = await FretSpark.instance.connection.requestPermissions();
      if (!ok) return;

      // 3. Listen for scan results — STORE the subscription for cleanup.
      _scanSub = FretSpark.instance.connection.scanResults.listen((r) {
        if (!_results.any((e) => e.id == r.id)) {
          setState(() => _results.add(r));
        }
      });

      // 4. Start scanning
      await FretSpark.instance.connection.startScan();
    } on FretSparkException catch (e) {
      debugPrint('SDK init failed: $e');
    }
  }

  Future<void> _connect(FretScanResult r) async {
    await FretSpark.instance.connection.stopScan();
    try {
      _device = await FretSpark.instance.connection.connect(r.id);
      setState(() {});
    } on FretSparkException catch (e) {
      debugPrint('Connect failed: $e');
      // Show error to user (e.g. via ScaffoldMessenger)
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_device != null) {
      return Scaffold(
        appBar: AppBar(title: Text(_device!.displayName)),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('Firmware version: ${_device!.firmwareVersion}'),
              Text('LED count: ${_device!.ledCount}'),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () async {
                  // Light up the C major chord
                  await FretSpark.instance.led.showChord(
                    _device!,
                    root: NoteName.c,
                    chordType: 'maj',
                    color: FretColor.green,
                  );
                },
                child: const Text('Show C major chord'),
              ),
              ElevatedButton(
                onPressed: () async {
                  // Clear all LEDs
                  await FretSpark.instance.led.clearAll(_device!);
                },
                child: const Text('Clear LEDs'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Scan devices')),
      body: ListView(
        children: _results
            .map((r) => ListTile(
                  leading: const Icon(Icons.bluetooth),
                  title: Text(r.name),
                  subtitle: Text('rssi: ${r.rssi}'),
                  onTap: () => _connect(r),
                ))
            .toList(),
      ),
    );
  }
}
```

---

## Core API Overview

The SDK exposes the following sub-APIs through the `FretSpark.instance` singleton:

| Getter | Type | Purpose |
|---|---|---|
| `.connection` | FretConnection | BLE scan, connect, handshake |
| `.led` | FretLED | LED color, effects, modes, learning lights |
| `.ota` | FretOTA | Firmware OTA upgrade |
| `.metronome` | FretMetronome | Metronome |
| `.classroom` | FretClassroom | Classroom mode (teacher/student) |
| `.firmware` | FretFirmwareDownloader | Firmware download, version check |
| `.brand` | FretBrand | Brand configuration management |
| `.transport` | FretTransport | Low-level BLE transport (advanced) |

It must be initialized before use:

```dart
await FretSpark.instance.initialize(
  brandId: 'auphy',       // Required: your brand ID
  manifestUrl: 'https://your-server.com/manifest.json',  // Optional: firmware manifest URL
  brandConfigUrl: 'https://your-server.com/brands.json',  // Optional: cloud brand config URL
);
```

> **Note:** Firmware OTA files are provided exclusively by FretSpark.
> Contact `auphy@auphymusic.com` to obtain the real OTA manifest and
> brand config URLs for your brand.

---

## Device Connection

### Scan

```dart
// Listen for scan results (automatically filtered by brand)
// Store the subscription so you can cancel it later.
final sub = FretSpark.instance.connection.scanResults.listen((result) {
  print('Found device: ${result.name} (${result.id})');
});

// Start scanning (default 10-second timeout)
await FretSpark.instance.connection.startScan();

// Stop manually
await FretSpark.instance.connection.stopScan();

// Cancel the subscription when done (e.g. in State.dispose())
// await sub.cancel();
```

### Connect

```dart
// Connect to a device (handshake is performed automatically: query firmware version, LED count, index mode, classroom ID)
final device = await FretSpark.instance.connection.connect(deviceId);

// After connecting, device info can be read directly
print('Firmware version: ${device.firmwareVersion}');    // e.g. "3.1.3.4"
print('LED count: ${device.ledCount}');          // e.g. 126
print('Max fret: ${device.maxFret}');           // e.g. 20
print('Classroom ID: ${device.classroomId}');        // e.g. 0
print('Battery: ${device.batteryLevel}%');         // e.g. 85
```

### Listen to Device State

```dart
// Listen for disconnection
FretSpark.instance.connection.onCurrentDeviceStateChanged.listen((connected) {
  if (!connected) print('Device disconnected');
});

// Listen for battery changes
device.onBatteryChanged.listen((battery) {
  print('Battery: ${battery.level}%, voltage: ${battery.voltageMv}mV');
});

// Listen for firmware version queries
device.onFirmwareVersionQueried.listen((version) {
  print('Firmware version: ${version.formatted}');
});
```

### Disconnect

```dart
await FretSpark.instance.connection.disconnect();
```

---

## LED Control

### Power and Brightness

```dart
// Power
await FretSpark.instance.led.setPower(device, on: true);

// Brightness (0-1000)
await FretSpark.instance.led.setBrightness(device, 500);
```

### Color

```dart
// Fill the entire fretboard with RGB
await FretSpark.instance.led.fillColor(device, FretColor(255, 0, 0));  // Red

// Set base color with HSL
await FretSpark.instance.led.setColor(device, FretHsl(hue: 120, saturation: 800));

// Built-in presets
await FretSpark.instance.led.fillColor(device, FretColor.red);
await FretSpark.instance.led.fillColor(device, FretColor.blue);
```

### Effect Mode

```dart
// Switch built-in effect (1-117)
await FretSpark.instance.led.setMode(device, 5);

// Speed (0-255)
await FretSpark.instance.led.setSpeed(device, 128);

// Direction (0=forward, 1=reverse)
await FretSpark.instance.led.setDirection(device, 0);
```

### Hardware Layout

```dart
// Set linear layout (WS2812 light strip)
await FretSpark.instance.led.setLinearLayout(device, linear: true);

// Override LED count (e.g. 21 frets = 126 LEDs)
await FretSpark.instance.led.setLedCount(device, 126);
```

### Range Fill

```dart
// Fill 5 different colors starting from LED index 0
await FretSpark.instance.led.fillRange(
  device,
  startIndex: 0,
  colors: [
    FretColor.red, FretColor.green, FretColor.blue,
    FretColor.yellow, FretColor.cyan,
  ],
);
// Max 79 LEDs per packet; multiple calls are split automatically
```

### Music Style and Timer

```dart
// Set music style (0-99)
await FretSpark.instance.led.setMusicStyle(device, 5);

// Scheduled power on/off (RTC must be synced first)
await device.setRtcTime(DateTime.now());
await FretSpark.instance.led.setTimer(
  device,
  on: true,
  hour: 8,
  minute: 0,
  second: 0,
);
```

### Group Control

```dart
// Assign colors by group (single-frame render)
await FretSpark.instance.led.applyGroupFrame(
  device,
  groupAssignments: {0: 1, 1: 1, 2: 1, 3: 2, 4: 2, 5: 2},  // LED index -> group ID
  groupColors: {
    1: FretColor.red,    // Group 1 = red
    2: FretColor.blue,   // Group 2 = blue
  },
);

// Clear group control
await FretSpark.instance.led.clearGroupMap(device);
```

### Left-handed Mode

```dart
// Enable left-handed mode (automatically mirrors string index 0<->5)
await FretSpark.instance.led.setLeftHandedMode(true);
// Persisted to SharedPreferences, shared across devices
```

---

## Fretboard Learning

### Light Up a Single Note

```dart
// String 1 (high E), fret 5, red
await FretSpark.instance.led.lightNote(
  device,
  FretNote(string: 0, fret: 5, color: FretColor.red),
);
```

### Batch Light Up

```dart
// Light up multiple notes simultaneously (auto-deduplicates, last write wins)
await FretSpark.instance.led.lightNotes(
  device,
  [
    FretNote(string: 0, fret: 0, color: FretColor.red),    // High E open string
    FretNote(string: 1, fret: 2, color: FretColor.green),  // B string, fret 2
    FretNote(string: 2, fret: 3, color: FretColor.blue),   // G string, fret 3
  ],
);
```

### Chord

```dart
// Show the C major chord
await FretSpark.instance.led.showChord(
  device,
  root: NoteName.c,
  chordType: 'maj',
  color: FretColor.green,
);

// Supported chord types: maj, min, 7, maj7, min7, dim, aug, sus2, sus4, ...
```

### Scale

```dart
// Show the C major scale
await FretSpark.instance.led.showScale(
  device,
  root: NoteName.c,
  scale: ScaleType.major,
  color: FretColor.cyan,
);

// Supported scales: major, minor, pentatonic, blues, dorian, mixolydian, ...
```

### Clear Learning LEDs

```dart
await FretSpark.instance.led.clearLearningLEDs(device);
```

---

## Classroom Mode

Classroom mode allows multiple devices to synchronize LED state, suitable for teaching scenarios.

```dart
// Teacher side: start broadcasting
await FretSpark.instance.classroom.startTeacher(device);

// Student side: start listening
await FretSpark.instance.classroom.startStudent(device);

// Stop
await FretSpark.instance.classroom.stop(device);
```

---

## Metronome

```dart
// Start the metronome (BPM 40-240, time signature optional)
await FretSpark.instance.metronome.start(
  device,
  bpm: 120,
  timeSignature: FretTimeSignature.fourFour,  // Default 4/4
);

// Switch time signature
await FretSpark.instance.metronome.start(
  device,
  bpm: 100,
  timeSignature: FretTimeSignature.sixEight,  // 6/8 time
);

// Stop
await FretSpark.instance.metronome.stop(device);
```

Supported time signatures:

| Enum | Beats | Meaning |
|---|---|---|
| `FretTimeSignature.twoFour` | 2 | 2/4 time |
| `FretTimeSignature.threeFour` | 3 | 3/4 time |
| `FretTimeSignature.fourFour` | 4 | 4/4 time (default) |
| `FretTimeSignature.sixEight` | 6 | 6/8 time |

---

## OTA Firmware Upgrade

OTA upgrade has three steps: enter OTA mode -> scan for OTA device -> transfer firmware.

```dart
final ota = FretSpark.instance.ota;

// 1. Notify the connected device to enter OTA mode (the device will reboot and change its Bluetooth name)
await ota.enterOtaMode(device);

// 2. Scan for OTA-mode devices (matched by OTA name prefix)
final otaDevice = await ota.scanOtaDevice('AUPHY-OTA');
if (otaDevice == null) {
  print('No OTA device found');
  return;
}

// 3. Listen for upgrade progress
final sub = ota.onProgress.listen((p) {
  print('${p.phase.name}: ${p.sent}/${p.total} bytes');
});

// 4. Transfer firmware
try {
  await ota.upgrade(otaDevice.id, firmwareBytes);
  print('Upgrade succeeded');
} on FretOtaException catch (e) {
  print('Upgrade failed: $e');
} finally {
  await sub.cancel();
}
```

Progress phases:

| Phase | Meaning |
|---|---|
| `connecting` | Connecting to OTA device |
| `starting` | Sending START_OTA command |
| `transferring` | Transferring firmware data |
| `rebooting` | Device is rebooting |
| `success` | Upgrade succeeded |

### Custom BLE Stack

If you don't use `flutter_blue_plus`, you can implement your own `FretOtaTransport`:

```dart
class MyOtaTransport implements FretOtaTransport {
  // Implement connect / discoverOtaService / writeCmd / writeData
  // / rspNotifyStream / disconnect
}

final ota = FretOTA(transport: MyOtaTransport());
```

---

## Firmware Downloader

```dart
final fw = FretSpark.instance.firmware;

// Check for updates
final info = await fw.checkForUpdate(
  manifestUrl: 'https://your-server.com/manifest.json',
  brandId: 'auphy',
);
if (info != null) {
  print('New version: ${info.version} (${info.size} bytes)');
}

// Download firmware
final localPath = await fw.checkAndDownload(
  manifestUrl: 'https://your-server.com/manifest.json',
  brandId: 'auphy',
  currentVersion: '3.1.3.4',
);
if (localPath != null) {
  // Read the firmware file using localPath, then call ota.upgrade()
  final bytes = await File(localPath).readAsBytes();
  await FretSpark.instance.ota.upgrade(deviceId, bytes);
}

// Query locally cached firmware
final cachedPath = await fw.getLocalFirmwarePath(brandId: 'auphy');
final cachedVersion = await fw.getLocalFirmwareVersion(brandId: 'auphy');

// Delete local cache
await fw.deleteLocalFirmware();
```

### Version Comparison

```dart
// Static method, can be used directly
final cmp = FretFirmwareDownloader.compareVersions('3.1.3.4', '3.1.3.5');
// cmp < 0: current version is older
// cmp == 0: identical
// cmp > 0: current version is newer
```

---

## Brand Configuration

The SDK ships with fallback configurations for 6 brands. If you need to sync the brand list from the cloud:

```dart
final brand = FretSpark.instance.brand;

// Sync brand configuration from the cloud (JSON format)
await brand.syncFromCloud(jsonString);

// Or sync from a URL
await FretSpark.instance.initialize(
  brandId: 'auphy',
  brandConfigUrl: 'https://your-server.com/brands.json',
);

// Match a brand by device name
final matched = brand.matchByFirmwareName('AUPHY-1234');
if (matched != null) {
  print('Matched brand: ${matched.displayName}');
}

// Set the active brand
await brand.setActive('auphy');

// Restore from cache
await brand.loadActiveFromCache();
```

---

## Advanced Usage

### Send Raw Command

When a higher-level SDK API doesn't wrap a specific firmware command, use the `FretAdvanced` escape hatch:

```dart
// Wait for the queue to complete (recommended)
await FretAdvanced.sendRaw(
  device,
  FretCommand.musicStyle,
  <int>[42],
);

// Fire-and-forget (for high-frequency animation frames)
FretAdvanced.sendRawFireAndForget(
  device,
  FretCommand.energyInject,
  <int>[0x01, 0x00],
);
```

> **Warning**: `sendRaw` bypasses SDK state machine optimizations. Before using it, confirm that the higher-level SDK API truly has no equivalent method. See the [FretCommand] command code comments for details.

### Listen for Unknown Notifications

```dart
// Capture firmware notifications the SDK doesn't recognize
device.setUnknownNotifyHandler((notify) {
  print('Unknown notify: cmd=0x${notify.cmd.toRadixString(16)} data=${notify.data}');
});
```

### Query Device State

```dart
// Re-query firmware version
await device.queryVersion();

// Re-query LED configuration
await device.queryLedConfig();

// Trigger firmware to push state (battery, etc.)
await device.queryStatus();
// Then listen to onBatteryChanged to get the result

// Set classroom ID
await device.setClassroomId(1234);

// Sync RTC time
await device.setRtcTime(DateTime.now());
```

---

## Error Handling

### Common Exception Types

| Exception | Meaning | Suggested Handling |
|---|---|---|
| `FretTransportException` | BLE connection/scan failed | Check Bluetooth switch, permissions, device distance |
| `FretOtaException` | OTA upgrade failed | Check firmware file, device battery, retry |
| `ArgumentError` | Parameter validation failed | Check parameter range |
| `StateError` | Device disconnected or not initialized | Reconnect/initialize |

### Error Handling Example

```dart
try {
  final device = await FretSpark.instance.connection.connect(deviceId);
  await FretSpark.instance.led.setBrightness(device, 500);
} on FretTransportException catch (e) {
  // BLE layer error
  print('Connection failed: $e');
} on StateError catch (e) {
  // Device disconnected
  print('Device state error: $e');
} catch (e) {
  // Other errors
  print('Unknown error: $e');
}
```

### Connection State Listening

```dart
FretSpark.instance.connection.onCurrentDeviceStateChanged.listen((connected) {
  if (!connected) {
    // Device disconnected unexpectedly; trigger reconnect logic here
    print('Device disconnected, attempting to reconnect...');
  }
});
```

---

## FAQ

### Q: Which brands are supported?

A: The SDK ships with 6 built-in brands: FretSpark, AUPHY, Smiger, NATASHA, Bullfighter, Deviser. Custom brands can be added via cloud configuration.

### Q: No devices found during scanning?

A: Check in order:
1. Whether the phone's Bluetooth is turned on
2. Whether the app has been granted Bluetooth permissions
3. Whether the device is powered on and within broadcast range
4. Android 12+ requires runtime requests for `BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT` permissions

### Q: Device info is empty after connecting?

A: The connection handshake has a 3-second timeout. If the firmware version/LED count appears empty/default, the firmware response may have timed out. You can manually call `device.queryVersion()` to re-query.

### Q: No response after sending an LED command?

A: Check whether the device is connected (`device.isConnected`) and whether it is in group control mode (if so, call `led.clearGroupMap(device)` first to exit group control).

### Q: What to do if the OTA upgrade fails?

A: Check:
1. Whether the firmware file is empty (`fileBytes.isEmpty`)
2. Whether the device battery is sufficient (recommended >20%)
3. Whether the OTA device name prefix is correct (e.g. `AUPHY-OTA`)
4. Confirm that the firmware file brand matches the device brand

### Q: How to switch brands in a multi-brand app?

```dart
await FretSpark.instance.brand.setActive('smiger');
// The SDK will automatically filter scan results by the new brand
```

### Q: Can multiple devices be connected at the same time?

A: `FretSpark.instance` is a singleton and only manages one device at a time. For multiple devices, you need to manage multiple `FretConnection` instances yourself (you must initialize the transport yourself).

### Q: How to add a custom brand?

A: Two ways:
1. Via cloud configuration (recommended): provide a brand JSON URL and call `syncFromCloud`
2. Add the brand in `assets/brands_fallback.json` (requires forking the SDK repository)

Brand JSON format:
```json
{
  "version": 1,
  "list": [
    {
      "id": "mybrand",
      "display_name": "My Brand",
      "device_model": "MB-1",
      "firmware_patterns": [".*MYBRAND.*"],
      "ota_name_prefix": "MYBRAND-OTA",
      "email": "support@mybrand.com",
      "enabled": true
    }
  ]
}
```

### Q: How to view the full command code list?

A: See the firmware command coverage table in [README.md](README.md), or view the SDK source at `lib/src/core/commands.dart`.

---

## Troubleshooting

Common problems and solutions when using the FretSpark SDK. Most issues fall into one of three categories: Bluetooth/permissions, command-validation, or platform-specific (Web).

### 1. Cannot Find Device During Scan

**Symptom:** The `scanResults` stream emits nothing, or the scan completes after the timeout with no devices discovered.

**Checks:**

- The device's Bluetooth adapter is turned on. Verify with `await FretSpark.instance.connection.isAdapterOn` — it should return `true`.
- On Android 12+, `requestPermissions()` returned `true` (Bluetooth Scan + Connect + Location runtime permissions granted). Use `requestPermissionsDetailed()` to distinguish user-denied, permanently-denied, adapter-off, and not-supported.
- The target device is in range and powered on. The LED panel may show no indication when disconnected — check the device's battery level by pressing its physical power button.
- The active brand's `firmwarePatterns` match the device's advertised BLE name. Use `BrandConfig.matchByFirmwareName(deviceName)` to verify. If the brand app filters too aggressively, no devices appear.
- Subscribe to `FretSpark.instance.connection.onAdapterStateChanged` and confirm the stream emits `true`. On Android 11 and below, also verify that Location Services is enabled (required for BLE scan).
- On Web, see [Web Platform Limitations](#web-platform-limitations) — the browser shows a device picker rather than scanning passively.

### 2. Connection Fails Immediately

**Symptom:** `connect(deviceId)` throws `FretTransportException` within a few seconds.

**Checks:**

- The device is not already connected to another app. The firmware allows only one BLE GATT connection at a time. Close any other brand app or BLE tool (e.g. nRF Connect, LightBlue) that may be holding the connection.
- The BLE adapter is on (`isAdapterOn` returns `true`).
- The device is in range and powered on.
- On iOS, verify the device is not connected in iOS Settings → Bluetooth (no checkmark next to it). iOS will not let an app connect to a device the OS itself is bonded to.
- Retry `connect()` after a brief delay — transient BLE stack issues can cause the first attempt to fail.

### 3. LED Commands Don't Work

**Symptom:** `fillColor`, `lightNote`, `setMode`, etc. complete without throwing but the LED panel shows no visible change.

**Checks:**

- The device is still connected: `device.isConnected` returns `true`. Subscribe to `onCurrentDeviceStateChanged` to detect silent disconnects.
- The firmware version was queried during the connect handshake (`device.firmwareVersion` is non-empty). An empty version string suggests the handshake query timed out — call `device.queryVersion()` and subscribe to `onFirmwareVersionQueried` to re-query.
- `device.ledCount` matches the physical hardware. If the firmware reported a wrong LED count (e.g. default 90 instead of 126 for a 21-fret board), `lightNote`/`lightNotes` will write to the wrong indices. Call `device.queryLedConfig()` to refresh and subscribe to `onLedCountChanged`.
- The device is not in OTA mode. If the device's advertised name ends with `OTA`, it is in OTA mode and ignores runtime LED commands. Use `FretOTA.scanOtaDevice(prefix)` and `FretOTA.upgrade(...)` instead, or reboot the device to exit OTA mode.
- The selection mask is not locked. If `lockSelection(indices)` was called previously, only those LEDs respond to effect/color commands. Call `unlockSelection(device)` to clear the mask.

### 4. setTimer Throws Validation Error

**Symptom:** `FretSparkException.validationError('RTC time not synchronized. Call setRtcTime() before setTimer().')`

**Cause:** The firmware's real-time clock has not been synced, so the scheduled timer would fire at an unpredictable time. The SDK blocks `setTimer` until `setRtcTime` has been called on the same `FretDevice` instance.

**Fix:** Call `await device.setRtcTime(DateTime.now());` before `setTimer`. The `isRtcSynced` flag is per-device-instance; if you reconnect or re-create the `FretDevice` (e.g. after a disconnect), you must call `setRtcTime` again.

```dart
await device.setRtcTime(DateTime.now());
await led.setTimer(device, on: false, hour: 23, minute: 30, second: 0);
```

### 5. OTA Upgrade Fails

**Symptom:** `FretOTA.upgrade` throws `FretOtaException`, or `onProgress` reports no further bytes after a burst.

**Checks:**

- The device is in OTA mode. After `enterOtaMode(device)`, the device reboots and advertises with the brand's OTA name prefix (e.g. `SCT-86PRO OTA`). `scanOtaDevice(prefix)` must find it. If the prefix does not match the device's advertised name, the scan returns `null`.
- The firmware bytes are for the **correct brand**. Firmware files are brand-specific; flashing an AUPHY firmware on a Smiger device will soft-brick it. Use `FretFirmwareDownloader.readLocalFirmwareBytes(brandId: ...)` with the correct `brandId`, and verify the brand entry in the manifest matches your device.
- Battery level is sufficient. The firmware may reject OTA below ~20% battery. Subscribe to `device.onBatteryChanged` and require a minimum level before starting.
- The OTA device is in range and not connected to another app's OTA transport.
- If `errBadData` (code 104) is reported repeatedly on the same burst, the firmware image may be corrupted or truncated. Re-download via `FretFirmwareDownloader.download(...)` and verify the file size matches the manifest.

### 6. Web: startScan() Does Nothing

**Symptom:** On the Web platform, `startScan()` completes without throwing but no device picker appears, or it throws `FretTransportException: Device selection cancelled or failed`.

**Checks:**

- `startScan()` is called from a user gesture handler (e.g. `ElevatedButton.onPressed`). Calling from `initState`, `Future.delayed`, or a stream callback is rejected by the browser.
- The page is served over HTTPS (or `localhost` for development). Insecure origins cannot access Web Bluetooth.
- The browser is Chromium-based (Chrome 56+, Edge 79+, Opera 43+). Firefox and Safari do not support Web Bluetooth.
- The user did not cancel the picker dialog. If they cancelled, retry from a fresh user gesture.

### 7. Web: Cannot Perform OTA

**Symptom:** `FretOTA.upgrade` is unavailable or throws on the Web platform.

**Cause:** OTA upgrade uses `FlutterBlueOtaTransport`, which wraps `flutter_blue_plus`. `flutter_blue_plus` does not implement Web Bluetooth, so the default OTA transport cannot run on Web.

**Fix:** Implement a custom `FretOtaTransport` that drives the OTA GATT service (`5833ff01-...`) via Web Bluetooth's `writeValueWithResponse` / `startNotifications`, then construct `FretOTA(transport: myWebOtaTransport)` and pass it to `FretSpark.initialize`. The SDK does not ship a Web OTA transport; brand apps must build one if Web OTA is required.

### 8. Permission Permanently Denied (Android)

**Symptom:** `requestPermissions()` returns `false` repeatedly, even after the user tapped the system permission dialog.

**Cause:** On Android 11+, the user selected "Don't ask again" or denied the permission twice in a row, which marks the Bluetooth permission as permanently denied at the OS level. The system permission dialog will no longer be shown.

**Fix:** Use `FretSpark.instance.connection.requestPermissionsDetailed()` to detect the permanently-denied state, then open the system Settings page for your app so the user can manually grant the permission:

```dart
final result = await FretSpark.instance.connection.requestPermissionsDetailed();
if (result.reason == FretPermissionDeniedReason.permanentlyDenied) {
  // Route the user to system Settings for this app.
  // Use the `permission_handler` package's openAppSettings() or
  // platform-specific code to launch the OS Settings screen.
}
```

`FretPermissionDeniedReason` distinguishes `userDenied` (can re-prompt), `permanentlyDenied` (must go to Settings), `adapterOff` (Bluetooth is off), and `notSupported` (platform has no Bluetooth).

### 9. Bluetooth Adapter Turned Off During Use

**Symptom:** LED commands stop working mid-session; `onCurrentDeviceStateChanged` emits `false` even though the device is still powered on.

**Cause:** The user (or the OS) turned off Bluetooth while the device was connected, dropping the GATT connection. This can also happen when the device enters a power-save mode or the OS suspends BLE to save battery.

**Fix:** Subscribe to `FretSpark.instance.connection.onAdapterStateChanged` and pause all LED/OTA operations while the adapter is off. Resume when it returns to `true`:

```dart
FretSpark.instance.connection.onAdapterStateChanged.listen((on) {
  if (!on) {
    _pauseOperations();
  } else {
    _resumeOperations();
  }
});
```

Reconnect explicitly via `FretSpark.instance.connection.connect(deviceId)` once the adapter is back on; the SDK does not auto-reconnect.

### 10. Memory Leaks / Stale Subscriptions

**Symptom:** App memory grows over time, or callbacks fire with stale device references after navigation.

**Cause:** `StreamSubscription`s from `scanResults`, `onBatteryChanged`, `onCurrentDeviceStateChanged`, `onProgress`, etc. were not cancelled in `dispose()`.

**Fix:**

- Cancel every `StreamSubscription` in your widget's `dispose()` method.
- Call `FretSpark.instance.dispose()` when the app is shutting down (or in integration tests) to close the singleton's streams and free the transport.
- For one-off operations (e.g. OTA), use a `finally` block to cancel the progress subscription and dispose the `FretOTA` controller.

```dart
StreamSubscription<FretBattery>? _batterySub;

@override
void dispose() {
  _batterySub?.cancel();
  // FretSpark.instance.dispose();  // only on app exit
  super.dispose();
}
```

---

## More Resources

- [README.md](README.md) - Full SDK API reference and command coverage table
- [CHANGELOG.md](CHANGELOG.md) - Version change log
- [example/](example/) - Complete example Flutter app
- [GitHub Issues](https://github.com/FretSpark/fretspark_sdk/issues) - Issue feedback and suggestions
