import 'dart:typed_data';

import '../models/fret_notify.dart';
import 'commands.dart';

/// Encodes/decodes firmware BLE packets.
///
/// APP -> firmware: `[0xBC, cmd, paramsLen, ...params, 0x55]`
/// Firmware -> APP: `[0xCC, cmd, len, ...data, 0xAA]`
///
/// This class is internal to the SDK and not exported to brand apps.
class PacketCodec {
  PacketCodec._();

  /// Build an APP->firmware frame.
  static Uint8List encode(int cmd, List<int> params) {
    final List<int> packet = <int>[
      kFrameStartAppTo_FW,
      cmd,
      params.length,
      ...params,
      kFrameEndAppToFW,
    ];
    return Uint8List.fromList(packet);
  }

  /// Try to parse a firmware->APP notify frame.
  /// Returns `null` if the buffer is malformed.
  static FretNotify? decode(List<int> data) {
    if (data.length < 4) return null;
    if (data.first != kFrameStartFWToApp || data.last != kFrameEndFWToApp) {
      return null;
    }
    final cmd = data[1];
    final len = data[2];
    if (data.length != 3 + len + 1) return null;
    final payload = data.sublist(3, 3 + len);
    return FretNotify(cmd: cmd, data: payload);
  }
}
