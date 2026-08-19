import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../api/fret_ota.dart';

/// Abstraction over the BLE operations [FretOTA.upgrade] needs to drive
/// the Nordic-style OTA service.
///
/// The default implementation [FlutterBlueOtaTransport] wraps
/// `flutter_blue_plus` calls; tests inject a fake to script the full
/// OTA protocol (START_OTA → PARTITION_INFO → 16-packet burst → ACK →
/// REBOOT) without a real BLE stack.
///
/// Brand apps with a non-flutter_blue_plus BLE stack can provide their
/// own implementation and inject it via `FretOTA.forTesting(transport:)`
/// or by subclassing `FretOTA` and overriding the transport factory.
abstract class FretOtaTransport {
  /// Connect to the OTA-mode device at [deviceId]. Should retry on
  /// transient failures (the implementation decides the retry policy).
  /// Throws on unrecoverable failure.
  Future<void> connect(String deviceId, {required Duration timeout});

  /// Discover GATT services and resolve the OTA service's cmd / rsp /
  /// data characteristics. Must be callable after [connect].
  /// Throws [FretOtaException] if the OTA service or any of the three
  /// characteristics are missing.
  Future<void> discoverOtaService({required Duration timeout});

  /// Enable or disable notifications on the rsp characteristic.
  Future<void> setRspNotifyValue(bool enable, {required Duration timeout});

  /// Write [data] to the cmd characteristic with response.
  Future<void> writeCmd(Uint8List data);

  /// Write [data] to the data characteristic without response. The
  /// implementation must respect the platform's write-without-response
  /// queue (e.g. flutter_blue_plus drains automatically).
  Future<void> writeData(Uint8List data, {required bool withoutResponse});

  /// Stream of byte buffers arriving on the rsp characteristic.
  /// Each emission is a complete notify payload as delivered by the OS.
  Stream<List<int>> get rspNotifyStream;

  /// Disconnect from the device and release GATT resources.
  /// Implementations should swallow errors so callers can use this in
  /// a finally block without masking the original exception.
  Future<void> disconnect({required Duration timeout});
}

/// Default [FretOtaTransport] backed by `flutter_blue_plus`.
///
/// Wraps `BluetoothDevice.fromId` + `connect` + `discoverServices` +
/// `BluetoothCharacteristic.write/setNotifyValue/Value` so that
/// [FretOTA.upgrade] can be unit-tested against a fake transport.
class FlutterBlueOtaTransport implements FretOtaTransport {
  FlutterBlueOtaTransport();

  BluetoothDevice? _device;
  BluetoothCharacteristic? _cmdChar;
  BluetoothCharacteristic? _rspChar;
  BluetoothCharacteristic? _dataChar;
  StreamSubscription<List<int>>? _rspSub;
  final StreamController<List<int>> _rspController =
      StreamController<List<int>>.broadcast();

  @override
  Future<void> connect(String deviceId, {required Duration timeout}) async {
    int retries = 0;
    while (true) {
      try {
        _device = BluetoothDevice.fromId(deviceId);
        await _device!
            .connect(autoConnect: false, timeout: const Duration(seconds: 15))
            .timeout(timeout);
        return;
      } catch (e) {
        retries += 1;
        if (retries >= 3) {
          throw FretOtaException('connect failed after 3 retries: $e');
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
  }

  @override
  Future<void> discoverOtaService({required Duration timeout}) async {
    final device = _device;
    if (device == null) {
      throw const FretOtaException('discoverOtaService called before connect');
    }
    final services = await device.discoverServices().timeout(timeout);
    for (final s in services) {
      if (s.uuid.toString().toLowerCase() != FretOTA.serviceUuid) continue;
      for (final c in s.characteristics) {
        final uuid = c.uuid.toString().toLowerCase();
        if (uuid == FretOTA.cmdUuid) {
          _cmdChar = c;
        } else if (uuid == FretOTA.rspUuid) {
          _rspChar = c;
        } else if (uuid == FretOTA.dataUuid) {
          _dataChar = c;
        }
      }
    }
    if (_cmdChar == null || _rspChar == null || _dataChar == null) {
      throw const FretOtaException('OTA characteristics not found');
    }
  }

  @override
  Future<void> setRspNotifyValue(bool enable, {required Duration timeout}) async {
    final rsp = _rspChar;
    if (rsp == null) {
      throw const FretOtaException(
          'setRspNotifyValue called before discoverOtaService');
    }
    if (enable) {
      _rspSub = rsp.value.listen((data) {
        if (data.isNotEmpty) _rspController.add(data);
      });
    }
    try {
      await rsp.setNotifyValue(enable).timeout(timeout);
    } catch (_) {
      // Some platforms reject setNotifyValue when already subscribed;
      // treat as best-effort. The notify stream is still wired above.
    }
  }

  @override
  Future<void> writeCmd(Uint8List data) async {
    final cmd = _cmdChar;
    if (cmd == null) {
      throw const FretOtaException('writeCmd called before discoverOtaService');
    }
    await cmd.write(data);
  }

  @override
  Future<void> writeData(Uint8List data, {required bool withoutResponse}) async {
    final d = _dataChar;
    if (d == null) {
      throw const FretOtaException('writeData called before discoverOtaService');
    }
    await d.write(data, withoutResponse: withoutResponse);
  }

  @override
  Stream<List<int>> get rspNotifyStream => _rspController.stream;

  @override
  Future<void> disconnect({required Duration timeout}) async {
    final sub = _rspSub;
    _rspSub = null;
    await sub?.cancel();
    final device = _device;
    _device = null;
    _cmdChar = null;
    _rspChar = null;
    _dataChar = null;
    if (device != null) {
      try {
        await device.disconnect().timeout(timeout);
      } catch (_) {
        // Swallow so callers can use disconnect in a finally block.
      }
    }
    await _rspController.close();
  }
}
