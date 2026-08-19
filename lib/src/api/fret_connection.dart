// ignore_for_file: invalid_use_of_visible_for_testing_member
// FretConnection internally needs to call FretDevice.forBle /
// attachQueriedInfo / send.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/commands.dart';
import '../models/brand_config.dart';
import '../models/fret_device.dart';
import '../transport/fret_transport.dart';

/// Scans for and connects to FretSpark devices.
///
/// Brand apps obtain an instance via `FretSpark.connection`. The class wraps
/// a [FretTransport] (default BLE transport implementation) and:
/// - Filters scan results by the active brand's [BrandConfig.firmwarePatterns].
/// - On connect, performs the initial handshake and reads the classroom ID
///   from the classroom-ID characteristic.
/// - Tracks the currently-connected [FretDevice] so the brand app can
///   access it without holding the reference itself.
/// Callback used by [FretConnection] to auto-detect the brand from a
/// device's BLE advertised name. Set via [FretConnection.setBrandMatcher].
/// The SDK wires this to [FretBrand.matchByFirmwareName] during
/// `FretSpark.initialize`.
typedef FretBrandMatcher = BrandConfig? Function(String deviceName);

class FretConnection {
  FretConnection(this._transport);

  final FretTransport _transport;

  /// Active brand, used to filter scan results. Set by `FretSpark.initialize`.
  BrandConfig? _activeBrand;
  BrandConfig? get activeBrand => _activeBrand;

  /// Currently-connected device, or `null` if disconnected.
  FretDevice? _current;
  FretDevice? get current => _current;

  /// Optional brand matcher for auto-detection on connect.
  FretBrandMatcher? _brandMatcher;

  final StreamController<BrandConfig> _brandDetectedController =
      StreamController<BrandConfig>.broadcast();

  /// Emits the auto-detected [BrandConfig] when a device is connected
  /// whose advertised name matches a different brand than the current
  /// [activeBrand]. Brand apps can subscribe to update their UI.
  Stream<BrandConfig> get onBrandAutoDetected =>
      _brandDetectedController.stream;

  /// Stream of connection-state changes for the active device.
  /// Emits `false` if the device disconnects unexpectedly.
  Stream<bool> get onCurrentDeviceStateChanged {
    if (_current == null) {
      return const Stream<bool>.empty();
    }
    final id = _current!.id;
    return _transport.connectionStates
        .where((e) => e.deviceId == id)
        .map((e) => e.isConnected);
  }

  /// Set the active brand (called by `FretSpark.initialize`).
  @visibleForTesting
  void setActiveBrand(BrandConfig? brand) {
    _activeBrand = brand;
  }

  /// Set the brand-matcher callback for auto-detection on connect.
  /// Wired by `FretSpark.initialize` to `FretBrand.matchByFirmwareName`.
  @visibleForTesting
  void setBrandMatcher(FretBrandMatcher? matcher) {
    _brandMatcher = matcher;
  }

  /// Returns `true` if the OS grants Bluetooth scan/connect permissions.
  Future<bool> requestPermissions() => _transport.requestPermissions();

  /// Returns `true` if the device's Bluetooth adapter is on.
  Future<bool> get isAdapterOn => _transport.isAdapterOn;

