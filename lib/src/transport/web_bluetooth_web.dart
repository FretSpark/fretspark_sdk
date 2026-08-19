// Web Bluetooth transport adapter for the FretSpark SDK.
//
// This file provides the real [WebBluetoothTransport] implementation backed
// by the Web Bluetooth API. It is only compiled on the Web platform
// (where `dart:js_interop` and `package:web` are available).
//
// On non-Web platforms, the conditional export in
// `web_bluetooth_transport.dart` loads the stub in
// `web_bluetooth_stub.dart` instead.
//
// ## Web Bluetooth limitations
//
// 1. **No background scanning.** The browser shows a device-picker dialog
//    and the user manually selects a device. Call [startScan] to trigger
//    the picker; the selected device is emitted on [scanResults].
//
// 2. **No RSSI.** All scan results report rssi=0.
//
// 3. **No MTU negotiation.** MTU is fixed at 23. The SDK's packet codec
//    already splits payloads into ≤20-byte frames, so this is not an issue.
//
// 4. **User gesture required.** [startScan] must be called from a user
//    gesture (e.g. a button tap).
//
// 5. **HTTPS required.** Web Bluetooth only works on HTTPS (or localhost).
//
// 6. **Browser support.** Chrome, Edge, Opera. Not Firefox or Safari.
//
// ## Usage
//
// ```dart
// import 'package:fretspark_sdk/fretspark_sdk.dart';
//
// await FretSpark.instance.initialize(
//   brandId: 'auphy',
//   transport: WebBluetoothTransport(),
// );
// ```

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart';

import 'fret_transport.dart';

/// GATT UUIDs used by FretSpark firmware (must match the native transport).
const String _kServiceUuid = '0000fff0-0000-1000-8000-00805f9b34fb';
const String _kWriteUuid = '0000fff3-0000-1000-8000-00805f9b34fb';
const String _kNotifyUuid = '0000fff4-0000-1000-8000-00805f9b34fb';
const String _kClassroomIdUuid = '0000fff6-0000-1000-8000-00805f9b34fb';

/// A [FretTransport] implementation backed by the Web Bluetooth API.
///
/// This class is only available on the Web platform. On other platforms,
/// constructing it throws [UnsupportedError] (via the conditional export
/// stub).
///
/// See file-level documentation for limitations and usage instructions.
class WebBluetoothTransport extends FretTransport {
  WebBluetoothTransport();

  final StreamController<FretScanResult> _scanController =
      StreamController<FretScanResult>.broadcast();
  final StreamController<FretConnectionState> _connectionController =
      StreamController<FretConnectionState>.broadcast();

  /// The selected device from the browser's device picker.
  BluetoothDevice? _webDevice;
  BluetoothRemoteGATTServer? _gattServer;
  BluetoothRemoteGATTCharacteristic? _writeChar;
  BluetoothRemoteGATTCharacteristic? _notifyChar;

  final StreamController<List<int>> _notifyController =
      StreamController<List<int>>.broadcast();

  @override
  Future<bool> requestPermissions() async {
    // Web Bluetooth does not require explicit OS permissions. The browser
    // handles permission via the device-picker dialog.
    return _isWebBluetoothAvailable;
  }

  @override
  Future<bool> get isAdapterOn async => _isWebBluetoothAvailable;

  @override
  Stream<bool> get adapterStateChanges => const Stream<bool>.empty();

