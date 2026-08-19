import 'dart:async';

import 'fret_transport.dart';

/// Stub [WebBluetoothTransport] for non-Web platforms.
///
/// This stub allows the SDK to compile on Android, iOS, macOS, Windows,
/// and Linux without requiring `package:web` or `dart:js_interop`.
///
/// Constructing or calling any method throws [UnsupportedError]. On Web
/// platforms, the conditional export replaces this stub with the real
/// implementation in `web_bluetooth_web.dart`.
class WebBluetoothTransport extends FretTransport {
  WebBluetoothTransport() {
    throw UnsupportedError(
      'WebBluetoothTransport is only available on the Web platform. '
      'Use the default FlutterBlueTransport on mobile/desktop, or '
      'provide a custom FretTransport implementation.',
    );
  }

  @override
  Future<bool> requestPermissions() async => throw _unsupported;

  @override
  Future<bool> get isAdapterOn async => throw _unsupported;

  @override
  Stream<bool> get adapterStateChanges => const Stream<bool>.empty();

  @override
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 10),
    String? serviceUuid,
  }) async => throw _unsupported;

  @override
  Future<void> stopScan() async => throw _unsupported;

  @override
  Stream<FretScanResult> get scanResults => throw _unsupported;

  @override
  Future<FretBleDevice> connect(String deviceId) async => throw _unsupported;

  @override
  Future<void> disconnect(String deviceId) async => throw _unsupported;

  @override
  Stream<FretConnectionState> get connectionStates => throw _unsupported;

  @override
  void dispose() {}

  static final UnsupportedError _unsupported = UnsupportedError(
    'WebBluetoothTransport is only available on the Web platform.',
  );
}
