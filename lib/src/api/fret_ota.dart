// ignore_for_file: invalid_use_of_visible_for_testing_member
// FretOTA 内部需要调用 FretDevice.send 触发 OTA 模式。

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../core/commands.dart';
import '../models/fret_device.dart';
import '../transport/fret_ota_transport.dart';
import '../transport/fret_transport.dart';

/// OTA firmware upgrade API.
///
/// FretSpark devices use a dedicated Nordic-style OTA service separate
/// from the runtime command service. To upgrade:
///
/// 1. The runtime device is notified to enter OTA mode via the runtime
///    command service. The device reboots into OTA mode and starts
///    advertising with the brand's OTA name prefix (e.g. `SCT-86PRO OTA`).
/// 2. The app scans for the OTA-mode device and connects.
/// 3. The app sends the firmware image in 20-byte packets, with a
///    16-packet burst window followed by an ACK from the device.
///    Bad-data responses trigger a rollback + retry (up to 3).
/// 4. On completion, the device reboots into normal mode.
///
/// The BLE GATT operations (connect / discoverServices / write /
/// setNotifyValue / disconnect) are abstracted behind [FretOtaTransport].
/// The default implementation [FlutterBlueOtaTransport] wraps
/// `flutter_blue_plus`; brands with a different BLE stack inject a
/// custom transport via the [FretOTA] constructor. Tests inject a fake
/// transport to script the full OTA protocol without a real BLE stack.
class FretOTA {
  /// Construct an OTA driver. By default uses [FlutterBlueOtaTransport]
  /// (flutter_blue_plus); tests and brands with a different BLE stack
  /// inject a custom [FretOtaTransport].
  FretOTA({FretOtaTransport? transport})
      : _otaTransport = transport ?? FlutterBlueOtaTransport();

  final FretOtaTransport _otaTransport;

  /// OTA service & characteristic UUIDs (PPlus/pHUB compatible).
  static const String serviceUuid = '5833ff01-9b8b-5191-6142-22a4536ef123';
  static const String cmdUuid = '5833ff02-9b8b-5191-6142-22a4536ef123';
  static const String rspUuid = '5833ff03-9b8b-5191-6142-22a4536ef123';
  static const String dataUuid = '5833ff04-9b8b-5191-6142-22a4536ef123';

  /// Burst window: 16 packets × 20 bytes = 320 bytes per ACK.
  static const int burstSize = 16;
  static const int packetSize = 20;
  static const int maxRetries = 3;

  // OTA commands and responses (PPlus convention).
  static const int cmdStartOta = 0x01;
  static const int cmdPartitionInfo = 0x02;
  static const int cmdReboot = 0x04;
  static const int rspStartOta = 0x81;
  static const int rspOtaComplete = 0x83;
  static const int rspPartitionInfo = 0x84;
  static const int rspPartitionComplete = 0x85;
  static const int rspBlockBurst = 0x87;
  static const int rspReboot = 0x8a;
  static const int rspError = 0xff;
  static const int errSuccess = 0;
  static const int errBadData = 104;

  final StreamController<FretOtaProgress> _progressController =
      StreamController<FretOtaProgress>.broadcast();

  /// Emits progress updates during [upgrade]. Brand apps should subscribe
  /// before calling [upgrade] and cancel the subscription after it
  /// completes.
  Stream<FretOtaProgress> get onProgress => _progressController.stream;

  /// Tell a connected runtime device to reboot into OTA mode.
  ///
  /// Notifies the device to enter OTA mode via the runtime command
  /// service. The device disconnects from the runtime service and reboots
  /// advertising its OTA name prefix (e.g. `AUPHY-OTA`). After
  /// [rebootDelay] (default 2 seconds) brand apps should call
  /// [scanOtaDevice] to find the OTA-mode device.
  ///
  /// [device] must be already connected via [FretConnection.connect].
  ///
  /// Example:
  /// ```dart
  /// final device = await FretSpark.instance.connection.connect(deviceId);
  /// await FretSpark.instance.ota.enterOtaMode(device);
  /// final otaDevice = await FretSpark.instance.ota.scanOtaDevice('AUPHY-OTA');
  /// await FretSpark.instance.ota.upgrade(otaDevice!.id, bytes);
  /// ```
  ///
  /// [rebootDelay]: how long to wait after sending the command before
  /// the device is expected to be advertising in OTA mode. The default
  /// 2 seconds is sufficient for current firmware; brand apps rarely
  /// need to override it.
  Future<void> enterOtaMode(
    FretDevice device, {
    Duration rebootDelay = const Duration(seconds: 2),
  }) async {
    await device.send(FretCommand.enterOta, <int>[0x02, 0x01]);
    if (rebootDelay > Duration.zero) {
      await Future<void>.delayed(rebootDelay);
    }
  }

