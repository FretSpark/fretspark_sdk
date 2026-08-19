// ignore_for_file: invalid_use_of_visible_for_testing_member
// Unit tests for the FretAdvanced escape-hatch class added in SDK 1.4.0.
//
// Verifies:
// - sendRaw routes through FretDevice.send (encoded frame is observable
//   on FakeBleDevice).
// - sendRawFireAndForget does not throw even when the device is disposed
//   (errors are swallowed).
// - bypassQueue=true throws UnimplementedError (reserved for future use).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:fretspark_sdk/src/api/fret_advanced.dart';
import 'package:fretspark_sdk/src/core/commands.dart';
import 'package:fretspark_sdk/src/models/fret_device.dart';

import 'helpers/fake_ble_device.dart';

void main() {
  late FakeBleDevice ble;
  late FretDevice device;

  setUp(() {
    ble = FakeBleDevice();
    device = FretDevice.forBle(
      ble: ble,
      displayName: ble.name,
      brandId: 'auphy',
    );
  });

  group('FretAdvanced.sendRaw', () {
    test('sends the given cmd + params through the queue', () async {
      await FretAdvanced.sendRaw(
        device,
        FretCommand.musicStyle,
        <int>[42],
      );
      final m = lastFrameOf(ble);
      m.expectValidFraming();
      expect(m.cmd, FretCommand.musicStyle);
      expect(m.params, <int>[42]);
    });

    test('can send a command the high-level API does not wrap (0x13 knobHsl)',
        () async {
      await FretAdvanced.sendRaw(
        device,
        FretCommand.knobHsl,
        <int>[(180 >> 8) & 0xFF, 180 & 0xFF],
      );
      final m = lastFrameOf(ble);
      expect(m.cmd, FretCommand.knobHsl);
      expect(m.params, <int>[0x00, 0xB4]);
    });

    test('empty params produce an empty payload (LEN=0)', () async {
      await FretAdvanced.sendRaw(device, FretCommand.queryVersion, <int>[]);
      final m = lastFrameOf(ble);
      expect(m.cmd, FretCommand.queryVersion);
      expect(m.length, 0);
    });

    test('bypassQueue=true throws UnimplementedError', () async {
      expect(
        () => FretAdvanced.sendRaw(
          device,
          FretCommand.power,
          <int>[0x01],
          bypassQueue: true,
        ),
        throwsA(isA<UnimplementedError>()),
      );
      expect(ble.writtenFrames, isEmpty,
          reason: 'no frame should be written when bypassQueue throws');
    });

    test('rejects disposed device with StateError', () async {
      await device.dispose();
      expect(
        () => FretAdvanced.sendRaw(device, FretCommand.power, <int>[0x01]),
        throwsA(isA<StateError>()),
      );
    });

    test('multiple sendRaw calls preserve FIFO order', () async {
      await FretAdvanced.sendRaw(device, FretCommand.power, <int>[0x01]);
      await FretAdvanced.sendRaw(device, FretCommand.brightness, <int>[0, 100, 0, 0, 0, 0]);
      await FretAdvanced.sendRaw(device, FretCommand.mode, <int>[0, 2]);
      expect(ble.writtenFrames.length, 3);
      expect(ble.writtenFrames[0][1], FretCommand.power);
      expect(ble.writtenFrames[1][1], FretCommand.brightness);
      expect(ble.writtenFrames[2][1], FretCommand.mode);
    });
  });

  group('FretAdvanced.sendRawFireAndForget', () {
    test('returns immediately and the frame still reaches the device',
        () async {
      FretAdvanced.sendRawFireAndForget(
        device,
        FretCommand.power,
        <int>[0x01],
      );
      // The send is queued synchronously; pump the microtask queue so
      // the SendQueue can drain.
      await Future<void>.delayed(Duration.zero);
      expect(ble.writtenFrames.length, 1);
      expect(ble.writtenFrames[0][1], FretCommand.power);
    });

    test('swallows errors from disposed device (no exception thrown)',
        () async {
      await device.dispose();
      // Should NOT throw — fire-and-forget swallows errors.
      FretAdvanced.sendRawFireAndForget(
        device,
        FretCommand.power,
        <int>[0x01],
      );
      // Pump the microtask queue so the underlying send().catchError
      // completes.
      await Future<void>.delayed(Duration.zero);
      expect(ble.writtenFrames, isEmpty);
    });
  });

  group('FretAdvanced protocol contract', () {
    test('sendRaw coalesces high-frequency commands when send2/3 queue '
        'during send1 ble.write', () async {
      // voiceSensitivity (0x12) is in FretCommand.coalesceCommands.
      // SendQueue's coalesce only kicks in when sends queue up while a
      // previous frame is still being written (i.e. during ble.write).
      // We simulate this by giving ble.write a small delay and issuing
      // 3 sends without awaiting the first two.
      ble.writeDelay = const Duration(milliseconds: 10);

      // Issue 3 sends without awaiting the first two — they queue
      // concurrently while the first frame is being written.
      final f1 = FretAdvanced.sendRaw(
        device,
        FretCommand.voiceSensitivity,
        <int>[10],
      );
      // Pump a microtask so send1 reaches ble.write and starts
      // awaiting the 10 ms delay.
      await Future<void>.delayed(Duration.zero);
      final f2 = FretAdvanced.sendRaw(
        device,
        FretCommand.voiceSensitivity,
        <int>[20],
      );
      final f3 = FretAdvanced.sendRaw(
        device,
        FretCommand.voiceSensitivity,
        <int>[30],
      );
      await Future.wait(<Future<void>>[f1, f2, f3]);

      // Coalesce dedupes by cmd; only the latest params win.
      // Expected: 2 frames total — frame 1 with [10] (already in
      // flight when send2/3 queued), frame 2 with [30] (send2 and
      // send3 coalesced to one queued item).
      final frames = ble.framesFor(FretCommand.voiceSensitivity);
      expect(frames.length, 2);
      expect(frames[0].sublist(3, 4), <int>[10]); // first frame params
      expect(frames[1].sublist(3, 4), <int>[30]); // coalesced frame
    });
  });
}
