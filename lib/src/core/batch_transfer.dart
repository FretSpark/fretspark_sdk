import 'dart:async';

import 'commands.dart';

/// Coordinates multi-packet batch transfers (0x1C + 0x16×N + 0x1D).
///
/// Why this exists:
/// - `applyDraw` / `setLearningMultipleLEDs` / `syncChordLEDs` are async and
///   can be called fire-and-forget by the UI layer. Two overlapping calls
///   would interleave 0x1C...0x1D frames in the BLE queue, causing the
///   firmware to emit "EXPECTED N, GOT M" warnings and drop the batch.
/// - This lock makes the second call a no-op while the first is in flight.
///   For 25fps lighting, dropped frames are visually preferable to corrupted
///   batches that cause flicker.
///
/// Behavior:
/// - `tryEnter(deviceId)` returns `true` if the lock was acquired.
///   If the lock is already held, returns `false` (caller should drop the
///   frame).
/// - `exit(deviceId)` releases the lock.
/// - Lock state is per-device, so multiple devices can transfer in parallel.
///
/// This class is internal to the SDK.
class BatchTransfer {
  final Map<String, bool> _busy = <String, bool>{};

  bool tryEnter(String deviceId) {
    if (_busy[deviceId] == true) return false;
    _busy[deviceId] = true;
    return true;
  }

  void exit(String deviceId) {
    _busy[deviceId] = false;
  }
}

/// Sends a list of LED pixels to the firmware, choosing the optimal path:
/// - <= [FretCommand.maxLedsPerPacket] LEDs: single 0x22 [0x02, count, ...].
/// - >  [FretCommand.maxLedsPerPacket] LEDs: 0x1C + 0x16×N + 0x1D batch.
///
/// [pixels] is a list of `{index, r, g, b}` maps (already mirrored and
/// bounds-checked by the caller).
///
/// This class is internal to the SDK.
class LedBatchSender {
  LedBatchSender(this._send);

  final Future<void> Function(int cmd, List<int> params) _send;
  final BatchTransfer _batchLock = BatchTransfer();

  Future<void> sendLearningMultiple({
    required String deviceId,
    required List<({int index, int r, int g, int b})> pixels,
  }) async {
    if (pixels.isEmpty) return;

    // Pack into a flat list of [idx, r, g, b, ...].
    final flat = <int>[];
    for (final p in pixels) {
      flat.addAll(<int>[p.index, p.r, p.g, p.b]);
    }
    final count = flat.length ~/ 4;

    if (count <= FretCommand.maxLedsPerPacket) {
      // Single 0x22 [0x02, count, ...].
      await _send(FretCommand.learningLed, <int>[0x02, count, ...flat]);
      return;
    }

    // Multi-packet batch: 0x1C -> 0x16×N -> 0x1D.
    // Drop the frame if a previous batch is still in flight (back-pressure).
    if (!_batchLock.tryEnter(deviceId)) return;
    try {
      final totalPackets = (count / FretCommand.maxLedsPerPacket).ceil();
      await _send(FretCommand.batchBegin, <int>[totalPackets]);
      int seq = 0;
      for (int i = 0; i < flat.length; i += FretCommand.maxLedsPerPacket * 4) {
        seq += 1;
        final end = (i + FretCommand.maxLedsPerPacket * 4 > flat.length)
            ? flat.length
            : i + FretCommand.maxLedsPerPacket * 4;
        final chunk = flat.sublist(i, end);
        final chunkLen = chunk.length ~/ 4;
        await _send(
          FretCommand.batchData,
          <int>[seq, chunkLen, ...chunk],
        );
      }
      await _send(FretCommand.batchEnd, <int>[]);
    } finally {
      _batchLock.exit(deviceId);
    }
  }
}
