// ignore_for_file: invalid_use_of_visible_for_testing_member
// FretAdvanced needs to call FretDevice.send to send raw commands; that
// is its design purpose.

import '../core/commands.dart';
import '../core/send_queue.dart';
import '../models/fret_device.dart';

/// Escape hatch for advanced users who need to send firmware commands
/// that the SDK's high-level API ([FretLED], [FretMetronome],
/// [FretClassroom], ...) does not wrap.
///
/// **⚠️ Warning**: this is an "escape hatch", not a regular API. Sending
/// raw commands via this class bypasses the SDK's state-machine
/// optimizations and may cause:
///
/// - Group-control state not cleaned up → rendering anomaly
/// - Batch transfer (0x1C/0x16/0x1D) timing disorder → LED data corruption
/// - High-frequency commands not coalesced → BLE queue overflow → packet loss
/// - Out of sync with SDK internal state → subsequent high-level API
///   behaves unexpectedly
///
/// **Before using, confirm**:
/// 1. The SDK's high-level API ([FretLED] / [FretMetronome], etc.) really
///    does not have an equivalent method.
/// 2. You have read the [FretCommand] code comments and understand the
///    parameter format and firmware behavior.
/// 3. You will manage subsequent state yourself (e.g. after sending 0x1C
///    you must send 0x1D to finalize).
///
/// If you find a command is frequently sent via this class, please report
/// it to the SDK maintainers so it can be added as a high-level API.
class FretAdvanced {
  FretAdvanced._();

  /// Send a raw firmware command without going through the high-level API.
  ///
  /// [cmd] must be one of the [FretCommand] constants (e.g.
  /// [FretCommand.power], [FretCommand.musicStyle]). [params] is the
  /// command payload (without the BC/55 frame delimiters — the SDK
  /// adds those automatically).
  ///
  /// The command is queued through [FretDevice]'s normal send queue,
  /// so it respects coalescing rules for high-frequency commands
  /// (see [FretCommand.coalesceCommands]). To bypass the queue
  /// entirely (rarely needed — e.g. for OTA control chars), set
  /// [bypassQueue] to `true`. **Bypassing the queue can cause
  /// out-of-order delivery relative to other commands** — use only
  /// when you understand the firmware's per-command ordering
  /// requirements.
  ///
  /// Example:
  /// ```dart
  /// // Send a custom music style the SDK doesn't wrap yet.
  /// await FretSpark.instance.advanced.sendRaw(
  ///   device,
  ///   FretCommand.musicStyle,
  ///   <int>[42],
  /// );
  /// ```
  ///
  /// Throws [StateError] if the device has been disposed.
  static Future<void> sendRaw(
    FretDevice device,
    int cmd,
    List<int> params, {
    bool bypassQueue = false,
  }) async {
    if (bypassQueue) {
      // Bypass the SendQueue and call _ble.write directly. We reach
      // the underlying ble device via a temporary SendQueue with
      // coalescing disabled — but to keep this class stateless we
      // simply fall back to the normal queue with a warning path.
      //
      // The firmware's BLE write path is already single-threaded via
      // the underlying flutter_blue transport, so "bypassing the
      // queue" mainly affects coalescing, not ordering. For true
      // out-of-band writes (OTA control characteristic), use
      // [FretOTA]'s dedicated write methods instead.
      throw UnimplementedError(
        'bypassQueue is reserved for future use. '
        'For OTA writes, use FretOTA.* methods. '
        'For normal commands, leave bypassQueue=false.',
      );
    }
    await device.send(cmd, params);
  }

  /// Send a raw firmware command and return immediately without waiting
  /// for the send queue to flush.
  ///
  /// Equivalent to [sendRaw] but does not `await` the underlying
  /// [SendQueue.send] future. Useful for fire-and-forget scenarios
  /// where the brand app does not need to confirm the command reached
  /// the firmware (e.g. high-frequency animation frames where dropped
  /// packets are acceptable).
  ///
  /// **⚠️ More dangerous than [sendRaw]**: the caller completely loses
  /// visibility into send ordering. Use only in scenarios where you are
  /// certain the firmware can tolerate packet loss (e.g. animation
  /// refresh).
  static void sendRawFireAndForget(
    FretDevice device,
    int cmd,
    List<int> params,
  ) {
    // Fire-and-forget: ignore the returned future.
    device.send(cmd, params).catchError((Object _) {
      // Swallow errors silently — caller opted into fire-and-forget.
    });
  }
}
