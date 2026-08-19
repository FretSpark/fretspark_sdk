# FretSpark SDK Developer Integration Guide

This guide helps third-party developers quickly integrate the FretSpark SDK to enable BLE connection, LED control, firmware upgrade, and other features for smart guitar fretboard devices.

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Platform Configuration](#platform-configuration)
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

---

## Quick Start

Implement the full flow of "scan device -> connect -> light up chord" in 5 minutes:

```dart
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

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // 1. Initialize the SDK (pass in your brandId)
    await FretSpark.instance.initialize(brandId: 'auphy');

    // 2. Request Bluetooth permissions
    await FretSpark.instance.connection.requestPermissions();

    // 3. Listen for scan results
    FretSpark.instance.connection.scanResults.listen((r) {
      if (!_results.any((e) => e.id == r.id)) {
        setState(() => _results.add(r));
      }
    });

    // 4. Start scanning
    await FretSpark.instance.connection.startScan();
  }

  Future<void> _connect(FretScanResult r) async {
    await FretSpark.instance.connection.stopScan();
    _device = await FretSpark.instance.connection.connect(r.id);
    setState(() {});
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

---

## Device Connection

### Scan

```dart
// Listen for scan results (automatically filtered by brand)
FretSpark.instance.connection.scanResults.listen((result) {
  print('Found device: ${result.name} (${result.id})');
});

// Start scanning (default 10-second timeout)
await FretSpark.instance.connection.startScan();

// Stop manually
await FretSpark.instance.connection.stopScan();
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

## More Resources

- [README.md](README.md) - Full SDK API reference and command coverage table
- [CHANGELOG.md](CHANGELOG.md) - Version change log
- [example/](example/) - Complete example Flutter app
- [GitHub Issues](https://github.com/FretSpark/fretspark_sdk/issues) - Issue feedback and suggestions
