// ignore_for_file: invalid_use_of_visible_for_testing_member
// Unit tests for the FretLED methods added in SDK 1.4.0:
//   - setLinearLayout (0x02)
//   - setLedCount    (0x03)
//   - setMusicStyle  (0x1B)
//   - setTimer       (0x0D)
//   - fillRange      (0x14)
//
// These tests assert on the encoded protocol frame captured by
// FakeBleDevice, so they verify both the command code and the exact
// payload layout the SDK puts on the wire.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fretspark_sdk/src/api/fret_led.dart';
import 'package:fretspark_sdk/src/core/commands.dart';
import 'package:fretspark_sdk/src/core/fret_spark_exception.dart';
import 'package:fretspark_sdk/src/models/fret_color.dart';
import 'package:fretspark_sdk/src/models/fret_device.dart';

import 'helpers/fake_ble_device.dart';

void main() {
  // Each test needs its own fresh FretLED + FakeBleDevice. The helper
  // rebuilds them on demand so a frame leak in one test cannot pollute
  // another.
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

  group('FretLED.setLinearLayout (0x02)', () {
    test('linear=true sends [0x01]', () async {
      await led.setLinearLayout(device, linear: true);
      final m = lastFrameOf(ble);
      m.expectValidFraming();
      expect(m.cmd, FretCommand.linearLayout);
      expect(m.params, <int>[0x01]);
    });

    test('linear=false sends [0x00]', () async {
      await led.setLinearLayout(device, linear: false);
      expect(lastFrameOf(ble).params, <int>[0x00]);
    });
  });

  group('FretLED.setLedCount (0x03)', () {
    test('sends uint16 big-endian payload', () async {
      await led.setLedCount(device, 126); // 21-fret board
      final m = lastFrameOf(ble);
      m.expectValidFraming();
      expect(m.cmd, FretCommand.ledCount);
      expect(m.params, <int>[(126 >> 8) & 0xFF, 126 & 0xFF]);
    });

    test('boundary: count=1 accepted', () async {
      await led.setLedCount(device, 1);
      expect(lastFrameOf(ble).params, <int>[0x00, 0x01]);
    });

    test('boundary: count=65535 accepted', () async {
      await led.setLedCount(device, 0xFFFF);
      expect(lastFrameOf(ble).params, <int>[0xFF, 0xFF]);
    });

    test('rejects count=0', () async {
      expect(
        () => led.setLedCount(device, 0),
        throwsA(isA<ArgumentError>()),
      );
      expect(ble.writtenFrames, isEmpty, reason: 'no frame should be sent on validation failure');
    });

    test('rejects count>65535', () async {
      expect(
        () => led.setLedCount(device, 0x10000),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('FretLED.setMusicStyle (0x1B)', () {
    test('sends [styleId]', () async {
      await led.setMusicStyle(device, 42);
      final m = lastFrameOf(ble);
      m.expectValidFraming();
      expect(m.cmd, FretCommand.musicStyle);
      expect(m.params, <int>[42]);
    });

    test('boundary: styleId=0 accepted', () async {
      await led.setMusicStyle(device, 0);
      expect(lastFrameOf(ble).params, <int>[0]);
    });

    test('boundary: styleId=99 accepted (firmware resets >=100)', () async {
      await led.setMusicStyle(device, 99);
      expect(lastFrameOf(ble).params, <int>[99]);
    });

    test('rejects styleId=100 (firmware would reset to 0)', () async {
      expect(
        () => led.setMusicStyle(device, 100),
        throwsA(isA<FretSparkException>()),
      );
    });

    test('rejects negative styleId', () async {
      expect(
        () => led.setMusicStyle(device, -1),
        throwsA(isA<FretSparkException>()),
      );
    });
  });

  group('FretLED.setTimer (0x0D)', () {
    test('scheduled power-on: [slot=0, onOff=1, h, m, s, 0x00]', () async {
      await device.setRtcTime(DateTime(2026, 1, 1, 0, 0, 0));
      await led.setTimer(
        device,
        on: true,
        hour: 7,
        minute: 30,
        second: 0,
      );
      final m = lastFrameOf(ble);
      m.expectValidFraming();
      expect(m.cmd, FretCommand.timer);
      expect(m.params, <int>[0x00, 0x01, 7, 30, 0, 0x00]);
    });

    test('scheduled power-off: onOff=0', () async {
      await device.setRtcTime(DateTime(2026, 1, 1, 0, 0, 0));
      await led.setTimer(
        device,
        on: false,
        hour: 23,
        minute: 0,
        second: 0,
      );
      expect(lastFrameOf(ble).params, <int>[0x00, 0x00, 23, 0, 0, 0x00]);
    });

    test('custom slot', () async {
      await device.setRtcTime(DateTime(2026, 1, 1, 0, 0, 0));
      await led.setTimer(
        device,
        on: true,
        hour: 12,
        minute: 30,
        second: 45,
        slot: 2,
      );
      expect(lastFrameOf(ble).params, <int>[2, 0x01, 12, 30, 45, 0x00]);
    });

    test('rejects when RTC not synced (throws FretSparkException)', () async {
      // No setRtcTime() call: device.isRtcSynced is false.
      expect(
        () => led.setTimer(
          device,
          on: true,
          hour: 7,
          minute: 30,
          second: 0,
        ),
        throwsA(isA<FretSparkException>()),
      );
    });

    test('rejects hour=24', () async {
      await device.setRtcTime(DateTime(2026, 1, 1, 0, 0, 0));
      expect(
        () => led.setTimer(device, on: true, hour: 24, minute: 0, second: 0),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects minute=60', () async {
      await device.setRtcTime(DateTime(2026, 1, 1, 0, 0, 0));
      expect(
        () => led.setTimer(device, on: true, hour: 0, minute: 60, second: 0),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects second=60', () async {
      await device.setRtcTime(DateTime(2026, 1, 1, 0, 0, 0));
      expect(
        () => led.setTimer(device, on: true, hour: 0, minute: 0, second: 60),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects negative slot', () async {
      await device.setRtcTime(DateTime(2026, 1, 1, 0, 0, 0));
      expect(
        () => led.setTimer(
          device,
          on: true,
          hour: 0,
          minute: 0,
          second: 0,
          slot: -1,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('FretLED.fillRange (0x14)', () {
    test('single LED: [start, r, g, b]', () async {
      await led.fillRange(
        device,
        startIndex: 5,
        colors: <FretColor>[FretColor.red],
      );
      final m = lastFrameOf(ble);
      m.expectValidFraming();
      expect(m.cmd, FretCommand.fillRange);
      expect(m.params, <int>[5, 255, 0, 0]);
    });

    test('multiple LEDs: contiguous RGB list', () async {
      await led.fillRange(
        device,
        startIndex: 10,
        colors: <FretColor>[
          FretColor.red,
          FretColor.green,
          FretColor.blue,
        ],
      );
      expect(
        lastFrameOf(ble).params,
        <int>[10, 255, 0, 0, 0, 255, 0, 0, 0, 255],
      );
    });

    test('boundary: max 79 LEDs accepted in one call', () async {
      final colors = List<FretColor>.filled(79, FretColor.white);
      await led.fillRange(device, startIndex: 0, colors: colors);
      expect(ble.writtenFrames.length, 1);
      expect(lastFrameOf(ble).length, 1 + 79 * 3);
    });

    test('rejects empty colors list', () async {
      expect(
        () => led.fillRange(device, startIndex: 0, colors: <FretColor>[]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects 80 LEDs in one call (must split)', () async {
      final colors = List<FretColor>.filled(80, FretColor.white);
      expect(
        () => led.fillRange(device, startIndex: 0, colors: colors),
        throwsA(isA<FretSparkException>()),
      );
    });

    test('rejects startIndex=256 (out of byte range)', () async {
      expect(
        () => led.fillRange(
          device,
          startIndex: 256,
          colors: <FretColor>[FretColor.red],
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('two consecutive fillRange calls produce two frames', () async {
      await led.fillRange(device, startIndex: 0, colors: <FretColor>[FretColor.red]);
      await led.fillRange(device, startIndex: 3, colors: <FretColor>[FretColor.green]);
      expect(ble.framesFor(FretCommand.fillRange).length, 2);
    });
  });
}
