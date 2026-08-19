// Integration tests for [FretMetronome].
//
// Coverage:
//   - start(device, bpm, timeSignature): encodes 0x20 [bpmH, bpmL, beats]
//   - bpm boundary validation (40 / 240 accepted; <40 / >240 rejected)
//   - all 4 time signatures encode correct beat count
//   - stop(device): encodes 0x21 with empty payload
//   - disposed device throws StateError

import 'package:flutter_test/flutter_test.dart';
import 'package:fretspark_sdk/src/api/fret_metronome.dart';
import 'package:fretspark_sdk/src/core/commands.dart';
import 'package:fretspark_sdk/src/models/fret_device.dart';

import 'helpers/fake_ble_device.dart';

void main() {
  group('FretMetronome', () {
    late FakeBleDevice ble;
    late FretDevice device;
    late FretMetronome metronome;

    setUp(() {
      ble = FakeBleDevice(id: 'dev-metronome', name: 'SCT-86PRO-TEST');
      device = FretDevice.forBle(
        ble: ble,
        displayName: 'Test',
        brandId: 'fretspark',
      );
      metronome = FretMetronome();
    });

    group('start', () {
      test('encodes 0x20 with [bpmH, bpmL, timeSignature] for 120 bpm 4/4',
          () async {
        await metronome.start(device, bpm: 120);

        expect(ble.framesFor(FretCommand.metronomeStart).length, 1);
        final params = ble.paramsFor(FretCommand.metronomeStart).single;
        // 120 = 0x00 0x78; 4/4 → 4 beats
        expect(params, <int>[0x00, 0x78, 4]);
      });

      test('accepts bpm=40 (lower boundary)', () async {
        await metronome.start(device, bpm: 40);
        final params = ble.paramsFor(FretCommand.metronomeStart).single;
        expect(params, <int>[0x00, 0x28, 4]);
      });

      test('accepts bpm=240 (upper boundary)', () async {
        await metronome.start(device, bpm: 240);
        final params = ble.paramsFor(FretCommand.metronomeStart).single;
        expect(params, <int>[0x00, 0xF0, 4]);
      });

      test('encodes bpm as 2-byte big-endian for bpm > 255', () async {
        await metronome.start(device, bpm: 200);
        final params = ble.paramsFor(FretCommand.metronomeStart).single;
        // 200 = 0x00 0xC8
        expect(params, <int>[0x00, 0xC8, 4]);
      });

      test('twoFour encodes beats=2', () async {
        await metronome.start(
          device,
          bpm: 100,
          timeSignature: FretTimeSignature.twoFour,
        );
        expect(ble.paramsFor(FretCommand.metronomeStart).single.last, 2);
      });

      test('threeFour encodes beats=3', () async {
        await metronome.start(
          device,
          bpm: 100,
          timeSignature: FretTimeSignature.threeFour,
        );
        expect(ble.paramsFor(FretCommand.metronomeStart).single.last, 3);
      });

      test('sixEight encodes beats=6', () async {
        await metronome.start(
          device,
          bpm: 100,
          timeSignature: FretTimeSignature.sixEight,
        );
        expect(ble.paramsFor(FretCommand.metronomeStart).single.last, 6);
      });

      test('default time signature is fourFour (beats=4)', () async {
        await metronome.start(device, bpm: 100);
        expect(ble.paramsFor(FretCommand.metronomeStart).single.last, 4);
      });

      test('bpm < 40 throws ArgumentError', () {
        expect(
          () => metronome.start(device, bpm: 39),
          throwsA(isA<ArgumentError>()),
        );
        expect(ble.framesFor(FretCommand.metronomeStart), isEmpty,
            reason: 'no frame sent on validation failure');
      });

      test('bpm > 240 throws ArgumentError', () {
        expect(
          () => metronome.start(device, bpm: 241),
          throwsA(isA<ArgumentError>()),
        );
        expect(ble.framesFor(FretCommand.metronomeStart), isEmpty);
      });

      test('bpm=0 throws ArgumentError', () {
        expect(
          () => metronome.start(device, bpm: 0),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('disposed device throws StateError', () async {
        await device.dispose();
        expect(
          () => metronome.start(device, bpm: 120),
          throwsA(isA<StateError>()),
        );
      });
    });

    group('stop', () {
      test('encodes 0x21 with empty payload', () async {
        await metronome.stop(device);

        expect(ble.framesFor(FretCommand.metronomeStop).length, 1);
        final params = ble.paramsFor(FretCommand.metronomeStop).single;
        expect(params, isEmpty);
      });

      test('disposed device throws StateError', () async {
        await device.dispose();
        expect(
          () => metronome.stop(device),
          throwsA(isA<StateError>()),
        );
      });
    });
  });

  group('FretTimeSignature', () {
    test('twoFour has 2 beats', () {
      expect(FretTimeSignature.twoFour.beats, 2);
    });

    test('threeFour has 3 beats', () {
      expect(FretTimeSignature.threeFour.beats, 3);
    });

    test('fourFour has 4 beats', () {
      expect(FretTimeSignature.fourFour.beats, 4);
    });

    test('sixEight has 6 beats', () {
      expect(FretTimeSignature.sixEight.beats, 6);
    });

    test('has exactly 4 values', () {
      expect(FretTimeSignature.values.length, 4);
    });
  });
}
