// Web Bluetooth transport adapter for the FretSpark SDK.
//
// This file demonstrates how to implement [FretTransport] using the Web
// Bluetooth API, enabling the FretSpark SDK to run in a Flutter Web app
// (or any Dart web app) in Chrome/Edge/Opera on desktop.
//
// ## Web Bluetooth limitations (important)
//
// 1. **No background scanning.** The Web Bluetooth API does not expose
//    a passive scan. Instead, the browser shows a device-picker dialog
//    and the user manually selects a device. Call [startScan] to trigger
//    the picker; the selected device is emitted on [scanResults].
//
// 2. **No RSSI.** The Web Bluetooth API does not expose advertised
//    RSSI. All scan results report rssi=0.
//
// 3. **No MTU negotiation.** The Web Bluetooth API does not support
//    MTU negotiation. The negotiated MTU is fixed at 23 (the BLE
//    default). This means the SDK's packet codec already splits
//    payloads into ≤20-byte frames, so this is not a problem.
//
// 4. **User gesture required.** [startScan] must be called from a
//    user gesture (e.g. a button tap). Browsers reject programmatic
//    calls without a user activation.
//
// 5. **HTTPS required.** Web Bluetooth only works on HTTPS origins
//    (or localhost for development).
//
// 6. **Browser support.** Chrome (macOS/Windows/Linux/Android),
//    Edge, Opera. Not supported in Firefox or Safari.
//
// ## Usage
//
// ```dart
// import 'web_bluetooth_transport.dart';
//
// await FretSpark.instance.initialize(
//   brandId: 'auphy',
//   transport: WebBluetoothTransport(),
// );
//
// // Trigger the browser's device picker (must be from a button tap).
// await FretSpark.instance.connection.startScan();
// ```

// This file uses dart:js_interop to call the Web Bluetooth API.
// It only compiles on the Web platform. To use it in a cross-platform
// app, use conditional imports:
//
//   import 'default_transport.dart'
//       if (dart.library.js_interop) 'web_bluetooth_transport.dart';

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:fretspark_sdk/fretspark_sdk.dart';
import 'package:web/web.dart';

/// GATT UUIDs used by FretSpark firmware (must match the native transport).
const String _kServiceUuid = '0000fff0-0000-1000-8000-00805f9b34fb';
const String _kWriteUuid = '0000fff3-0000-1000-8000-00805f9b34fb';
const String _kNotifyUuid = '0000fff4-0000-1000-8000-00805f9b34fb';
const String _kClassroomIdUuid = '0000fff6-0000-1000-8000-00805f9b34fb';

/// A [FretTransport] implementation backed by the Web Bluetooth API.
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
    // Return true if the Web Bluetooth API is available.
    return _isWebBluetoothAvailable;
  }

  @override
  Future<bool> get isAdapterOn async => _isWebBluetoothAvailable;

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
    //
    // The filters use the active brand's name prefix. If no brand is
    // set, we request all devices with the FretSpark service.
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

      // Auto-connect after selection (the SDK's connect() will be a no-op
      // if already connected).
    } on JSException catch (e) {
      throw FretTransportException('Device selection cancelled or failed: $e');
    }
  }

  @override
  Future<void> stopScan() async {
    // Web Bluetooth has no scan to stop; the device picker is modal.
    // Close the scan stream to signal completion.
    await _scanController.close();
  }

  @override
  Stream<FretScanResult> get scanResults => _scanController.stream;

  @override
  Future<FretBleDevice> connect(String deviceId) async {
    // If the user already selected a device via startScan(), use it.
    // If not, we need to call requestDevice again (requires user gesture).
    if (_webDevice == null) {
      // Trigger the device picker again.
      await startScan();
      if (_webDevice == null) {
        throw const FretTransportException('No device selected');
      }
    }

    // Verify the selected device matches the requested deviceId.
    if (_webDevice!.id != deviceId) {
      // The user picked a different device than the one requested.
      // In practice, this shouldn't happen because the SDK uses the
      // deviceId from scanResults (which came from startScan).
      throw FretTransportException(
        'Selected device $_webDevice!.id does not match requested $deviceId',
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

  // === Internal: notify callback ===

  /// Called by the browser when the notify characteristic sends data.
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

/// Helper to build the `requestDevice()` options object.
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
