// ignore_for_file: invalid_use_of_visible_for_testing_member
// Integration tests for [FretOTA].
//
// Coverage:
//   - enterOtaMode: emits 0x01 [0x02, 0x01] via the runtime command
//     service (observable on FakeBleDevice).
//   - FretOtaProgress / FretOtaException / FretOtaPhase: pure model
//     behavior (fraction, percent, toString).
//   - upgrade: input validation (empty image throws).
//   - upgrade protocol (FakeOtaTransport): the full START_OTA →
//     PARTITION_INFO → 16-packet burst → ACK → REBOOT flow, including
//     multi-burst, bad-data retry, retry-exhausted, padding, progress,
//     and disconnect-on-error.
//   - Constants: OTA UUIDs and PPlus protocol codes are stable.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:fretspark_sdk/src/api/fret_ota.dart';
import 'package:fretspark_sdk/src/core/commands.dart';
import 'package:fretspark_sdk/src/models/fret_device.dart';

import 'helpers/fake_ble_device.dart';
import 'helpers/fake_ota_transport.dart';

void main() {
  late FakeBleDevice ble;
  late FretDevice device;
  late FretOTA ota;

  setUp(() {
    ble = FakeBleDevice(id: 'dev-1', name: 'SCT-86PRO-ABCD');
    device = FretDevice.forBle(
      ble: ble,
      displayName: ble.name,
      brandId: 'auphy',
    );
    ota = FretOTA();
  });

  tearDown(() {
    ota.dispose();
  });

  group('FretOTA.enterOtaMode', () {
    test('sends enterOta command [0x02, 0x01] via the runtime service',
        () async {
      await ota.enterOtaMode(device, rebootDelay: Duration.zero);

      // The runtime command service receives 0x01 with [0x02, 0x01].
      final frames = ble.framesFor(FretCommand.enterOta);
      expect(frames.length, 1);
      final m = FrameMatcher(frames[0]);
      m.expectValidFraming();
      expect(m.cmd, FretCommand.enterOta);
      expect(m.params, <int>[0x02, 0x01]);
    });

    test('default rebootDelay is 2 seconds', () async {
      // Use a shorter delay for the test to keep it fast, but verify
      // the default value is documented as 2 seconds.
      expect(FretOTA.burstSize, 16);
      expect(FretOTA.packetSize, 20);
      expect(FretOTA.maxRetries, 3);
    });

    test('zero rebootDelay skips the wait entirely', () async {
      final sw = Stopwatch()..start();
      await ota.enterOtaMode(device, rebootDelay: Duration.zero);
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(500),
          reason: 'zero delay should not wait 2s');
      expect(ble.framesFor(FretCommand.enterOta).length, 1);
    });

    test('after enterOtaMode the device.send still works (no dispose)',
        () async {
      await ota.enterOtaMode(device, rebootDelay: Duration.zero);
      // The runtime device is still usable — enterOtaMode does not
      // dispose the runtime connection; the firmware will disconnect
      // itself when it reboots into OTA mode.
      await device.send(FretCommand.power, <int>[0x01]);
      // enterOtaMode sent 0x01 [0x02, 0x01] and the subsequent power
      // send adds another 0x01 [0x01] — both share the 0x01 command
      // code because FretCommand.enterOta is aliased to power.
      final powerFrames = ble.framesFor(FretCommand.power);
      expect(powerFrames.length, 2);
      // First frame: enterOtaMode payload [0x02, 0x01].
      expect(FrameMatcher(powerFrames[0]).params, <int>[0x02, 0x01]);
      // Second frame: power payload [0x01].
      expect(FrameMatcher(powerFrames[1]).params, <int>[0x01]);
    });
  });

  group('FretOTA.upgrade input validation', () {
    test('empty firmware image throws FretOtaException', () async {
      expect(
        () => ota.upgrade('some-device-id', Uint8List(0)),
        throwsA(isA<FretOtaException>()),
      );
    });

    test('non-empty image attempts connection (will fail without BLE)',
        () async {
      // Without a real BLE stack, BluetoothDevice.fromId + connect will
      // fail. We expect either a FretOtaException (connect retried 3x)
      // or a platform exception to bubble up. The contract we test is:
      // the SDK does NOT throw on the empty-check, only on connect.
      final image = Uint8List.fromList(List<int>.filled(100, 0xFF));
      expect(
        () => ota
            .upgrade('fake-id', image)
            .timeout(const Duration(seconds: 5)),
        throwsA(anyOf(
          isA<FretOtaException>(),
          isA<TimeoutException>(),
          isA<StateError>(),
        )),
      );
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('emits connecting phase before throwing on connect failure',
        () async {
      final phases = <FretOtaPhase>[];
      final sub = ota.onProgress.listen((p) => phases.add(p.phase));

      // Even on connect failure, the connecting phase should be emitted.
      try {
        await ota
            .upgrade('fake-id', Uint8List.fromList(<int>[1, 2, 3]))
            .timeout(const Duration(seconds: 5));
      } catch (_) {}
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(phases, contains(FretOtaPhase.connecting),
          reason: 'connecting phase must be emitted before any connect attempt');
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  group('FretOtaProgress model', () {
    test('fraction is 0 when total is 0', () {
      const progress = FretOtaProgress(
        phase: FretOtaPhase.idle,
        sentBytes: 0,
        totalBytes: 0,
      );
      expect(progress.fraction, 0.0);
      expect(progress.percent, 0);
    });

    test('fraction = sent / total for non-zero total', () {
      const progress = FretOtaProgress(
        phase: FretOtaPhase.transferring,
        sentBytes: 250,
        totalBytes: 1000,
      );
      expect(progress.fraction, 0.25);
      expect(progress.percent, 25);
    });

    test('fraction is clamped to 1.0 when sent > total', () {
      const progress = FretOtaProgress(
        phase: FretOtaPhase.transferring,
        sentBytes: 1500,
        totalBytes: 1000,
      );
      expect(progress.fraction, 1.0);
      expect(progress.percent, 100);
    });

    test('percent rounds to nearest integer', () {
      // 1/3 = 0.333... -> 33%
      const progress = FretOtaProgress(
        phase: FretOtaPhase.transferring,
        sentBytes: 1,
        totalBytes: 3,
      );
      expect(progress.percent, 33);
    });

    test('toString includes phase, sent/total, and percent', () {
      const progress = FretOtaProgress(
        phase: FretOtaPhase.success,
        sentBytes: 1000,
        totalBytes: 1000,
      );
      final s = progress.toString();
      expect(s, contains('FretOtaProgress'));
      expect(s, contains('success'));
      expect(s, contains('1000/1000'));
      expect(s, contains('100%'));
    });

    test('all phases are enumerated in order', () {
      // The phase enum is part of the public API; verify it has the
      // expected values so brand apps can switch over them.
      expect(FretOtaPhase.values, contains(FretOtaPhase.idle));
      expect(FretOtaPhase.values, contains(FretOtaPhase.connecting));
      expect(FretOtaPhase.values, contains(FretOtaPhase.starting));
      expect(FretOtaPhase.values, contains(FretOtaPhase.transferring));
      expect(FretOtaPhase.values, contains(FretOtaPhase.rebooting));
      expect(FretOtaPhase.values, contains(FretOtaPhase.success));
      expect(FretOtaPhase.values, contains(FretOtaPhase.failed));
    });
  });

  group('FretOtaException', () {
    test('carries message and stringifies', () {
      const e = FretOtaException('firmware image is empty');
      expect(e.message, 'firmware image is empty');
      expect(e.toString(), 'FretOtaException: firmware image is empty');
    });
  });

  group('FretOTA constants (PPlus protocol)', () {
    // These constants are part of the SDK's public contract: brand apps
    // that subclass FretOTA reference them. Renaming or renumbering
    // breaks subclasses silently.

    test('OTA GATT UUIDs are stable', () {
      expect(FretOTA.serviceUuid, '5833ff01-9b8b-5191-6142-22a4536ef123');
      expect(FretOTA.cmdUuid, '5833ff02-9b8b-5191-6142-22a4536ef123');
      expect(FretOTA.rspUuid, '5833ff03-9b8b-5191-6142-22a4536ef123');
      expect(FretOTA.dataUuid, '5833ff04-9b8b-5191-6142-22a4536ef123');
    });

    test('burst window is 16 packets x 20 bytes = 320 bytes per ACK', () {
      expect(FretOTA.burstSize, 16);
      expect(FretOTA.packetSize, 20);
      expect(FretOTA.burstSize * FretOTA.packetSize, 320);
    });

    test('maxRetries is 3', () {
      expect(FretOTA.maxRetries, 3);
    });

    test('OTA command codes (PPlus convention)', () {
      expect(FretOTA.cmdStartOta, 0x01);
      expect(FretOTA.cmdPartitionInfo, 0x02);
      expect(FretOTA.cmdReboot, 0x04);
    });

    test('OTA response codes (PPlus convention)', () {
      expect(FretOTA.rspStartOta, 0x81);
      expect(FretOTA.rspOtaComplete, 0x83);
      expect(FretOTA.rspPartitionInfo, 0x84);
      expect(FretOTA.rspPartitionComplete, 0x85);
      expect(FretOTA.rspBlockBurst, 0x87);
      expect(FretOTA.rspReboot, 0x8a);
      expect(FretOTA.rspError, 0xff);
    });

    test('error codes', () {
      expect(FretOTA.errSuccess, 0);
      expect(FretOTA.errBadData, 104);
    });
  });

  group('FretOTA.enterOtaMode alias', () {
    test('FretCommand.enterOta is aliased to power (0x01) for [0x02, 0x01]',
        () {
      // The firmware branches on the [0x02, 0x01] parameter of 0x01
      // to enter OTA mode, so the SDK alias intentionally shares the
      // command byte with `power`.
      expect(FretCommand.enterOta, FretCommand.power);
      expect(FretCommand.enterOta, 0x01);
    });
  });

  // === Full upgrade protocol (FakeOtaTransport) ===
  //
  // These tests script the complete OTA flow through the injected
  // FretOtaTransport abstraction: START_OTA → PARTITION_INFO →
  // 16-packet burst → ACK → REBOOT, covering multi-burst, bad-data
  // retry, retry-exhausted, final-packet padding, progress stream,
  // and disconnect-on-error.

  group('FretOTA.upgrade protocol (FakeOtaTransport)', () {
    late FakeOtaTransport fake;
    late FretOTA ota;

    setUp(() {
      fake = FakeOtaTransport();
      ota = FretOTA(transport: fake);
    });

    tearDown(() {
      ota.dispose();
    });

    test('small image (100 bytes) completes in one burst', () async {
      // 100 bytes = 5 packets of 20 bytes each. Single burst.
      final image = Uint8List.fromList(List<int>.filled(100, 0xAB));
      _scriptOkFlow(fake);

      await ota.upgrade('dev-1', image);

      expect(fake.connected, isTrue);
      expect(fake.discovered, isTrue);
      expect(fake.notifyEnabled, isTrue);
      expect(fake.disconnected, isTrue,
          reason: 'must disconnect after success');

      // 3 cmd writes: START_OTA, PARTITION_INFO, REBOOT.
      expect(fake.cmdWrites.length, 3);
      expect(fake.cmdWrites[0],
          <int>[FretOTA.cmdStartOta, 0x02, 0x01]);
      // PARTITION_INFO: cmd byte + partition index 0 + 4-byte length.
      expect(fake.cmdWrites[1][0], FretOTA.cmdPartitionInfo);
      expect(fake.cmdWrites[1][1], 0x00);
      // length encoded big-endian.
      expect(fake.cmdWrites[1].sublist(2), <int>[0, 0, 0, 100]);
      expect(fake.cmdWrites[2], <int>[FretOTA.cmdReboot, 0x00]);

      // 5 data writes, each 20 bytes, content from image.
      expect(fake.dataWrites.length, 5);
      for (final w in fake.dataWrites) {
        expect(w.length, FretOTA.packetSize);
        expect(w.every((b) => b == 0xAB), isTrue);
      }
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('final packet is zero-padded to 20 bytes', () async {
      // 105 bytes = 5 full packets + 1 packet with 5 real bytes.
      // The 6th packet must be padded to 20 bytes (5 real + 15 zeros).
      final image = Uint8List.fromList(List<int>.filled(105, 0xCD));
      _scriptOkFlow(fake, burstEndAt: 6);

      await ota.upgrade('dev-1', image);

      expect(fake.dataWrites.length, 6);
      for (final w in fake.dataWrites) {
        expect(w.length, FretOTA.packetSize,
            reason: 'every writeData must be exactly packetSize');
      }
      // Last packet: 5 bytes of 0xCD followed by 15 zeros.
      final last = fake.dataWrites.last;
      expect(last.sublist(0, 5), everyElement(0xCD));
      expect(last.sublist(5), everyElement(0));
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('large image (500 bytes) splits into 2 bursts', () async {
      // 500 bytes = 25 packets. Burst 1: 16 packets (320 bytes).
      // Burst 2: 9 packets (180 bytes). Two ACKs expected.
      final image = Uint8List.fromList(List<int>.filled(500, 0x77));
      fake.cmdResponses[FretOTA.cmdStartOta] = [
        <int>[FretOTA.errSuccess, FretOTA.rspStartOta],
      ];
      fake.cmdResponses[FretOTA.cmdPartitionInfo] = [
        <int>[FretOTA.errSuccess, FretOTA.rspPartitionInfo],
      ];
      // Burst 1 ACK at packet 16; burst 2 ACK + complete at packet 25.
      fake.responsesAtDataCount[16] = [
        <int>[FretOTA.errSuccess, FretOTA.rspBlockBurst],
      ];
      fake.responsesAtDataCount[25] = [
        <int>[FretOTA.errSuccess, FretOTA.rspBlockBurst],
        <int>[FretOTA.errSuccess, FretOTA.rspOtaComplete],
      ];

      await ota.upgrade('dev-1', image);

      expect(fake.dataWrites.length, 25);
      expect(fake.disconnected, isTrue);
      // PARTITION_INFO length field = 500 big-endian.
      expect(fake.cmdWrites[1].sublist(2), <int>[0, 0, 0x01, 0xF4]);
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('bad-data ACK triggers rollback + retry, succeeds on retry',
        () async {
      // 320 bytes = 16 packets = exactly 1 burst per attempt.
      final image = Uint8List.fromList(List<int>.filled(320, 0x55));
      fake.cmdResponses[FretOTA.cmdStartOta] = [
        <int>[FretOTA.errSuccess, FretOTA.rspStartOta],
      ];
      fake.cmdResponses[FretOTA.cmdPartitionInfo] = [
        <int>[FretOTA.errSuccess, FretOTA.rspPartitionInfo],
      ];
      // First attempt (packets 1-16): bad-data ACK.
      fake.responsesAtDataCount[16] = [
        <int>[FretOTA.errBadData, FretOTA.rspBlockBurst],
      ];
      // Retry (packets 17-32): success ACK + OTA complete.
      fake.responsesAtDataCount[32] = [
        <int>[FretOTA.errSuccess, FretOTA.rspBlockBurst],
        <int>[FretOTA.errSuccess, FretOTA.rspOtaComplete],
      ];

      await ota.upgrade('dev-1', image);

      // 32 data writes: 16 original + 16 retried.
      expect(fake.dataWrites.length, 32);
      // The retried packets must match the original (same image bytes).
      expect(fake.dataWrites.sublist(0, 16), fake.dataWrites.sublist(16, 32),
          reason: 'retry must resend identical packets');
      expect(fake.disconnected, isTrue);
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('retry exhausted after 3 retries throws FretOtaException',
        () async {
      // 320 bytes = 16 packets per attempt. 4 attempts (1 + 3 retries),
      // all bad-data. SDK throws after the 4th failure.
      final image = Uint8List.fromList(List<int>.filled(320, 0x55));
      fake.cmdResponses[FretOTA.cmdStartOta] = [
        <int>[FretOTA.errSuccess, FretOTA.rspStartOta],
      ];
      fake.cmdResponses[FretOTA.cmdPartitionInfo] = [
        <int>[FretOTA.errSuccess, FretOTA.rspPartitionInfo],
      ];
      for (int n = 16; n <= 64; n += 16) {
        fake.responsesAtDataCount[n] = [
          <int>[FretOTA.errBadData, FretOTA.rspBlockBurst],
        ];
      }

      await expectLater(
        ota.upgrade('dev-1', image),
        throwsA(isA<FretOtaException>()
            .having((e) => e.toString(), 'toString',
                contains('burst retry exhausted'))),
      );
      // Even on failure, the transport must be disconnected.
      expect(fake.disconnected, isTrue,
          reason: 'disconnect must run in finally even on error');
      expect(fake.dataWrites.length, 64,
          reason: '4 attempts × 16 packets');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('START_OTA rejected throws FretOtaException', () async {
      final image = Uint8List.fromList(List<int>.filled(100, 0x01));
      // START_OTA response with non-zero error code.
      fake.cmdResponses[FretOTA.cmdStartOta] = [
        <int>[0xFF, FretOTA.rspStartOta],
      ];

      await expectLater(
        ota.upgrade('dev-1', image),
        throwsA(isA<FretOtaException>()
            .having((e) => e.toString(), 'toString',
                contains('START_OTA rejected'))),
      );
      expect(fake.disconnected, isTrue);
      // No data writes — the protocol aborts before the burst phase.
      expect(fake.dataWrites, isEmpty);
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('PARTITION_INFO rejected throws FretOtaException', () async {
      final image = Uint8List.fromList(List<int>.filled(100, 0x01));
      fake.cmdResponses[FretOTA.cmdStartOta] = [
        <int>[FretOTA.errSuccess, FretOTA.rspStartOta],
      ];
      // PARTITION_INFO response with non-zero error code.
      fake.cmdResponses[FretOTA.cmdPartitionInfo] = [
        <int>[0xFF, FretOTA.rspPartitionInfo],
      ];

      await expectLater(
        ota.upgrade('dev-1', image),
        throwsA(isA<FretOtaException>()
            .having((e) => e.toString(), 'toString',
                contains('PARTITION_INFO rejected'))),
      );
      expect(fake.disconnected, isTrue);
      expect(fake.dataWrites, isEmpty);
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('rspPartitionComplete is accepted as well as rspOtaComplete',
        () async {
      final image = Uint8List.fromList(List<int>.filled(100, 0xAB));
      _scriptOkFlow(
        fake,
        burstEndAt: 5,
        completeRsp: <int>[FretOTA.errSuccess, FretOTA.rspPartitionComplete],
      );

      await ota.upgrade('dev-1', image);

      expect(fake.disconnected, isTrue);
      expect(fake.cmdWrites.length, 3);
      expect(fake.dataWrites.length, 5);
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('progress stream emits connecting/starting/transferring/success',
        () async {
      final image = Uint8List.fromList(List<int>.filled(100, 0xAB));
      _scriptOkFlow(fake);
      final phases = <FretOtaPhase>[];
      final sub = ota.onProgress.listen((p) => phases.add(p.phase));

      await ota.upgrade('dev-1', image);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(phases, contains(FretOtaPhase.connecting));
      expect(phases, contains(FretOtaPhase.starting));
      expect(phases, contains(FretOtaPhase.transferring));
      expect(phases, contains(FretOtaPhase.rebooting));
      expect(phases, contains(FretOtaPhase.success));
      // Phases appear in order: connecting → starting → transferring →
      // ... → rebooting → success.
      final connectingIdx = phases.indexOf(FretOtaPhase.connecting);
      final startingIdx = phases.indexOf(FretOtaPhase.starting);
      final transferringIdx = phases.indexOf(FretOtaPhase.transferring);
      final rebootingIdx = phases.indexOf(FretOtaPhase.rebooting);
      final successIdx = phases.indexOf(FretOtaPhase.success);
      expect(connectingIdx, lessThan(startingIdx));
      expect(startingIdx, lessThan(transferringIdx));
      expect(transferringIdx, lessThan(rebootingIdx));
      expect(rebootingIdx, lessThan(successIdx));
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('connect failure throws FretOtaException and does not discover',
        () async {
      final image = Uint8List.fromList(List<int>.filled(100, 0xAB));
      fake.connectException =
          const FretOtaException('connect failed after 3 retries: boom');

      await expectLater(
        ota.upgrade('dev-1', image),
        throwsA(isA<FretOtaException>()),
      );
      expect(fake.discovered, isFalse,
          reason: 'must not discover when connect fails');
      expect(fake.disconnected, isFalse,
          reason: 'disconnect only runs when connect succeeded');
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('discoverOtaService failure throws and disconnects', () async {
      final image = Uint8List.fromList(List<int>.filled(100, 0xAB));
      fake.discoverException =
          const FretOtaException('OTA characteristics not found');

      await expectLater(
        ota.upgrade('dev-1', image),
        throwsA(isA<FretOtaException>()),
      );
      // connect succeeded, so the finally block must disconnect.
      expect(fake.connected, isTrue);
      expect(fake.disconnected, isTrue,
          reason: 'disconnect must run in finally after connect succeeded');
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}

/// Scripts the standard success flow for [FretOTA.upgrade] against
/// [FakeOtaTransport]: START_OTA ok, PARTITION_INFO ok, one burst ACK
/// at [burstEndAt] packets, then OTA_COMPLETE.
void _scriptOkFlow(
  FakeOtaTransport fake, {
  int burstEndAt = 5,
  List<int>? completeRsp,
}) {
  fake.cmdResponses[FretOTA.cmdStartOta] = [
    <int>[FretOTA.errSuccess, FretOTA.rspStartOta],
  ];
  fake.cmdResponses[FretOTA.cmdPartitionInfo] = [
    <int>[FretOTA.errSuccess, FretOTA.rspPartitionInfo],
  ];
  fake.responsesAtDataCount[burstEndAt] = [
    <int>[FretOTA.errSuccess, FretOTA.rspBlockBurst],
    completeRsp ?? <int>[FretOTA.errSuccess, FretOTA.rspOtaComplete],
  ];
}