  /// Start a BLE scan. Results are filtered by [BrandConfig.firmwarePatterns]
  /// when an active brand is set.
  ///
  /// Emits results on [scanResults]. Stops automatically after [timeout].
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    await _transport.startScan(timeout: timeout);
  }

  /// Stop an in-flight scan.
  Future<void> stopScan() => _transport.stopScan();

  /// Stream of scan results, filtered by the active brand's firmware
  /// patterns. If no active brand is set, all named devices are emitted.
  Stream<FretScanResult> get scanResults {
    final brand = _activeBrand;
    if (brand == null) {
      return _transport.scanResults;
    }
    return _transport.scanResults.where((r) => brand.matches(r.name));
  }

  /// Connect to a device by its BLE id.
  ///
  /// Performs:
  /// 1. BLE connect + MTU negotiation + service discovery (via transport).
  /// 2. Firmware version query — fills [FretDevice.firmwareVersion].
  /// 3. LED config query — fills [FretDevice.ledCount].
  /// 4. LED index mode query — fills [FretDevice.ledIndexReversed].
  /// 5. Classroom ID read — fills [FretDevice.classroomId].
  ///
  /// Throws [FretTransportException] if the BLE connection fails. If a
  /// query times out, the corresponding field remains at its default
  /// (empty / 90 / 0 / 0).
  Future<FretDevice> connect(String deviceId) async {
    if (_current != null && _current!.id == deviceId) {
      return _current!;
    }
    // Disconnect any prior device before connecting a new one.
    if (_current != null) {
      await _current!.dispose();
      _current = null;
    }

    final ble = await _transport.connect(deviceId);

    // Auto-detect brand from the device's BLE advertised name.
    BrandConfig? detected = _activeBrand;
    if (_brandMatcher != null && ble.name.isNotEmpty) {
      final matched = _brandMatcher!(ble.name);
      if (matched != null && matched.id != _activeBrand?.id) {
        detected = matched;
        _activeBrand = matched;
        // Notify listeners (FretSpark persists this via FretBrand.setActive).
        if (!_brandDetectedController.isClosed) {
          _brandDetectedController.add(matched);
        }
      }
    }

    final device = FretDevice.forBle(
      ble: ble,
      displayName: ble.name,
      brandId: detected?.id ?? 'unknown',
    );
    _current = device;

    // Run the handshake queries in parallel; each has a per-query timeout.
    final results = await Future.wait(<Future<dynamic>>[
      _queryFirmwareVersion(device)
          .timeout(const Duration(seconds: 3), onTimeout: () => ''),
      _queryLedConfig(device)
          .timeout(const Duration(seconds: 3), onTimeout: () => 90),
      _queryLedIndexMode(device)
          .timeout(const Duration(seconds: 3), onTimeout: () => 0),
      ble
          .readClassroomId()
          .timeout(const Duration(seconds: 3), onTimeout: () => 0),
    ]);

    // Apply the results that did not time out.
    final version = results[0] as String?;
    final ledCount = results[1] as int?;
    final ledIndexReversed = results[2] as int?;
    final classroomId = results[3] as int?;

    device.attachQueriedInfo(
      firmwareVersion: version ?? '',
      ledCount: ledCount ?? 90,
      ledIndexReversed: ledIndexReversed ?? 0,
      classroomId: classroomId ?? 0,
    );

    return device;
  }

  /// Disconnect the current device.
  Future<void> disconnect() async {
    final dev = _current;
    _current = null;
    if (dev != null) {
      await dev.dispose();
    }
  }

  // === Handshake queries ===

  Future<String> _queryFirmwareVersion(FretDevice device) async {
    final completer = Completer<String>();
    final sub = device.onFirmwareVersionQueried.listen((v) {
      if (!completer.isCompleted) completer.complete(v.formatted);
    });
    try {
      await device.send(FretCommand.queryVersion, <int>[]);
      // NOTE: `return await` (not `return`) is required so the async
      // function awaits the completer before entering finally. With
      // a bare `return completer.future;`, finally runs before the
      // completer completes and cancels the subscription, losing the
      // notify response. The bare-return form is a regression that
      // silently breaks firmware-version/led-config/led-index-mode
      // application during connect.
      return await completer.future;
    } finally {
      await sub.cancel();
    }
  }

  Future<int> _queryLedConfig(FretDevice device) async {
    final completer = Completer<int>();
    final sub = device.onLedCountChanged.listen((count) {
      if (!completer.isCompleted) completer.complete(count);
    });
    try {
      await device.send(FretCommand.queryLedConfig, <int>[]);
      return await completer.future;
    } finally {
      await sub.cancel();
    }
  }

  Future<int> _queryLedIndexMode(FretDevice device) async {
    final completer = Completer<int>();
    final sub = device.onLedIndexModeChanged.listen((mode) {
      if (!completer.isCompleted) completer.complete(mode);
    });
    try {
      await device.send(FretCommand.queryLedIndexMode, <int>[]);
      return await completer.future;
    } finally {
      await sub.cancel();
    }
  }
}
