// ignore_for_file: invalid_use_of_visible_for_testing_member
// Test-only fake of [FretTransport] that lets tests script the entire
// connect/scan/connection-state surface without a real BLE stack.

import 'dart:async';

import 'package:fretspark_sdk/src/core/fret_permission_result.dart';
import 'package:fretspark_sdk/src/transport/fret_transport.dart';

import 'fake_ble_device.dart';

/// A fake [FretTransport] that returns scripted [FakeBleDevice] instances
/// on connect and lets tests drive scan results / connection state.
class FakeTransport implements FretTransport {
  /// The device returned by the next [connect] call. If this is null
  /// when [connect] is called, a fresh [FakeBleDevice] is created with
  /// id = the requested [deviceId] and stored in [lastConnectedDevice].
  FakeBleDevice? nextDevice;

  /// The most recent device returned by [connect].
  FakeBleDevice? lastConnectedDevice;

  /// All [connect] invocations, in order.
  final List<String> connectCalls = <String>[];

  /// All [disconnect] invocations, in order.
  final List<String> disconnectCalls = <String>[];

  /// Throw this exception on the next [connect] call (set instead of
  /// [nextDevice] to simulate a connection failure).
  FretTransportException? connectException;

  final StreamController<FretScanResult> _scanController =
      StreamController<FretScanResult>.broadcast();
  final StreamController<FretConnectionState> _connStateController =
      StreamController<FretConnectionState>.broadcast();
  final StreamController<bool> _adapterStateController =
      StreamController<bool>.broadcast();

  bool _permissionsGranted = true;
  bool _adapterOn = true;

  @override
  Future<bool> requestPermissions() async => _permissionsGranted;

  @override
  Future<FretPermissionResult> requestPermissionsDetailed() async {
    final granted = await requestPermissions();
    return granted
        ? FretPermissionResult.granted()
        : FretPermissionResult.denied();
  }

  @override
  Future<bool> get isAdapterOn async => _adapterOn;

  @override
  Stream<bool> get adapterStateChanges => _adapterStateController.stream;

  /// Test-setter: whether [requestPermissions] returns true.
  set permissionsGranted(bool v) => _permissionsGranted = v;
  set adapterOn(bool v) => _adapterOn = v;

  /// Inject an adapter on/off state event as if the OS reported it.
  void emitAdapterStateChange(bool on) {
    _adapterStateController.add(on);
  }

  @override
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 10),
    String? serviceUuid,
  }) async {
    // No-op: tests inject results via [emitScanResult].
  }

  @override
  Future<void> stopScan() async {}

  @override
  Stream<FretScanResult> get scanResults => _scanController.stream;

  /// Inject a scan result as if a real device was discovered.
  void emitScanResult(FretScanResult r) {
    _scanController.add(r);
  }

  @override
  Future<FretBleDevice> connect(String deviceId) async {
    connectCalls.add(deviceId);
    if (connectException != null) {
      final e = connectException!;
      connectException = null;
      throw e;
    }
    final device = nextDevice ??
        FakeBleDevice(id: deviceId, name: 'SCT-86PRO-TEST');
    nextDevice = null;
    lastConnectedDevice = device;
    return device;
  }

  @override
  Future<void> disconnect(String deviceId) async {
    disconnectCalls.add(deviceId);
  }

  @override
  Stream<FretConnectionState> get connectionStates =>
      _connStateController.stream;

  /// Inject a connection-state event for [deviceId].
  void emitConnectionState(String deviceId, bool connected) {
    _connStateController.add(
      FretConnectionState(deviceId: deviceId, isConnected: connected),
    );
  }

  /// Release internal stream controllers.
  Future<void> dispose() async {
    await _scanController.close();
    await _connStateController.close();
    await _adapterStateController.close();
  }
}
