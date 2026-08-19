// ignore_for_file: invalid_use_of_visible_for_testing_member
// Regression tests for the legacy FretLED API surface (everything that
// existed before SDK 1.4.0). These guard against accidental behavior
// changes when refactoring the LED state machine.
//
// Coverage:
//   - Power / brightness / color        (0x01, 0x05, 0x04, 0x15)
//   - Effect mode / speed / direction    (0x06, 0x08, 0x07)
//   - setAllOn / clearAll                (mode=2, batchBegin/End)
//   - Selection mask                     (0x18)
//   - Single / multiple learning LEDs   (0x22, batched 0x1C/0x16/0x1D)
//   - Chord / scale                      (compositional)
//   - Music mode / mic / voice / energy  (0x09, 0x0F, 0x11, 0x12, 0x26)
//   - Group channel                      (0x19, 0x1A, 0x17, 0x1C/0x1D)
//   - DIY mode list                      (0x29, 0x2A)
//   - LED index mode                     (0x27)
//   - Group-channel state-machine cleanup frames

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fretspark_sdk/src/api/fret_led.dart';
import 'package:fretspark_sdk/src/core/commands.dart';
import 'package:fretspark_sdk/src/core/fret_spark_exception.dart';
import 'package:fretspark_sdk/src/models/fret_color.dart';
import 'package:fretspark_sdk/src/models/fret_device.dart';
import 'package:fretspark_sdk/src/models/fret_note.dart';

import 'helpers/fake_ble_device.dart';

