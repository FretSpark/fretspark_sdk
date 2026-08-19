import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/commands.dart';
import '../core/notify_dispatcher.dart';
import '../core/send_queue.dart';
import '../transport/fret_transport.dart';
import 'fret_notify.dart';

/// A connected FretSpark device.
///
/// Returned by `FretSpark.connection.connect(...)`. Brand apps hold a
/// reference to this object and pass it to `FretSpark.led.*`,
/// `FretSpark.ota.*`, etc.
///
/// On connect, the SDK automatically:
/// - Queries firmware version -> [firmwareVersion]
/// - Queries LED config -> [ledCount], [maxFret]
/// - Queries LED index mode -> [ledIndexReversed]
/// - Reads classroom ID from the classroom-ID characteristic (if present)
///   -> [classroomId]
class FretDevice {
  /// Internal constructor used by [FretConnection]. Brand apps receive
  /// an instance from `FretSpark.connection.connect`; they do not
  /// construct [FretDevice] directly.
  @visibleForTesting
  FretDevice.forBle({
    required FretBleDevice ble,
    required this.displayName,
    required this.brandId,
  })  : _ble = ble,
        _sendQueue = SendQueue(ble.write),
        _notify = NotifyDispatcher() {
    _notifySub = ble.notifyStream.listen(_notify.dispatch);
  }

  final FretBleDevice _ble;
  final SendQueue _sendQueue;
  final NotifyDispatcher _notify;
  late final StreamSubscription<List<int>> _notifySub;

  /// Display name (may differ from [name] if the brand app set a custom one).
  final String displayName;

  /// Brand that owns this device (matches [BrandConfig.id]).
  final String brandId;

  // === Auto-queried device info ===
  String _firmwareVersion = '';
  int _ledCount = 90;
  int _ledIndexReversed = 0;
  int _classroomId = 0;
  int _batteryLevel = 0;
  int _batteryVoltageMv = 0;
  bool _disposed = false;
  bool _rtcSynced = false;

  /// Firmware version string (e.g. `1.2.3.4`). Empty until the query
  /// completes or times out.
  String get firmwareVersion => _firmwareVersion;

  /// Total LED count on this device (e.g. 84 for a 14-fret board, 126 for 21).
  int get ledCount => _ledCount;

  /// Maximum fret index (ledCount / 6 - 1).
  /// For a 14-fret board: 84 / 6 - 1 = 13.
  /// For a 21-fret board: 126 / 6 - 1 = 20.
  int get maxFret => (ledCount ~/ 6) - 1;

  /// LED index mode: 0 = normal order, 1 = reversed (newer hardware).
  int get ledIndexReversed => _ledIndexReversed;

  /// Classroom ID read from the classroom-ID characteristic (0-9999, 0 = not set).
  int get classroomId => _classroomId;

  /// Latest battery level (0-100). Stale until the first notify.
  int get batteryLevel => _batteryLevel;

  /// Latest battery voltage in mV. Stale until the first notify.
  int get batteryVoltageMv => _batteryVoltageMv;

  /// Whether the device RTC has been synchronized via [setRtcTime].
  ///
  /// Required before [FretLED.setTimer]; the firmware uses its RTC as the
  /// reference for scheduled power on/off. Until [setRtcTime] succeeds,
  /// this is `false` and [FretLED.setTimer] will reject.
  bool get isRtcSynced => _rtcSynced;

  /// BLE device id.
  String get id => _ble.id;

  /// BLE advertised name.
  String get name => _ble.name;

  /// Negotiated MTU.
  int get mtu => _ble.negotiatedMtu;

  /// Whether the device is currently connected.
  bool get isConnected => !_disposed;

  // === Streams ===
  Stream<FretBattery> get onBatteryChanged => _notify.battery;
  Stream<FretFirmwareVersion> get onFirmwareVersionQueried =>
      _notify.firmwareVersion;
  Stream<int> get onLedCountChanged => _notify.ledCount;
  Stream<int> get onLedIndexModeChanged => _notify.ledIndexMode;
  Stream<List<int>> get onDiyModeList => _notify.diyModeList;

  /// Catch-all for firmware notify commands not handled by the typed streams.
  /// Use this to access experimental/new commands added by future firmware.
  void Function(FretNotify notify)? onUnknownNotify;

  // === Internal: send a command via the queue ===

