import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'fret_transport.dart';

/// GATT UUIDs used by FretSpark firmware.
class _Uuids {
  static const String service = '0000fff0-0000-1000-8000-00805f9b34fb';
  static const String write = '0000fff3-0000-1000-8000-00805f9b34fb';
  static const String notify = '0000fff4-0000-1000-8000-00805f9b34fb';
  static const String classroomId = '0000fff6-0000-1000-8000-00805f9b34fb';
  static const String gapService = '00001800-0000-1000-8000-00805f9b34fb';
  static const String gapDeviceName = '00002a00-0000-1000-8000-00805f9b34fb';

  static bool _matchShort(String uuid, String short16) {
    final lower = uuid.toLowerCase();
    return lower == short16 || lower.endsWith('-0000-1000-8000-00805f9b34fb') &&
        lower.startsWith('0000$short16');
  }

  static bool isService(String uuid) =>
      _matchShort(uuid, 'fff0') || uuid.toLowerCase() == service;

  static bool isWrite(String uuid) => _matchShort(uuid, 'fff3');

  static bool isNotify(String uuid) => _matchShort(uuid, 'fff4');

  static bool isClassroomId(String uuid) => _matchShort(uuid, 'fff6');
}

/// Default [FretTransport] implementation backed by `flutter_blue_plus`.
class FlutterBlueTransport extends FretTransport {
  FlutterBlueTransport();

  final StreamController<FretScanResult> _scanController =
      StreamController<FretScanResult>.broadcast();
  final StreamController<FretConnectionState> _connectionController =
      StreamController<FretConnectionState>.broadcast();

  StreamSubscription<List<ScanResult>>? _scanSub;
  bool _scanning = false;
  final Set<String> _seen = <String>{};
  final Map<String, _FlutterBlueDevice> _connected = <String, _FlutterBlueDevice>{};

