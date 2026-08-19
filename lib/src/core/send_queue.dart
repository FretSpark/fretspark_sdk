import 'dart:async';
import 'dart:typed_data';

import 'commands.dart';
import 'packet_codec.dart';

/// Serializes command writes to a single device.
///
/// Behavior:
/// - Commands are sent strictly in FIFO order.
/// - Commands in [FretCommand.coalesceCommands] are merged: if the same cmd
///   is already queued, the new params replace the old ones (latest wins).
///   This prevents flooding the firmware BLE_RX_QUEUE_DEPTH=4 with
///   high-frequency frames (e.g. 25fps lighting, 0x22).
/// - Always uses `writeWithoutResponse` first, falls back to `writeWithResponse`
///   if the platform rejects the no-response write.
///
/// This class is internal to the SDK.
class SendQueue {
  SendQueue(this._handle);

  final Future<void> Function(Uint8List payload) _handle;

  final List<_QueueItem> _queue = <_QueueItem>[];
  final Map<int, _QueueItem> _coalesceByKey = <int, _QueueItem>{};
  bool _sending = false;

  Future<void> send(int cmd, List<int> params) {
    final completer = Completer<void>();
    final item = _QueueItem(cmd, params, <Completer<void>>[completer]);

    if (FretCommand.coalesceCommands.contains(cmd)) {
      final existing = _coalesceByKey[cmd];
      if (existing != null) {
        // Replace params, chain completer.
        existing.params = params;
        existing.completers.add(completer);
        return completer.future;
      }
      _coalesceByKey[cmd] = item;
    }

    _queue.add(item);
    _pump();
    return completer.future;
  }

  void _pump() {
    if (_sending) return;
    _sending = true;
    _drain();
  }

  Future<void> _drain() async {
    while (_queue.isNotEmpty) {
      final item = _queue.removeAt(0);
      if (FretCommand.coalesceCommands.contains(item.cmd)) {
        _coalesceByKey.remove(item.cmd);
      }
      try {
        final payload = PacketCodec.encode(item.cmd, item.params);
        await _handle(payload);
        for (final c in item.completers) {
          c.complete();
        }
      } catch (e) {
        for (final c in item.completers) {
          c.completeError(e);
        }
      }
    }
    _sending = false;
  }

  void dispose() {
    _queue.clear();
    _coalesceByKey.clear();
  }
}

class _QueueItem {
  _QueueItem(this.cmd, this.params, this.completers);
  final int cmd;
  List<int> params;
  final List<Completer<void>> completers;
}
