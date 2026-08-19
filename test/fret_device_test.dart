// ignore_for_file: invalid_use_of_visible_for_testing_member
// Unit tests for the FretDevice methods added in SDK 1.4.0:
//   - setRtcTime     (0x0B)
//   - queryVersion   (0x1E)
//   - queryLedConfig (0x1F)
//   - queryStatus    (0x0C)

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:fretspark_sdk/src/core/commands.dart';
import 'package:fretspark_sdk/src/models/fret_device.dart';
import 'package:fretspark_sdk/src/models/fret_notify.dart';

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

  group('FretDevice.setRtcTime (0x0B)', () {
    test('encodes DateTime as [yyH, yyL, MM, dd, HH, mm, ss]', () async {
      // 2026-08-18 14:30:45
      final time = DateTime(2026, 8, 18, 14, 30, 45);
      await device.setRtcTime(time);

      final m = lastFrameOf(ble);
      m.expectValidFraming();
      expect(m.cmd, FretCommand.rtcTime);
      expect(m.params, <int>[
        (2026 >> 8) & 0xFF, // yyH
        2026 & 0xFF,        // yyL
        8,                  // MM
        18,                 // dd
        14,                 // HH
        30,                 // mm
        45,                 // ss
      ]);
    });

    test('epoch boundary (year 2000)', () async {
      await device.setRtcTime(DateTime(2000, 1, 1, 0, 0, 0));
      expect(
        lastFrameOf(ble).params,
        <int>[(2000 >> 8) & 0xFF, 2000 & 0xFF, 1, 1, 0, 0, 0],
      );
    });

    test('far-future date (year 65535 max)', () async {
      await device.setRtcTime(DateTime(9999, 12, 31, 23, 59, 59));
      final p = lastFrameOf(ble).params;
      expect(p[0] << 8 | p[1], 9999);
      expect(p[2], 12);
      expect(p[3], 31);
      expect(p[4], 23);
      expect(p[5], 59);
      expect(p[6], 59);
    });

    test('full byte layout matches firmware comment in commands.dart', () async {
      // The firmware comment in commands.dart says:
      //   payload = [yearH, yearL, month, day, hour, minute, second] (7 bytes)
      // Verify the actual frame LEN matches that comment.
      await device.setRtcTime(DateTime(2026, 8, 18, 14, 30, 45));
      expect(lastFrameOf(ble).length, 7);
    });
  });

  group('FretDevice.queryVersion (0x1E)', () {
    test('sends empty payload', () async {
      await device.queryVersion();
      final m = lastFrameOf(ble);
      m.expectValidFraming();
      expect(m.cmd, FretCommand.queryVersion);
      expect(m.params, <int>[]);
      expect(m.length, 0);
    });
  });

  group('FretDevice.queryLedConfig (0x1F)', () {
    test('sends empty payload', () async {
      await device.queryLedConfig();
      final m = lastFrameOf(ble);
      m.expectValidFraming();
      expect(m.cmd, FretCommand.queryLedConfig);
      expect(m.params, <int>[]);
    });
  });

  group('FretDevice.queryStatus (0x0C)', () {
    test('sends [0x01] to trigger firmware status push', () async {
      await device.queryStatus();
      final m = lastFrameOf(ble);
      m.expectValidFraming();
      expect(m.cmd, FretCommand.queryStatus);
      expect(m.params, <int>[0x01]);
    });

    test('does NOT crash when no notify subscriber is attached', () async {
      // queryStatus triggers the firmware to push status via notify.
      // Without a subscriber, the notify is silently dropped. The query
      // method itself should still complete without throwing.
      await device.queryStatus();
      expect(ble.writtenFrames.length, 1);
    });
  });

  group('FretDevice.query* stream integration', () {
    test('queryVersion result is delivered via onFirmwareVersionQueried',
        () async {
      final completer = Completer<String>();
      late StreamSubscription sub;
      sub = device.onFirmwareVersionQueried.listen((v) {
        if (!completer.isCompleted) completer.complete(v.formatted);
      });

      // Simulate firmware pushing a version notify: [0xCC, 0x1E, 4, 3,1,3,4, 0xAA]
      ble.emitNotify(<int>[0xCC, 0x1E, 4, 3, 1, 3, 4, 0xAA]);

      final version = await completer.future.timeout(
        const Duration(seconds: 1),
        onTimeout: () => throw TimeoutException('no version notify'),
      );
      expect(version, '3.1.3.4');
      await sub.cancel();
    });

    test('queryLedConfig result is delivered via onLedCountChanged',
        () async {
      final completer = Completer<int>();
      late StreamSubscription sub;
      sub = device.onLedCountChanged.listen((count) {
        if (!completer.isCompleted) completer.complete(count);
      });

      // Firmware pushes LED count = 126 = 0x007E
      ble.emitNotify(<int>[0xCC, 0x1F, 2, 0x00, 0x7E, 0xAA]);

      final count = await completer.future.timeout(
        const Duration(seconds: 1),
        onTimeout: () => throw TimeoutException('no led-count notify'),
      );
      expect(count, 126);
      await sub.cancel();
    });

    test('queryStatus result is delivered via onBatteryChanged', () async {
      final completer = Completer<FretBattery>();
      late StreamSubscription sub;
      sub = device.onBatteryChanged.listen((b) {
        if (!completer.isCompleted) completer.complete(b);
      });

      // Firmware pushes battery: level=85, voltage=3700mV.
      // 3700 = 0x0E74. Bytes are big-endian: 0x0E, 0x74.
      ble.emitNotify(<int>[0xCC, 0x0A, 3, 85, 0x0E, 0x74, 0xAA]);

      final battery = await completer.future.timeout(
        const Duration(seconds: 1),
        onTimeout: () => throw TimeoutException('no battery notify'),
      );
      expect(battery.level, 85);
      expect(battery.voltageMv, 3700);
      await sub.cancel();
    });
  });

  group('FretDevice disposal', () {
    test('send after dispose throws StateError', () async {
      await device.dispose();
      expect(
        () => device.send(FretCommand.power, <int>[0x01]),
        throwsA(isA<StateError>()),
      );
    });

    test('queryVersion after dispose throws StateError', () async {
      await device.dispose();
      expect(
        () => device.queryVersion(),
        throwsA(isA<StateError>()),
      );
    });
  });
}