  /// Send a raw firmware command.
  ///
  /// **⚠️ Internal method; brand apps should not call it directly.**
  ///
  /// Brand apps should use the high-level APIs ([FretLED] / [FretOTA] /
  /// [FretMetronome] / [FretClassroom], etc.) instead of calling [send]
  /// with raw commands; otherwise the SDK's state machine (group control /
  /// batch transfer / coalesce) may be broken, causing LED anomalies or
  /// OTA failures.
  ///
  /// This method is for SDK internal use only, and for unit tests to
  /// inject commands while bypassing the high-level API.
  @visibleForTesting
  Future<void> send(int cmd, List<int> params) async {
    if (_disposed) {
      throw StateError('FretDevice($id) is disposed');
    }
    await _sendQueue.send(cmd, params);
  }

  /// Set the classroom ID (classroom-ID characteristic, 4-byte big-endian uint32).
  Future<void> setClassroomId(int id) async {
    if (id < 0 || id > 9999) {
      throw ArgumentError('classroomId must be 0..9999, got $id');
    }
    await _ble.writeClassroomId(id);
    _classroomId = id;
  }

  // === RTC & runtime queries ===

  /// Sync the device's RTC to the given [time].
  ///
  /// Required before [FretLED.setTimer] — the firmware uses its RTC as
  /// the reference for scheduled power on/off. If the RTC is never
  /// synced, the firmware's clock drifts from wall time and timers fire
  /// at the wrong moment.
  ///
  /// Maps to firmware command 0x0B. Payload layout:
  /// `[yearH, yearL, month, day, hour, minute, second]`.
  ///
  /// Note: the firmware currently only reads year/month/day/hour/minute
  /// (second is sent but unused). The year is a 16-bit unsigned int.
  Future<void> setRtcTime(DateTime time) async {
    final year = time.year;
    if (year < 0 || year > 0xFFFF) {
      throw ArgumentError('year must be 0..65535, got $year');
    }
    await send(FretCommand.rtcTime, <int>[
      (year >> 8) & 0xFF,
      year & 0xFF,
      time.month,
      time.day,
      time.hour,
      time.minute,
      time.second,
    ]);
    _rtcSynced = true;
  }

  /// Re-query the firmware version at runtime.
  ///
  /// On [FretConnection.connect], the SDK already queries this once and
  /// fills [firmwareVersion]. Use this method to re-query after a manual
  /// firmware upgrade or whenever the brand app needs the latest value.
  /// The result is delivered via [onFirmwareVersionQueried].
  ///
  /// Returns a [Future] that completes when the query command has been
  /// queued (not when the notify arrives — subscribe to the stream for
  /// the result).
  Future<void> queryVersion() async {
    await send(FretCommand.queryVersion, <int>[]);
  }

  /// Re-query the LED config (LED count) at runtime.
  ///
  /// On [FretConnection.connect], the SDK already queries this once and
  /// fills [ledCount]. Use this method after [FretLED.setLedCount] or
  /// whenever the brand app needs to refresh the value. The result is
  /// delivered via [onLedCountChanged].
  Future<void> queryLedConfig() async {
    await send(FretCommand.queryLedConfig, <int>[]);
  }

  /// Trigger the firmware to push its current status (battery, config,
  /// etc.) via notify.
  ///
  /// The firmware has no dedicated "query battery" command; battery
  /// level is normally pushed proactively by the firmware. This method
  /// sends command 0x0C `[0x01]`, which makes the firmware call
  /// `send_type_request(8)` and `send_type_request(9)` internally to
  /// re-push its status. Subscribe to [onBatteryChanged] for the result.
  ///
  /// Use this when the brand app needs to refresh the battery display
  /// after the screen is re-opened or after a long idle period.
  Future<void> queryStatus() async {
    await send(FretCommand.queryStatus, <int>[0x01]);
  }

  /// Configure the catch-all notify handler. See [onUnknownNotify].
  void setUnknownNotifyHandler(void Function(FretNotify)? handler) {
    onUnknownNotify = handler;
    _notify.onUnknownNotify = handler;
  }

  // === Internal: lifecycle hooks ===

  /// Apply the queried device info after the connect handshake.
  /// Called by [FretConnection] once the parallel handshake queries
  /// resolve.
  ///
  /// **⚠️ Internal method; brand apps should not call it directly.** For
  /// SDK internal use and unit tests only.
  @visibleForTesting
  void attachQueriedInfo({
    required String firmwareVersion,
    required int ledCount,
    required int ledIndexReversed,
    required int classroomId,
  }) {
    _firmwareVersion = firmwareVersion;
    _ledCount = ledCount;
    _ledIndexReversed = ledIndexReversed;
    _classroomId = classroomId;
    _notify.battery.listen((b) {
      _batteryLevel = b.level;
      _batteryVoltageMv = b.voltageMv;
    });
  }

  /// Disconnect and release all resources.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _notifySub.cancel();
    _notify.dispose();
    _sendQueue.dispose();
    await _ble.disconnect();
  }
}