  /// Scan for an OTA-mode device whose advertised name starts with
  /// [prefix]. Returns the first match, or `null` if [timeout] elapses.
  Future<FretScanResult?> scanOtaDevice(
    String prefix, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final completer = Completer<FretScanResult?>();
    StreamSubscription<List<ScanResult>>? sub;
    sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        if (r.device.name.isEmpty) continue;
        if (r.device.name.startsWith(prefix) && !completer.isCompleted) {
          completer.complete(FretScanResult(
            id: r.device.id.id,
            name: r.device.name,
            rssi: r.rssi,
          ));
        }
      }
    });
    try {
      await FlutterBluePlus.startScan(timeout: timeout);
      return await completer.future.timeout(timeout, onTimeout: () => null);
    } catch (_) {
      return null;
    } finally {
      await sub.cancel();
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
    }
  }

  /// Connect to the OTA-mode device at [deviceId], then upgrade its
  /// firmware with [fileBytes]. The device must already be in OTA mode
  /// (i.e. its advertised name must use the OTA prefix).
  ///
  /// Throws [FretOtaException] on any failure. Progress is emitted via
  /// [onProgress].
  Future<void> upgrade(String deviceId, Uint8List fileBytes) async {
    if (fileBytes.isEmpty) {
      throw const FretOtaException('firmware image is empty');
    }
    _emit(phase: FretOtaPhase.connecting, sent: 0, total: fileBytes.length);

    await _otaTransport.connect(
      deviceId,
      timeout: const Duration(seconds: 20),
    );
    try {
      await _otaTransport.discoverOtaService(
        timeout: const Duration(seconds: 15),
      );
      await _otaTransport.setRspNotifyValue(
        true,
        timeout: const Duration(seconds: 5),
      );

      await _runOtaProtocol(fileBytes: fileBytes);
      _emit(
        phase: FretOtaPhase.success,
        sent: fileBytes.length,
        total: fileBytes.length,
      );
    } finally {
      await _otaTransport.disconnect(timeout: const Duration(seconds: 3));
    }
  }

  /// Drives the OTA protocol: send START, wait for rspStartOta, send
  /// PARTITION_INFO, wait for rspPartitionInfo, then stream the data in
  /// 16-packet bursts with ACK-driven retransmission.
  Future<void> _runOtaProtocol({required Uint8List fileBytes}) async {
    final responseQueue = <List<int>>[];
    Completer<void>? pending;

    final sub = _otaTransport.rspNotifyStream.listen((data) {
      responseQueue.add(data);
      final p = pending;
      if (p != null && !p.isCompleted) {
        pending = null;
        p.complete();
      }
    });

    Future<List<int>> nextResponse({
      Duration timeout = const Duration(seconds: 10),
    }) async {
      if (responseQueue.isNotEmpty) {
        return responseQueue.removeAt(0);
      }
      pending = Completer<void>();
      await pending!.future.timeout(timeout);
      return responseQueue.removeAt(0);
    }

    try {
      // 1. Send START_OTA [0x01, 0x02, 0x01]
      _emit(phase: FretOtaPhase.starting, sent: 0, total: fileBytes.length);
      await _otaTransport.writeCmd(
        Uint8List.fromList(<int>[cmdStartOta, 0x02, 0x01]),
      );
      final startRsp = await nextResponse();
      if (!_isRsp(startRsp, rspStartOta, errSuccess)) {
        throw FretOtaException('START_OTA rejected: $startRsp');
      }

      // 2. Send PARTITION_INFO: a single partition covering [fileBytes].
      final totalLen = fileBytes.length;
      await _otaTransport.writeCmd(Uint8List.fromList(<int>[
        cmdPartitionInfo,
        0x00, // partition index 0
        (totalLen >> 24) & 0xFF,
        (totalLen >> 16) & 0xFF,
        (totalLen >> 8) & 0xFF,
        totalLen & 0xFF,
      ]));
      final partRsp = await nextResponse();
      if (!_isRsp(partRsp, rspPartitionInfo, errSuccess)) {
        throw FretOtaException('PARTITION_INFO rejected: $partRsp');
      }

      // 3. Stream data in 16-packet bursts.
      _emit(phase: FretOtaPhase.transferring, sent: 0, total: totalLen);
      int offset = 0;
      int lastBurstStart = 0;
      int retry = 0;

      while (offset < totalLen) {
        lastBurstStart = offset;
        final burstEnd = (offset + burstSize * packetSize > totalLen)
            ? totalLen
            : offset + burstSize * packetSize;

        // Send up to burstSize packets.
        for (int p = 0; p < burstSize && offset < burstEnd; p++) {
          final end =
              (offset + packetSize > totalLen) ? totalLen : offset + packetSize;
          final chunk = Uint8List.sublistView(fileBytes, offset, end);
          // Pad the final packet to packetSize bytes.
          if (chunk.length < packetSize) {
            final padded = Uint8List(packetSize)
              ..setRange(0, chunk.length, chunk);
            await _otaTransport.writeData(padded, withoutResponse: true);
          } else {
            await _otaTransport.writeData(chunk, withoutResponse: true);
          }
          offset = end;
          _emit(
            phase: FretOtaPhase.transferring,
            sent: offset,
            total: totalLen,
          );
          // Yield to let the transport drain its write queue.
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        // Wait for the burst ACK.
        final burstRsp = await nextResponse(
          timeout: const Duration(seconds: 20),
        );
        if (_isRsp(burstRsp, rspBlockBurst, errSuccess)) {
          retry = 0;
          continue;
        }
        if (_isRsp(burstRsp, rspBlockBurst, errBadData)) {
          retry += 1;
          if (retry > maxRetries) {
            throw FretOtaException('burst retry exhausted at offset $offset');
          }
          // Rollback to the start of the failed burst.
          offset = lastBurstStart;
          _emit(
            phase: FretOtaPhase.transferring,
            sent: offset,
            total: totalLen,
          );
          continue;
        }
        throw FretOtaException('unexpected burst response: $burstRsp');
      }

      // 4. Wait for OTA_COMPLETE / PARTITION_COMPLETE.
      final completeRsp = await nextResponse(
        timeout: const Duration(seconds: 30),
      );
      if (!_isRsp(completeRsp, rspOtaComplete, errSuccess) &&
          !_isRsp(completeRsp, rspPartitionComplete, errSuccess)) {
        throw FretOtaException('OTA complete expected, got: $completeRsp');
      }

      // 5. Send REBOOT.
      _emit(phase: FretOtaPhase.rebooting, sent: totalLen, total: totalLen);
      await _otaTransport.writeCmd(Uint8List.fromList(<int>[cmdReboot, 0x00]));
      // The device will disconnect; don't wait for rspReboot.
    } finally {
      await sub.cancel();
    }
  }

  bool _isRsp(List<int> data, int rspCode, int errCode) {
    if (data.length < 2) return false;
    return data[0] == errCode && data[1] == rspCode;
  }

  void _emit({
    required FretOtaPhase phase,
    required int sent,
    required int total,
  }) {
    if (_progressController.isClosed) return;
    _progressController.add(FretOtaProgress(
      phase: phase,
      sentBytes: sent,
      totalBytes: total,
    ));
  }

  /// Release resources. After disposal, [upgrade] will throw.
  void dispose() {
    _progressController.close();
  }
}

/// Progress event emitted by [FretOTA.onProgress].
class FretOtaProgress {
  final FretOtaPhase phase;
  final int sentBytes;
  final int totalBytes;

  const FretOtaProgress({
    required this.phase,
    required this.sentBytes,
    required this.totalBytes,
  });

  /// 0.0–1.0.
  double get fraction =>
      totalBytes > 0 ? (sentBytes / totalBytes).clamp(0.0, 1.0) : 0.0;

  /// 0–100.
  int get percent => (fraction * 100).round();

  @override
  String toString() =>
      'FretOtaProgress($phase, $sentBytes/$totalBytes = $percent%)';
}

/// OTA upgrade phase.
enum FretOtaPhase {
  idle,
  connecting,
  starting,
  transferring,
  rebooting,
  success,
  failed,
}

/// Thrown by [FretOTA.upgrade] on protocol or transport errors.
class FretOtaException implements Exception {
  final String message;
  const FretOtaException(this.message);

  @override
  String toString() => 'FretOtaException: $message';
}
