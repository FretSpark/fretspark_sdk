import 'dart:async';
import 'dart:typed_data';

/// Abstraction over the BLE transport layer.
///
/// The SDK ships a default [FlutterBlueTransport] implementation. Brand apps
/// that use a different BLE stack (React Native, native iOS/Android, Web
/// Bluetooth) can provide their own implementation and inject it via
/// `FretSpark.initialize(transport: ...)`.
///
/// All methods are async and may throw [FretTransportException].
abstract class FretTransport {
  /// Request OS-level permissions (Bluetooth scan/connect, location on
  /// Android <= 11). Returns `true` if all required permissions are granted.
  Future<bool> requestPermissions();

  /// Returns `true` if the device's Bluetooth adapter is on and ready.
  Future<bool> get isAdapterOn;

  /// Start a BLE scan. Results are emitted on [scanResults].
  /// If [serviceUuid] is non-null, the scan is filtered to that service.
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 10),
    String? serviceUuid,
  });

  /// Stop an in-flight scan.
  Future<void> stopScan();

  /// Stream of scan results discovered during [startScan].
  /// Each result is emitted once per device id.
  Stream<FretScanResult> get scanResults;

  /// Connect to a device. Performs MTU negotiation and service discovery.
  /// Throws if connection fails after retries.
  Future<FretBleDevice> connect(String deviceId);

  /// Disconnect from a device.
  Future<void> disconnect(String deviceId);

  /// Stream of connection-state changes per device.
  Stream<FretConnectionState> get connectionStates;
}

/// A single BLE scan result.
class FretScanResult {
  final String id;
  final String name;
  final int rssi;

  const FretScanResult(
      {required this.id, required this.name, required this.rssi});

  @override
  String toString() => 'FretScanResult($name, $id, rssi=$rssi)';
}

/// Connection-state change event.
class FretConnectionState {
  final String deviceId;
  final bool isConnected;
  const FretConnectionState(
      {required this.deviceId, required this.isConnected});
}

/// A connected BLE device with the runtime command service configured.
///
/// The SDK owns the write/notify subscriptions. Brand apps interact with the
/// device via [FretDevice] (returned by `FretSpark.connection.connect`),
/// not via this raw transport interface.
abstract class FretBleDevice {
  String get id;
  String get name;
  int get negotiatedMtu;

  /// Write a payload to the command-write characteristic without response.
  /// Falls back to with-response write if the platform rejects the
  /// no-response variant.
  Future<void> write(Uint8List payload);

  /// Stream of notify frames from the notify characteristic (raw bytes, as
  /// delivered by the OS).
  Stream<List<int>> get notifyStream;

  /// Read the 4-byte big-endian classroom ID from the classroom-ID
  /// characteristic. Returns null if the characteristic is missing or the
  /// read times out.
  Future<int?> readClassroomId();

  /// Write the 4-byte big-endian classroom ID to the classroom-ID
  /// characteristic.
  Future<void> writeClassroomId(int id);

  /// Disconnect and release all resources.
  Future<void> disconnect();
}

class FretTransportException implements Exception {
  final String message;
  const FretTransportException(this.message);

  @override
  String toString() => 'FretTransportException: $message';
}