  @override
  Future<bool> requestPermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
    final scan = statuses[Permission.bluetoothScan]?.isGranted ?? false;
    final connect = statuses[Permission.bluetoothConnect]?.isGranted ?? false;
    final location = statuses[Permission.location]?.isGranted ?? false;
    // Android <= 11 uses location; Android 12+ uses scan+connect.
    return (scan && connect) || location;
  }

  @override
  Future<bool> get isAdapterOn async => FlutterBluePlus.isOn;

  @override
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 10),
    String? serviceUuid,
  }) async {
    if (_scanning) return;
    _seen.clear();
    _scanController.stream; // ensure alive
    _scanning = true;

    await FlutterBluePlus.stopScan();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    _scanSub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        if (r.device.name.isEmpty) continue;
        if (_seen.add(r.device.id.id)) {
          _scanController.add(FretScanResult(
            id: r.device.id.id,
            name: r.device.name,
            rssi: r.rssi,
          ));
        }
      }
    });

    await FlutterBluePlus.startScan(timeout: timeout);
  }

  @override
  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
    await _scanSub?.cancel();
    _scanSub = null;
    _scanning = false;
  }

  @override
  Stream<FretScanResult> get scanResults => _scanController.stream;

  @override
  Future<FretBleDevice> connect(String deviceId) async {
    final device = BluetoothDevice.fromId(deviceId);

    // Disconnect any stale connection.
    if (device.isConnected) {
      try {
        await device.disconnect().timeout(const Duration(seconds: 3));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      } catch (_) {}
    }

    // Connect with retry.
    int retries = 0;
    const maxRetries = 3;
    while (true) {
      try {
        await device
            .connect(autoConnect: false, timeout: const Duration(seconds: 15))
            .timeout(const Duration(seconds: 20));
        break;
      } catch (e) {
        retries += 1;
        if (retries >= maxRetries) {
          throw FretTransportException('connect failed after $maxRetries retries: $e');
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }

    // MTU.
    int mtu = 247;
    try {
      mtu = await device.requestMtu(247).timeout(const Duration(seconds: 5));
    } catch (_) {}

    // Service discovery.
    final services = await device.discoverServices().timeout(
      const Duration(seconds: 15),
    );

    BluetoothCharacteristic? writeChar;
    BluetoothCharacteristic? notifyChar;
    BluetoothCharacteristic? classroomIdChar;

    for (final s in services) {
      final sUuid = s.uuid.toString().toLowerCase();
      final isFff0 = sUuid == _Uuids.service || sUuid == 'fff0' || sUuid == '0000fff0';
      if (!isFff0) continue;
      for (final c in s.characteristics) {
        final cUuid = c.uuid.toString().toLowerCase();
        if (writeChar == null && _Uuids.isWrite(cUuid)) {
          writeChar = c;
        } else if (notifyChar == null && _Uuids.isNotify(cUuid)) {
          notifyChar = c;
        } else if (classroomIdChar == null && _Uuids.isClassroomId(cUuid)) {
          classroomIdChar = c;
        }
      }
    }

    if (writeChar == null || notifyChar == null) {
      await device.disconnect();
      throw FretTransportException(
        'FFF0 service missing FFF3/FFF4 characteristics',
      );
    }

    // Subscribe to notify.
    try {
      await notifyChar.setNotifyValue(true).timeout(const Duration(seconds: 5));
    } catch (_) {}

    final wrapped = _FlutterBlueDevice(
      device: device,
      writeChar: writeChar,
      notifyChar: notifyChar,
      classroomIdChar: classroomIdChar,
      mtu: mtu,
      onConnectionChange: (connected) {
        _connectionController.add(
          FretConnectionState(deviceId: deviceId, isConnected: connected),
        );
        if (!connected) _connected.remove(deviceId);
      },
    );
    _connected[deviceId] = wrapped;
    return wrapped;
  }

  @override
  Future<void> disconnect(String deviceId) async {
    final dev = _connected.remove(deviceId);
    if (dev != null) await dev.disconnect();
  }

  @override
  Stream<FretConnectionState> get connectionStates => _connectionController.stream;

  void dispose() {
    _scanSub?.cancel();
    _scanController.close();
    _connectionController.close();
  }
}

class _FlutterBlueDevice extends FretBleDevice {
  _FlutterBlueDevice({
    required this.device,
    required this.writeChar,
    required this.notifyChar,
    required this.classroomIdChar,
    required this.mtu,
    required this.onConnectionChange,
  }) {
    _connectionSub = device.connectionState.listen((state) {
      final connected = state == BluetoothConnectionState.connected;
      onConnectionChange(connected);
    });
  }

  final BluetoothDevice device;
  final BluetoothCharacteristic writeChar;
  final BluetoothCharacteristic notifyChar;
  final BluetoothCharacteristic? classroomIdChar;
  final int mtu;
  final void Function(bool connected) onConnectionChange;

  late final StreamSubscription<BluetoothConnectionState> _connectionSub;

  @override
  String get id => device.id.id;

  @override
  String get name => device.name;

  @override
  int get negotiatedMtu => mtu;

  @override
  Future<void> write(Uint8List payload) async {
    try {
      await writeChar.write(payload, withoutResponse: true);
    } catch (_) {
      // Fallback to with-response write (some platforms reject no-response
      // when the payload exceeds ATT_MTU - 3).
      await writeChar.write(payload, withoutResponse: false);
    }
  }

  @override
  Stream<List<int>> get notifyStream => notifyChar.value;

  @override
  Future<int?> readClassroomId() async {
    if (classroomIdChar == null) return null;
    try {
      final value = await classroomIdChar!.read().timeout(
        const Duration(seconds: 3),
      );
      if (value.isEmpty) return null;
      if (value.length >= 4) {
        return ((value[0] & 0xFF) << 24) |
            ((value[1] & 0xFF) << 16) |
            ((value[2] & 0xFF) << 8) |
            (value[3] & 0xFF);
      }
      if (value.length == 2) {
        return ((value[0] & 0xFF) << 8) | (value[1] & 0xFF);
      }
      return value[0] & 0xFF;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeClassroomId(int id) async {
    if (classroomIdChar == null) {
      throw FretTransportException('FFF6 characteristic not available');
    }
    final bytes = Uint8List(4)
      ..[0] = (id >> 24) & 0xFF
      ..[1] = (id >> 16) & 0xFF
      ..[2] = (id >> 8) & 0xFF
      ..[3] = id & 0xFF;
    try {
      await classroomIdChar!.write(bytes, withoutResponse: true);
    } catch (_) {
      await classroomIdChar!.write(bytes, withoutResponse: false);
    }
  }

  @override
  Future<void> disconnect() async {
    await _connectionSub.cancel();
    try {
      await device.disconnect().timeout(const Duration(seconds: 3));
    } catch (_) {}
  }
}
