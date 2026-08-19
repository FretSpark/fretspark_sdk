import 'dart:async';

import '../models/fret_notify.dart';
import 'commands.dart';
import 'packet_codec.dart';

/// Dispatches firmware notify frames to typed streams.
///
/// Parsed fields:
/// - 0x0A: battery (level 0-100, voltage mV)
/// - 0x1E: firmware version (major.minor.revision.sub)
/// - 0x1F: LED config (ledCount)
/// - 0x27: LED index mode set confirm
/// - 0x28: LED index mode query result
/// - 0x2A: DIY mode list
///
/// Unknown commands are forwarded to [onUnknownNotify] for forward compat.
///
/// This class is internal to the SDK.
class NotifyDispatcher {
  final StreamController<FretBattery> _batteryController =
      StreamController<FretBattery>.broadcast();
  final StreamController<FretFirmwareVersion> _versionController =
      StreamController<FretFirmwareVersion>.broadcast();
  final StreamController<int> _ledCountController =
      StreamController<int>.broadcast();
  final StreamController<int> _ledIndexModeController =
      StreamController<int>.broadcast();
  final StreamController<List<int>> _diyModeListController =
      StreamController<List<int>>.broadcast();

  /// Catch-all for commands not handled by the typed streams above.
  void Function(FretNotify notify)? onUnknownNotify;

  Stream<FretBattery> get battery => _batteryController.stream;
  Stream<FretFirmwareVersion> get firmwareVersion => _versionController.stream;
  Stream<int> get ledCount => _ledCountController.stream;
  Stream<int> get ledIndexMode => _ledIndexModeController.stream;
  Stream<List<int>> get diyModeList => _diyModeListController.stream;

  /// Feed a raw notify buffer (already stripped of BLE framing by the
  /// transport layer).
  void dispatch(List<int> raw) {
    final notify = PacketCodec.decode(raw);
    if (notify == null) return;
    switch (notify.cmd) {
      case FretCommand.batteryNotify:
        if (notify.data.length >= 3) {
          _batteryController.add(FretBattery(
            level: notify.data[0],
            voltageMv: (notify.data[1] << 8) | notify.data[2],
          ));
        }
        break;
      case FretCommand.queryVersion:
        if (notify.data.length >= 4) {
          _versionController.add(FretFirmwareVersion(
            major: notify.data[0],
            minor: notify.data[1],
            revision: notify.data[2],
            subCode: notify.data[3],
          ));
        }
        break;
      case FretCommand.queryLedConfig:
        if (notify.data.length >= 2) {
          _ledCountController.add(
            (notify.data[0] << 8) | notify.data[1],
          );
        }
        break;
      case FretCommand.setLedIndexMode:
      case FretCommand.queryLedIndexMode:
        if (notify.data.isNotEmpty) {
          _ledIndexModeController.add(notify.data[0]);
        }
        break;
      case FretCommand.queryDiyModeList:
        _diyModeListController.add(List<int>.from(notify.data));
        break;
      default:
        onUnknownNotify?.call(notify);
    }
  }

  void dispose() {
    _batteryController.close();
    _versionController.close();
    _ledCountController.close();
    _ledIndexModeController.close();
    _diyModeListController.close();
  }
}
