// ignore_for_file: invalid_use_of_visible_for_testing_member
// Test-only fake of [FretBleDevice] that captures every write so tests
// can assert on the encoded protocol frame.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fretspark_sdk/src/transport/fret_transport.dart';
import 'package:fretspark_sdk/src/core/commands.dart';

/// A fake [FretBleDevice] that records every [write] call into
/// [writtenFrames] as the raw encoded bytes.
///
/// Each frame is `[0xBC, cmd, len, ...params, 0x55]`. Use [lastFrame] /
/// [lastCmd] / [lastParams] for quick assertions, or [framesFor] to
/// filter by command code.
class FakeBleDevice implements FretBleDevice {
  FakeBleDevice({
    this.id = 'test-device-id',
    this.name = 'SCT-86PRO-TEST',
    this.negotiatedMtu = 247,
  });

  @override
  final String id;

  @override
  final String name;

  @override
  final int negotiatedMtu;

  /// All encoded frames written via [write], in send order.
  final List<List<int>> writtenFrames = <List<int>>[];

  /// Notify frames injected by tests via [emitNotify].
  final StreamController<List<int>> _notifyController =
      StreamController<List<int>>.broadcast();

  /// Last written frame, or throws if none.
  List<int> get lastFrame =>
      writtenFrames.isEmpty ? throw StateError('no frame written') : writtenFrames.last;

  /// Command byte of the last written frame.
  int get lastCmd => lastFrame[1];

  /// Payload (params only, without BC/CMD/LEN/55 delimiters) of the
  /// last written frame.
  List<int> get lastParams {
    final f = lastFrame;
    final len = f[2];
    return f.sublist(3, 3 + len);
  }

  /// All written frames matching [cmd].
  List<List<int>> framesFor(int cmd) =>
      writtenFrames.where((f) => f[1] == cmd).toList();

  @override
  Future<void> write(Uint8List payload) async {
    // Optional artificial delay so tests can simulate the realistic
    // case where multiple sends queue up while a previous frame is
    // still being written. This is the only path that exercises the
    // SendQueue's coalesce logic.
    if (writeDelay != null) {
      await Future<void>.delayed(writeDelay!);
    }
    writtenFrames.add(payload.toList());
  }

  /// Optional delay injected before each [write] records the frame.
  /// Set to a non-zero Duration to simulate a slow BLE stack.
  Duration? writeDelay;

  @override
  Stream<List<int>> get notifyStream => _notifyController.stream;

  /// Inject a notify frame as if the firmware sent it. The frame must
  /// be a complete `[0xCC, cmd, len, ...data, 0xAA]` buffer.
  void emitNotify(List<int> frame) {
    _notifyController.add(frame);
  }

  /// Value returned by [readClassroomId]. Tests can set this to
  /// simulate the firmware's classroom-ID characteristic value, or
  /// leave `null` to simulate a missing characteristic.
  int? classroomIdValue;

  @override
  Future<int?> readClassroomId() async => classroomIdValue;

  @override
  Future<void> writeClassroomId(int id) async {
    classroomIdValue = id;
  }

  @override
  Future<void> disconnect() async {
    await _notifyController.close();
  }

  /// Decode and return the params of every written frame for [cmd].
  /// Helper for the common assertion pattern.
  List<List<int>> paramsFor(int cmd) => framesFor(cmd).map((f) {
        final len = f[2];
        return f.sublist(3, 3 + len);
      }).toList();
}

/// A thin DSL to assert on a frame.
class FrameMatcher {
  FrameMatcher(this.frame);

  final List<int> frame;

  int get cmd => frame[1];
  int get length => frame[2];
  List<int> get params => frame.sublist(3, 3 + length);

  /// Assert this frame starts with 0xBC and ends with 0x55.
  void expectValidFraming() {
    expect(frame.first, kFrameStartAppTo_FW,
        reason: 'frame must start with 0xBC');
    expect(frame.last, kFrameEndAppToFW,
        reason: 'frame must end with 0x55');
    expect(length, params.length,
        reason: 'LEN byte must match payload length');
  }
}

/// Convenience to wrap the last frame of [device] for assertion.
FrameMatcher lastFrameOf(FakeBleDevice device) =>
    FrameMatcher(device.writtenFrames.last);