  bool get _isWebBluetoothAvailable {
    try {
      return window.navigator.bluetooth != null;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 10),
    String? serviceUuid,
  }) async {
    // Web Bluetooth does not support passive scanning. Instead, we
    // request the user to pick a device from the browser's dialog.
    final options = _RequestDeviceOptions(
      filters: [
        _Filter(namePrefix: 'SCT-86PRO'),
        _Filter(namePrefix: 'FretSpark'),
        _Filter(namePrefix: 'AUPHY'),
      ],
      optionalServices: [_kServiceUuid],
    );

    try {
      _webDevice = await window.navigator.bluetooth
          .requestDevice(options.toJS())
          .toDart();

      // Emit the selected device as a scan result.
      final name = _webDevice!.name ?? 'Unknown';
      final id = _webDevice!.id;
      _scanController.add(FretScanResult(
        id: id,
        name: name,
        rssi: 0, // Web Bluetooth does not expose RSSI.
      ));
    } on JSException catch (e) {
      throw FretTransportException('Device selection cancelled or failed: $e');
    }
  }

  @override
  Future<void> stopScan() async {
    // Web Bluetooth has no scan to stop; the device picker is modal.
    await _scanController.close();
  }

  @override
  Stream<FretScanResult> get scanResults => _scanController.stream;

  @override
  Future<FretBleDevice> connect(String deviceId) async {
    // If the user already selected a device via startScan(), use it.
    if (_webDevice == null) {
      await startScan();
      if (_webDevice == null) {
        throw const FretTransportException('No device selected');
      }
    }

    // Verify the selected device matches the requested deviceId.
    if (_webDevice!.id != deviceId) {
      throw FretTransportException(
        'Selected device ${_webDevice!.id} does not match requested $deviceId',
      );
    }

    try {
      _gattServer = await _webDevice!.gatt!.connect().toDart();

      // Discover the FretSpark service and characteristics.
      final service =
          await _gattServer!.getPrimaryService(_kServiceUuid.toJS()).toDart();

      _writeChar = await service.getCharacteristic(_kWriteUuid.toJS()).toDart();
      _notifyChar =
          await service.getCharacteristic(_kNotifyUuid.toJS()).toDart();

      // Start notifications on the notify characteristic.
      await _notifyChar!.startNotifications().toDart();

      // Listen for characteristic value changes.
      _notifyChar!.addEventListener(
        'characteristicvaluechanged'.toJS,
        _onNotify.toJS,
      );

      _connectionController.add(FretConnectionState(
        deviceId: deviceId,
        isConnected: true,
      ));

      return _WebBluetoothDevice(
        transport: this,
        deviceId: deviceId,
        device: _webDevice!,
        writeChar: _writeChar!,
        notifyChar: _notifyChar!,
        notifyStream: _notifyController.stream,
      );
    } on JSException catch (e) {
      throw FretTransportException('GATT connection failed: $e');
    }
  }

  @override
  Future<void> disconnect(String deviceId) async {
    _connectionController
        .add(FretConnectionState(deviceId: deviceId, isConnected: false));

    if (_notifyChar != null) {
      try {
        _notifyChar!.removeEventListener(
          'characteristicvaluechanged'.toJS,
          _onNotify.toJS,
        );
        await _notifyChar!.stopNotifications().toDart();
      } catch (_) {
        // Best-effort cleanup.
      }
    }

    if (_webDevice != null) {
      try {
        _webDevice!.gatt!.disconnect();
      } catch (_) {
        // Device may already be disconnected.
      }
    }

    _writeChar = null;
    _notifyChar = null;
    _gattServer = null;
    _webDevice = null;
  }

  @override
  Stream<FretConnectionState> get connectionStates =>
      _connectionController.stream;

  @override
  void dispose() {
    _scanController.close();
    _connectionController.close();
    _notifyController.close();
  }

  // === Internal: notify callback ===

  void _onNotify(Event event) {
    final charEvent = event as CharacteristicEvent;
    final dataView = charEvent.target.value;
    if (dataView == null) return;

    // Convert DataView to List<int>.
    final bytes = <int>[];
    for (int i = 0; i < dataView.byteLength; i++) {
      bytes.add(dataView.getUint8(i));
    }
    _notifyController.add(bytes);
  }

  // === Internal: GATT operations used by _WebBluetoothDevice ===

  Future<void> _write(Uint8List payload) async {
    if (_writeChar == null) {
      throw const FretTransportException('Write characteristic not available');
    }
    try {
      // Prefer writeValueWithoutResponse for low-latency command writes.
      // Fall back to writeValueWithResponse if the browser rejects it.
      try {
        await _writeChar!.writeValueWithoutResponse(payload).toDart();
      } catch (_) {
        await _writeChar!.writeValueWithResponse(payload).toDart();
      }
    } on JSException catch (e) {
      throw FretTransportException('GATT write failed: $e');
    }
  }

  Future<int?> _readClassroomId() async {
    if (_gattServer == null) return null;
    try {
      final service =
          await _gattServer!.getPrimaryService(_kServiceUuid.toJS()).toDart();
      final char =
          await service.getCharacteristic(_kClassroomIdUuid.toJS()).toDart();
      final dataView = await char.readValue().toDart();

      // 4-byte big-endian uint32.
      if (dataView.byteLength < 4) return null;
      return dataView.getUint32(0, Endianness.bigEndian);
    } on JSException {
      // Characteristic may be missing on some firmware versions.
      return null;
    }
  }

  Future<void> _writeClassroomId(int id) async {
    if (_gattServer == null) {
      throw const FretTransportException('GATT server not available');
    }
    try {
      final service =
          await _gattServer!.getPrimaryService(_kServiceUuid.toJS()).toDart();
      final char =
          await service.getCharacteristic(_kClassroomIdUuid.toJS()).toDart();

      // 4-byte big-endian uint32.
      final buffer = ByteData(4);
      buffer.setUint32(0, id, Endianness.bigEndian);
      await char.writeValueWithResponse(buffer.buffer.asUint8List()).toDart();
    } on JSException catch (e) {
      throw FretTransportException('Classroom ID write failed: $e');
    }
  }
}

/// A [FretBleDevice] backed by a Web Bluetooth GATT connection.
class _WebBluetoothDevice extends FretBleDevice {
  _WebBluetoothDevice({
    required this.transport,
    required this.deviceId,
    required this.device,
    required this.writeChar,
    required this.notifyChar,
    required this.notifyStream,
  });

  final WebBluetoothTransport transport;
  final String deviceId;
  final BluetoothDevice device;
  final BluetoothRemoteGATTCharacteristic writeChar;
  final BluetoothRemoteGATTCharacteristic notifyChar;
  final Stream<List<int>> notifyStream;

  @override
  String get id => deviceId;

  @override
  String get name => device.name ?? 'Unknown';

  @override
  int get negotiatedMtu => 23; // Web Bluetooth does not support MTU negotiation.

  @override
  Future<void> write(Uint8List payload) => transport._write(payload);

  @override
  Stream<List<int>> get notifyStream => this.notifyStream;

  @override
  Future<int?> readClassroomId() => transport._readClassroomId();

  @override
  Future<void> writeClassroomId(int id) => transport._writeClassroomId(id);

  @override
  Future<void> disconnect() => transport.disconnect(deviceId);
}

// === JS interop helpers for requestDevice options ===

class _RequestDeviceOptions {
  _RequestDeviceOptions({
    required this.filters,
    required this.optionalServices,
  });

  final List<_Filter> filters;
  final List<String> optionalServices;

  JSObject toJS() {
    final filtersJS = filters.map((f) => f.toJS()).toList().toJS;
    final servicesJS =
        optionalServices.map((s) => s.toJS).toList().toJS;
    return {'filters': filtersJS, 'optionalServices': servicesJS}.jsify();
  }
}

class _Filter {
  _Filter({this.namePrefix});
  final String? namePrefix;

  JSObject toJS() {
    if (namePrefix != null) {
      return {'namePrefix': namePrefix}.jsify();
    }
    return {}.jsify();
  }
}