void main() {
  late FretLED led;
  late FakeBleDevice ble;
  late FretDevice device;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    led = FretLED(prefs);
    await led.loadPersistedState();

    ble = FakeBleDevice();
    device = FretDevice.forBle(
      ble: ble,
      displayName: ble.name,
      brandId: 'auphy',
    );
  });

  // Helper: assert a specific cmd produced the expected params at the
  // given 0-based index among all frames with that cmd.
  List<List<int>> framesForCmd(int cmd) => ble.framesFor(cmd);

  group('FretLED.setPower (0x01)', () {
    test('on sends [0x01]', () async {
      await led.setPower(device, on: true);
      final m = lastFrameOf(ble);
      m.expectValidFraming();
      expect(m.cmd, FretCommand.power);
      expect(m.params, <int>[0x01]);
    });

    test('off sends [0x00]', () async {
      await led.setPower(device, on: false);
      expect(lastFrameOf(ble).params, <int>[0x00]);
    });

    test('emits group-channel cleanup frame first when in group context',
        () async {
      // Enter group context via applyGroupMap (sets _groupActive=true).
      await led.applyGroupMap(device, 0, <int>[1, 1, 1]);
      ble.writtenFrames.clear();

      await led.setPower(device, on: true);

      // First a groupMap [] cleanup, then the power frame.
      expect(ble.writtenFrames.length, 2);
      expect(ble.writtenFrames[0][1], FretCommand.groupMap);
      expect(ble.writtenFrames[0].sublist(3, 3), <int>[]);
      expect(ble.writtenFrames[1][1], FretCommand.power);
    });
  });

  group('FretLED.setBrightness (0x05)', () {
    test('encodes uint16 big-endian + 4 trailing zero bytes', () async {
      await led.setBrightness(device, 500);
      final m = lastFrameOf(ble);
      m.expectValidFraming();
      expect(m.cmd, FretCommand.brightness);
      expect(m.params, <int>[(500 >> 8) & 0xFF, 500 & 0xFF, 0, 0, 0, 0]);
      expect(m.length, 6);
    });

    test('boundary: 0 accepted', () async {
      await led.setBrightness(device, 0);
      expect(lastFrameOf(ble).params, <int>[0, 0, 0, 0, 0, 0]);
    });

    test('boundary: 1000 accepted', () async {
      await led.setBrightness(device, 1000);
      expect(lastFrameOf(ble).params, <int>[0x03, 0xE8, 0, 0, 0, 0]);
    });

    test('rejects 1001', () async {
      expect(() => led.setBrightness(device, 1001), throwsA(isA<FretSparkException>()));
    });

    test('rejects negative', () async {
      expect(() => led.setBrightness(device, -1), throwsA(isA<FretSparkException>()));
    });
  });

  group('FretLED.setColor (0x04, HSL)', () {
    test('encodes hue and saturation as uint16 big-endian', () async {
      await led.setColor(device, const FretHsl(180, 800));
      final m = lastFrameOf(ble);
      m.expectValidFraming();
      expect(m.cmd, FretCommand.color);
      expect(m.params, <int>[
        (180 >> 8) & 0xFF, 180 & 0xFF, // hue
        (800 >> 8) & 0xFF, 800 & 0xFF, // saturation
        0, 0,
      ]);
    });

    test('always emits selectionMask [] cleanup frame first', () async {
      await led.setColor(device, const FretHsl(0, 0));
      expect(ble.writtenFrames.length, 2);
      expect(ble.writtenFrames[0][1], FretCommand.selectionMask);
      expect(ble.writtenFrames[0].sublist(3, 3), <int>[]);
      expect(ble.writtenFrames[1][1], FretCommand.color);
    });

    test('emits group-channel cleanup too when in group context (3 frames)',
        () async {
      await led.applyGroupMap(device, 0, <int>[1, 1, 1]);
      ble.writtenFrames.clear();

      await led.setColor(device, const FretHsl(0, 0));

      // 1) groupMap [] cleanup
      // 2) selectionMask [] cleanup
      // 3) color payload
      expect(ble.writtenFrames.length, 3);
      expect(ble.writtenFrames[0][1], FretCommand.groupMap);
      expect(ble.writtenFrames[1][1], FretCommand.selectionMask);
      expect(ble.writtenFrames[2][1], FretCommand.color);
    });
  });

  group('FretLED.fillColor (0x15)', () {
    test('interleaves color bytes with zero placeholders', () async {
      await led.fillColor(device, FretColor.red);
      final m = lastFrameOf(ble);
      m.expectValidFraming();
      expect(m.cmd, FretCommand.fillColor);
      expect(m.params, <int>[0, 255, 0, 0, 0, 0]);
    });

    test('white fills with all channels at 255', () async {
      await led.fillColor(device, FretColor.white);
      expect(lastFrameOf(ble).params, <int>[0, 255, 0, 255, 0, 255]);
    });

    test('emits selectionMask [] cleanup frame first', () async {
      await led.fillColor(device, FretColor.blue);
      expect(ble.writtenFrames.length, 2);
      expect(ble.writtenFrames[0][1], FretCommand.selectionMask);
      expect(ble.writtenFrames[1][1], FretCommand.fillColor);
    });
  });

  group('FretLED.setMode (0x06)', () {
    test('encodes modeId as uint16 big-endian', () async {
      await led.setMode(device, 5);
      final m = lastFrameOf(ble);
      m.expectValidFraming();
      expect(m.cmd, FretCommand.mode);
      expect(m.params, <int>[0, 5]);
    });

    test('modeId=128 (AI rhythm range) rejected (out of 1..117)', () async {
      // P1-5 boundary validation: built-in modes are 1..117. Values
      // outside that range (including the AI rhythm range 124-135) now
      // throw FretSparkException instead of being sent raw.
      expect(
        () => led.setMode(device, 128),
        throwsA(isA<FretSparkException>()),
      );
    });

    test('clears selection before mode change', () async {
      await led.setMode(device, 2);
      expect(ble.writtenFrames[0][1], FretCommand.selectionMask);
      expect(ble.writtenFrames[1][1], FretCommand.mode);
    });
  });

  group('FretLED.setSpeed (0x08)', () {
    test('sends single-byte speed value', () async {
      await led.setSpeed(device, 120);
      final m = lastFrameOf(ble);
      m.expectValidFraming();
      expect(m.cmd, FretCommand.speed);
      expect(m.params, <int>[120]);
    });

    test('boundary: 0 and 255 accepted', () async {
      await led.setSpeed(device, 0);
      expect(lastFrameOf(ble).params, <int>[0]);
      await led.setSpeed(device, 255);
      expect(lastFrameOf(ble).params, <int>[255]);
    });

    test('rejects 256', () async {
      expect(() => led.setSpeed(device, 256), throwsA(isA<ArgumentError>()));
    });
  });

  group('FretLED.setDirection (0x07)', () {
    test('forward=0, reverse=1', () async {
      await led.setDirection(device, 0);
      expect(lastFrameOf(ble).params, <int>[0]);
      await led.setDirection(device, 1);
      expect(lastFrameOf(ble).params, <int>[1]);
    });

    test('rejects 2 and -1', () async {
      expect(() => led.setDirection(device, 2), throwsA(isA<ArgumentError>()));
      expect(() => led.setDirection(device, -1), throwsA(isA<ArgumentError>()));
    });
  });

  group('FretLED.setAllOn / clearAll', () {
    test('setAllOn emits selectionMask [] + selectionMask [] (from setMode) + mode 2',
        () async {
      await led.setAllOn(device);
      // 1) _clearSelection -> selectionMask []
      // 2) setMode -> _clearSelection again -> selectionMask []
      // 3) setMode -> mode [0, 2]
      expect(ble.writtenFrames.length, 3);
      expect(ble.writtenFrames[0][1], FretCommand.selectionMask);
      expect(ble.writtenFrames[1][1], FretCommand.selectionMask);
      expect(ble.writtenFrames[2][1], FretCommand.mode);
      expect(ble.writtenFrames[2].sublist(3, 5), <int>[0, 2]);
    });

    test('clearAll emits selectionMask [] + batchBegin [0] + batchEnd []', () async {
      await led.clearAll(device);
      // 1) _clearSelection -> selectionMask []
      // 2) batchBegin [0]
      // 3) batchEnd []
      expect(ble.writtenFrames.length, 3);
      expect(ble.writtenFrames[0][1], FretCommand.selectionMask);
      expect(ble.writtenFrames[1][1], FretCommand.batchBegin);
      expect(ble.writtenFrames[1].sublist(3, 4), <int>[0]);
      expect(ble.writtenFrames[2][1], FretCommand.batchEnd);
      expect(ble.writtenFrames[2].sublist(3, 3), <int>[]);
    });
  });

  group('FretLED.lockSelection / unlockSelection (0x18)', () {
    test('empty list sends empty payload (clears mask)', () async {
      await led.lockSelection(device, <int>[]);
      expect(lastFrameOf(ble).cmd, FretCommand.selectionMask);
      expect(lastFrameOf(ble).params, <int>[]);
    });

    test('non-empty list sends 50-byte bitmap', () async {
      // LED 0 and LED 9 -> bits 0 and 1 in bytes 0 and 1.
      await led.lockSelection(device, <int>[0, 9]);
      final m = lastFrameOf(ble);
      expect(m.cmd, FretCommand.selectionMask);
      expect(m.length, 50);
      expect(m.params[0], 0x01); // bit 0 set (LED 0)
      expect(m.params[1], 0x02); // bit 1 set (LED 9)
    });

    test('LED indices >=400 are silently skipped (out of bitmap range)',
        () async {
      await led.lockSelection(device, <int>[0, 400, 500]);
      expect(lastFrameOf(ble).length, 50);
      expect(lastFrameOf(ble).params[0], 0x01); // only LED 0 set
    });

    test('unlockSelection sends empty payload', () async {
      await led.unlockSelection(device);
      expect(lastFrameOf(ble).params, <int>[]);
    });
  });

  group('FretLED.lightNote (0x22 single)', () {
    test('encodes [0x01, idx, r, g, b] for string 0 / fret 0', () async {
      await led.lightNote(device, const FretNote(string: 0, fret: 0, color: FretColor.red));
      final m = lastFrameOf(ble);
      m.expectValidFraming();
      expect(m.cmd, FretCommand.learningLed);
      expect(m.params, <int>[0x01, 0, 255, 0, 0]);
    });

    test('string 2 / fret 3 -> idx = 3*6 + 2 = 20', () async {
      await led.lightNote(
        device,
        const FretNote(string: 2, fret: 3, color: FretColor.green),
      );
      expect(lastFrameOf(ble).params, <int>[0x01, 20, 0, 255, 0]);
    });

    test('out-of-bounds fret (>maxFret) produces no frame', () async {
      // default maxFret = (90 ~/ 6) - 1 = 14; fret=15 is out of range
      await led.lightNote(
        device,
        const FretNote(string: 0, fret: 15, color: FretColor.white),
      );
      expect(ble.writtenFrames, isEmpty,
          reason: 'out-of-bounds note should produce no frame');
    });
  });

  group('FretLED.lightNotes (single-packet path for count <= 59)', () {
    test('3 notes -> single 0x22 frame with [0x02, count, idx, r, g, b, ...]',
        () async {
      final notes = <FretNote>[
        const FretNote(string: 0, fret: 0, color: FretColor.red),
        const FretNote(string: 1, fret: 1, color: FretColor.green),
        const FretNote(string: 2, fret: 2, color: FretColor.blue),
      ];
      await led.lightNotes(device, notes);

      // Single-packet path (count=3 <= 59): one learningLed frame.
      final learningFrames = framesForCmd(FretCommand.learningLed);
      expect(learningFrames.length, 1);
      final m = FrameMatcher(learningFrames[0]);
      m.expectValidFraming();
      expect(m.params[0], 0x02); // sub-cmd = multi-write
      expect(m.params[1], 3); // count = 3
      // First pixel: idx = 0*6 + 0 = 0, color red
      expect(m.params[2], 0); // idx
      expect(m.params[3], 255); // r
      expect(m.params[4], 0); // g
      expect(m.params[5], 0); // b
      // Second pixel: idx = 1*6 + 1 = 7, color green
      expect(m.params[6], 7);
      expect(m.params[7], 0);
      expect(m.params[8], 255);
      expect(m.params[9], 0);
      // Third pixel: idx = 2*6 + 2 = 14, color blue
      expect(m.params[10], 14);
      expect(m.params[11], 0);
      expect(m.params[12], 0);
      expect(m.params[13], 255);

      // No batch frames should be emitted (single-packet path).
      expect(framesForCmd(FretCommand.batchBegin), isEmpty);
      expect(framesForCmd(FretCommand.batchData), isEmpty);
      expect(framesForCmd(FretCommand.batchEnd), isEmpty);
    });

    test('empty list produces no frames', () async {
      await led.lightNotes(device, <FretNote>[]);
      expect(ble.writtenFrames, isEmpty);
    });

    test('duplicates by LED index are deduped (last write wins)', () async {
      final notes = <FretNote>[
        const FretNote(string: 0, fret: 0, color: FretColor.red),
        const FretNote(string: 0, fret: 0, color: FretColor.blue), // same LED
      ];
      await led.lightNotes(device, notes);
      // Deduped to count=1; blue wins.
      final learningFrames = framesForCmd(FretCommand.learningLed);
      expect(learningFrames.length, 1);
      final m = FrameMatcher(learningFrames[0]);
      expect(m.params[0], 0x02);
      expect(m.params[1], 1); // count = 1 (deduped)
      expect(m.params[2], 0); // idx = 0
      expect(m.params[3], 0); // r (blue)
      expect(m.params[4], 0); // g
      expect(m.params[5], 255); // b (blue wins)
    });

    test('>59 LEDs switches to batched 0x1C/0x16/0x1D path', () async {
      // Build 60 unique LED notes (well under maxFret=14 -> 6 strings * 15 frets = 90 LEDs).
      final notes = <FretNote>[];
      for (int s = 0; s < 6 && notes.length < 60; s++) {
        for (int f = 0; f <= 14 && notes.length < 60; f++) {
          notes.add(FretNote(string: s, fret: f, color: FretColor.white));
        }
      }
      expect(notes.length, 60);

      await led.lightNotes(device, notes);
      // Batch path: batchBegin + batchData* + batchEnd
      expect(framesForCmd(FretCommand.batchBegin), isNotEmpty);
      expect(framesForCmd(FretCommand.batchData), isNotEmpty);
      expect(framesForCmd(FretCommand.batchEnd), isNotEmpty);
    });
  });

  group('FretLED.clearLearningLEDs (0x22 with [0x00])', () {
    test('sends learningLed [0x00]', () async {
      await led.clearLearningLEDs(device);
      final m = lastFrameOf(ble);
      m.expectValidFraming();
      expect(m.cmd, FretCommand.learningLed);
      expect(m.params, <int>[0x00]);
    });
  });

  group('FretLED.showChord', () {
    test('C major emits clearLearningLEDs + single-packet lightNotes', () async {
      await led.showChord(device, root: NoteName.c, chordType: 'maj');
      // 1) clearLearningLEDs: learningLed [0x00]
      // 2) lightNotes: single learningLed [0x02, count, ...] (C maj has <=6 fingers)
      final learningFrames = framesForCmd(FretCommand.learningLed);
      expect(learningFrames.length, 2);
      expect(FrameMatcher(learningFrames[0]).params, <int>[0x00]);
      expect(FrameMatcher(learningFrames[1]).params[0], 0x02); // multi-write sub-cmd
    });

    test('unknown chord throws ArgumentError', () async {
      expect(
        () => led.showChord(device, root: NoteName.c, chordType: 'aug-dom13'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('FretLED.showScale', () {
    test('C major scale emits clearLearningLEDs + lightNotes', () async {
      await led.showScale(device, root: NoteName.c, scale: ScaleType.major);
      // 1) clearLearningLEDs: learningLed [0x00]
      // 2) lightNotes: single or batched depending on count (one octave on each string)
      expect(framesForCmd(FretCommand.learningLed), isNotEmpty);
    });

    test('chromatic scale lights more LEDs than pentatonic', () async {
      // Sanity check: chromatic has 12 intervals per octave, pentatonic has 5.
      // LightNotes pixel count differs -> single-packet count byte differs.
      await led.showScale(device, root: NoteName.c, scale: ScaleType.chromatic);
      final chromaticCount = _lightNoteCount(ble);

      ble.writtenFrames.clear();
      await led.showScale(
          device, root: NoteName.c, scale: ScaleType.majorPentatonic);
      final pentatonicCount = _lightNoteCount(ble);

      expect(chromaticCount, greaterThan(pentatonicCount));
    });
  });

  group('FretLED.setMusicMode (0x09)', () {
    test('metronome with no extra params sends [mode.code]', () async {
      await led.setMusicMode(device, MusicMode.metronome);
      final m = lastFrameOf(ble);
      m.expectValidFraming();
      expect(m.cmd, FretCommand.musicMode);
      expect(m.params, <int>[0x01]); // metronome.code = 0x01
    });

    test('metronome with extra params sends [code, ...params]', () async {
      await led.setMusicMode(
        device,
        MusicMode.metronome,
        extraParams: <int>[0x78, 0x00, 0x04], // 120 BPM, 4/4
      );
      expect(lastFrameOf(ble).params, <int>[0x01, 0x78, 0x00, 0x04]);
    });

    test('bass mode code = 0x04', () async {
      await led.setMusicMode(device, MusicMode.bass);
      expect(lastFrameOf(ble).params, <int>[0x04]);
    });
  });

  group('FretLED.setMicSource (0x0F)', () {
    test('appMic -> [0x00]', () async {
      await led.setMicSource(device, MicSource.appMic);
      expect(lastFrameOf(ble).params, <int>[0x00]);
    });

    test('localMic -> [0x01]', () async {
      await led.setMicSource(device, MicSource.localMic);
      expect(lastFrameOf(ble).params, <int>[0x01]);
    });

    test('vibration -> [0x06]', () async {
      await led.setMicSource(device, MicSource.vibration);
      expect(lastFrameOf(ble).params, <int>[0x06]);
    });

    test('off -> [0xFF]', () async {
      await led.setMicSource(device, MicSource.off);
      expect(lastFrameOf(ble).params, <int>[0xFF]);
    });
  });

  group('FretLED.setVoiceMode (0x11)', () {
    test('on -> [0x00], off -> [0xFF]', () async {
      await led.setVoiceMode(device, on: true);
      expect(lastFrameOf(ble).params, <int>[0x00]);
      await led.setVoiceMode(device, on: false);
      expect(lastFrameOf(ble).params, <int>[0xFF]);
    });
  });

  group('FretLED.setVoiceSensitivity (0x12)', () {
    test('sends single-byte value', () async {
      await led.setVoiceSensitivity(device, 128);
      expect(lastFrameOf(ble).params, <int>[128]);
    });

    test('boundary: 0 and 255 accepted', () async {
      await led.setVoiceSensitivity(device, 0);
      expect(lastFrameOf(ble).params, <int>[0]);
      await led.setVoiceSensitivity(device, 255);
      expect(lastFrameOf(ble).params, <int>[255]);
    });

    test('rejects 256 and -1', () async {
      expect(() => led.setVoiceSensitivity(device, 256), throwsA(isA<ArgumentError>()));
      expect(() => led.setVoiceSensitivity(device, -1), throwsA(isA<ArgumentError>()));
    });
  });

  group('FretLED.injectEnergy (0x26)', () {
    test('encodes uint16 big-endian', () async {
      await led.injectEnergy(device, 30000); // 0x7530
      final m = lastFrameOf(ble);
      m.expectValidFraming();
      expect(m.cmd, FretCommand.energyInject);
      expect(m.params, <int>[0x75, 0x30]);
    });

    test('boundary: 0 and 65535 accepted', () async {
      await led.injectEnergy(device, 0);
      expect(lastFrameOf(ble).params, <int>[0x00, 0x00]);
      await led.injectEnergy(device, 0xFFFF);
      expect(lastFrameOf(ble).params, <int>[0xFF, 0xFF]);
    });

    test('rejects 65536 and -1', () async {
      expect(() => led.injectEnergy(device, 0x10000), throwsA(isA<ArgumentError>()));
      expect(() => led.injectEnergy(device, -1), throwsA(isA<ArgumentError>()));
    });
  });

  group('FretLED.applyGroupFrame (high-level group API)', () {
    test('empty assignment clears group map and exits group mode', () async {
      await led.applyGroupFrame(
        device,
        groupAssignments: <int, int>{},
        groupColors: <int, FretColor>{},
      );
      // Emits exactly one frame: groupMap [] (clear).
      expect(ble.writtenFrames.length, 1);
      expect(ble.writtenFrames[0][1], FretCommand.groupMap);
      expect(ble.writtenFrames[0].sublist(3, 3), <int>[]);
    });

    test('2-group assignment emits batchBegin + groupMap + 2x groupColor + batchEnd',
        () async {
      await led.applyGroupFrame(
        device,
        groupAssignments: <int, int>{0: 1, 1: 1, 6: 2},
        groupColors: <int, FretColor>{
          1: FretColor.red,
          2: FretColor.green,
        },
      );

      // 1) batchBegin [0] (force group state 4)
      // 2) groupMap [0, 1, 1, 0, 0, 0, 0, 2]  (indices 0..6)
      // 3) groupColor [1, 255, 0, 0]
      // 4) groupColor [2, 0, 255, 0]
      // 5) batchEnd []
      final cmds = ble.writtenFrames.map((f) => f[1]).toList();
      expect(cmds[0], FretCommand.batchBegin);
      expect(cmds[1], FretCommand.groupMap);
      expect(cmds[2], FretCommand.groupColor);
      expect(cmds[3], FretCommand.groupColor);
      expect(cmds[4], FretCommand.batchEnd);

      // groupMap payload: baseIdx=0, then groupIds for indices 0..6
      final gmParams = FrameMatcher(ble.writtenFrames[1]).params;
      expect(gmParams[0], 0); // baseIdx
      expect(gmParams.length, 8); // 1 baseIdx + 7 groupIds
      expect(gmParams[1], 1); // idx 0 -> group 1
      expect(gmParams[2], 1); // idx 1 -> group 1
      expect(gmParams[7], 2); // idx 6 -> group 2

      // groupColor payloads (order may vary; just check both exist as
      // sets of strings to bypass List<int> reference equality).
      final colorPayloads = ble.framesFor(FretCommand.groupColor)
          .map((f) => f.sublist(3, 7).join(','))
          .toSet();
      expect(colorPayloads.length, 2);
      expect(colorPayloads, contains('1,255,0,0'));
      expect(colorPayloads, contains('2,0,255,0'));
    });
  });

  group('FretLED.setGroupColor (low-level 0x1A)', () {
    test('sends [groupId, r, g, b]', () async {
      await led.setGroupColor(device, 5, FretColor.cyan);
      final m = lastFrameOf(ble);
      m.expectValidFraming();
      expect(m.cmd, FretCommand.groupColor);
      expect(m.params, <int>[5, 0, 255, 255]);
    });

    test('rejects groupId=256', () async {
      expect(() => led.setGroupColor(device, 256, FretColor.white),
          throwsA(isA<ArgumentError>()));
    });
  });

  group('FretLED.applyGroupMap / clearGroupMap (0x19)', () {
    test('applyGroupMap sends [baseIdx, ...groupIds]', () async {
      await led.applyGroupMap(device, 10, <int>[1, 2, 3]);
      final m = lastFrameOf(ble);
      m.expectValidFraming();
      expect(m.cmd, FretCommand.groupMap);
      expect(m.params, <int>[10, 1, 2, 3]);
    });

    test('rejects baseIdx >=400', () async {
      expect(() => led.applyGroupMap(device, 400, <int>[1]),
          throwsA(isA<ArgumentError>()));
    });

    test('rejects groupId >255', () async {
      expect(() => led.applyGroupMap(device, 0, <int>[256]),
          throwsA(isA<ArgumentError>()));
    });

    test('clearGroupMap sends empty payload', () async {
      await led.clearGroupMap(device);
      expect(lastFrameOf(ble).cmd, FretCommand.groupMap);
      expect(lastFrameOf(ble).params, <int>[]);
    });
  });

  group('FretLED.flushGroupImmediate (0x17)', () {
    test('sends empty payload', () async {
      await led.flushGroupImmediate(device);
      final m = lastFrameOf(ble);
      m.expectValidFraming();
      expect(m.cmd, FretCommand.groupEnd);
      expect(m.params, <int>[]);
    });
  });

  group('FretLED.setDiyModeList / queryDiyModeList (0x29 / 0x2A)', () {
    test('sends [count, ...modeIds]', () async {
      await led.setDiyModeList(device, <int>[1, 5, 10, 117]);
      final m = lastFrameOf(ble);
      m.expectValidFraming();
      expect(m.cmd, FretCommand.setDiyModeList);
      expect(m.params, <int>[4, 1, 5, 10, 117]);
    });

    test('empty list sends [0]', () async {
      await led.setDiyModeList(device, <int>[]);
      expect(lastFrameOf(ble).params, <int>[0]);
    });

    test('rejects modeId=0 (must be 1..117)', () async {
      expect(() => led.setDiyModeList(device, <int>[0]),
          throwsA(isA<FretSparkException>()));
    });

    test('rejects modeId=118 (out of built-in range)', () async {
      expect(() => led.setDiyModeList(device, <int>[118]),
          throwsA(isA<FretSparkException>()));
    });

    test('queryDiyModeList sends empty payload', () async {
      await led.queryDiyModeList(device);
      final m = lastFrameOf(ble);
      expect(m.cmd, FretCommand.queryDiyModeList);
      expect(m.params, <int>[]);
    });
  });

  group('FretLED.setLedIndexMode (0x27)', () {
    test('reversed=false -> [0], reversed=true -> [1]', () async {
      await led.setLedIndexMode(device, reversed: false);
      expect(lastFrameOf(ble).params, <int>[0]);
      await led.setLedIndexMode(device, reversed: true);
      expect(lastFrameOf(ble).params, <int>[1]);
    });
  });

  group('Group-channel state machine invariants', () {
    test('setGroupColor marks device as in-group; next setColor emits cleanup',
        () async {
      // Pre-condition: setColor emits 2 frames (selectionMask + color).
      await led.setColor(device, const FretHsl(0, 0));
      expect(ble.writtenFrames.length, 2);
      ble.writtenFrames.clear();

      // Enter group context via setGroupColor (calls _markGroupActive).
      await led.setGroupColor(device, 1, FretColor.red);
      ble.writtenFrames.clear();

      // Now setColor should emit 3 frames: groupMap [] + selectionMask [] + color.
      await led.setColor(device, const FretHsl(0, 0));
      expect(ble.writtenFrames.length, 3);
      expect(ble.writtenFrames[0][1], FretCommand.groupMap);
      expect(ble.writtenFrames[1][1], FretCommand.selectionMask);
      expect(ble.writtenFrames[2][1], FretCommand.color);
    });

    test('clearGroupMap resets state; subsequent setColor does NOT emit cleanup',
        () async {
      await led.setGroupColor(device, 1, FretColor.red);
      await led.clearGroupMap(device);
      ble.writtenFrames.clear();

      await led.setColor(device, const FretHsl(0, 0));
      // Only selectionMask [] + color (no groupMap cleanup).
      expect(ble.writtenFrames.length, 2);
      expect(ble.writtenFrames[0][1], FretCommand.selectionMask);
      expect(ble.writtenFrames[1][1], FretCommand.color);
    });

    test('applyGroupFrame with non-empty assignment is idempotent on entry',
        () async {
      // applyGroupFrame calls _forceGroupState4 which is idempotent.
      // The first call should emit batchBegin [0].
      await led.applyGroupFrame(
        device,
        groupAssignments: <int, int>{0: 1},
        groupColors: <int, FretColor>{1: FretColor.red},
      );
      final firstBatchBeginCount = framesForCmd(FretCommand.batchBegin).length;
      expect(firstBatchBeginCount, 1);

      ble.writtenFrames.clear();

      // Second applyGroupFrame should NOT re-emit batchBegin (idempotent).
      await led.applyGroupFrame(
        device,
        groupAssignments: <int, int>{0: 1},
        groupColors: <int, FretColor>{1: FretColor.red},
      );
      final secondBatchBeginCount = framesForCmd(FretCommand.batchBegin).length;
      expect(secondBatchBeginCount, 0,
          reason: '_forceGroupState4 should be idempotent until cleared');
    });
  });
}

/// Helper for showScale chromatic-vs-pentatonic test:
/// returns the total LED count from the most recent lightNotes call.
///
/// - Single-packet path: one learningLed [0x02, count, ...] frame;
///   count = params[1].
/// - Batched path: multiple batchData [seq, count, ...] frames;
///   total = sum of params[1] across all batchData frames.
int _lightNoteCount(FakeBleDevice ble) {
  final single = ble.framesFor(FretCommand.learningLed)
      .where((f) => f[3] == 0x02) // multi-write sub-cmd
      .toList();
  if (single.isNotEmpty) {
    // Use the last single-packet frame (a scale test issues exactly one).
    return FrameMatcher(single.last).params[1];
  }
  // Batched path: sum batchData count bytes.
  return ble.framesFor(FretCommand.batchData)
      .map((f) => FrameMatcher(f).params[1])
      .fold(0, (int a, int b) => a + b);
}
