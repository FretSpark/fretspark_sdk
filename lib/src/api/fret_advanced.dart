// ignore_for_file: invalid_use_of_visible_for_testing_member
// FretAdvanced 需要调用 FretDevice.send 发送裸命令,这是它的设计目的。

import '../core/commands.dart';
import '../core/send_queue.dart';
import '../models/fret_device.dart';

/// Escape hatch for advanced users who need to send firmware commands
/// that the SDK's high-level API ([FretLED], [FretMetronome],
/// [FretClassroom], ...) does not wrap.
///
/// **⚠️ 警告**: 这是一个"逃生通道", 不是常规 API。使用本类发送裸命令
/// 会绕过 SDK 的状态机优化,可能导致:
///
/// - 组控状态未清理 → 渲染异常
/// - 批量传输 (0x1C/0x16/0x1D) 时序错乱 → LED 数据污染
/// - 高频指令未合并 (coalesce) → BLE 队列溢出 → 丢包
/// - 与 SDK 内部状态不同步 → 后续高阶 API 行为异常
///
/// **使用前请确认**:
/// 1. SDK 高阶 API ([FretLED] / [FretMetronome] 等) **确实**没有等价方法。
/// 2. 已阅读 [FretCommand] 命令码注释,了解参数格式与固件行为。
/// 3. 调用后需要自行管理后续状态 (如发完 0x1C 必须发 0x1D 收尾)。
///
/// 若发现某命令频繁通过本类发送, 请向 SDK 维护者反馈, 以便补充为
/// 高阶 API。
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
  /// **⚠️】比 [sendRaw] 更危险**: 调用方完全失去对发送顺序的可见性,
  /// 仅在确信固件能容忍丢包的场景使用 (如动画刷新)。
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
