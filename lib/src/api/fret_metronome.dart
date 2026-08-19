// ignore_for_file: invalid_use_of_visible_for_testing_member
// FretMetronome 内部需要调用 FretDevice.send 发送节拍器命令。

import '../core/commands.dart';
import '../models/fret_device.dart';

/// Time signatures accepted by the firmware metronome.
enum FretTimeSignature {
  twoFour(2),
  threeFour(3),
  fourFour(4),
  sixEight(6);

  final int beats;
  const FretTimeSignature(this.beats);
}

/// Firmware metronome control.
///
/// The firmware has a built-in metronome that emits a click on the LED
/// panel. Brand apps start/stop it via this class; the actual beat
/// scheduling lives in the firmware.
class FretMetronome {
  FretMetronome();

  /// Start the metronome on [device].
  ///
  /// - [bpm]: 40–240.
  /// - [timeSignature]: defaults to 4/4.
  Future<void> start(
    FretDevice device, {
    required int bpm,
    FretTimeSignature timeSignature = FretTimeSignature.fourFour,
  }) async {
    if (bpm < 40 || bpm > 240) {
      throw ArgumentError('bpm must be 40..240, got $bpm');
    }
    await device.send(FretCommand.metronomeStart, <int>[
      (bpm >> 8) & 0xFF,
      bpm & 0xFF,
      timeSignature.beats,
    ]);
  }

  /// Stop the metronome on [device].
  Future<void> stop(FretDevice device) async {
    await device.send(FretCommand.metronomeStop, <int>[]);
  }
}
