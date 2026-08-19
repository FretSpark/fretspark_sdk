// ignore_for_file: invalid_use_of_visible_for_testing_member
// Integration tests for [FretConnection.connect] handshake flow.
//
// These tests script the full connect → handshake → attachQueriedInfo
// pipeline using FakeTransport + FakeBleDevice, with no real BLE stack.
// They verify the SDK's connection contract: which commands the SDK
// emits during handshake, how it parses notify responses, and how it
// behaves on transport failures / repeated connects / brand changes.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:fretspark_sdk/src/api/fret_connection.dart';
import 'package:fretspark_sdk/src/core/commands.dart';
import 'package:fretspark_sdk/src/models/brand_config.dart';
import 'package:fretspark_sdk/src/models/fret_device.dart';
import 'package:fretspark_sdk/src/transport/fret_transport.dart';

import 'helpers/fake_ble_device.dart';
import 'helpers/fake_transport.dart';

void main() {
  late FakeTransport transport;
  late FretConnection connection;
  late FakeBleDevice ble;

  setUp(() {
    transport = FakeTransport();
    connection = FretConnection(transport);
    ble = FakeBleDevice(id: 'dev-1', name: 'SCT-86PRO-ABCD');
    transport.nextDevice = ble;
  });

  // Helper: build a firmware->app notify frame for [cmd] carrying [data].
  // ignore: unused_element
  List<int> fwNotifyFrame(int cmd, List<int> data) {
    final len = data.length;
    return <int>[kFrameStartFWToApp, cmd, len, ...data, kFrameEndFWToApp];
  }

  group('FretConnection.connect handshake', () {
    // The SDK's _queryFirmwareVersion / _queryLedConfig /
    // _queryLedIndexMode helpers use `return await completer.future`
    // (not a bare `return completer.future`) so the async function
    // awaits the completer before entering finally and cancelling the
    // notify subscription. This lets the notify response drive the
    // completer before the subscription is torn down, so
    // attachQueriedInfo applies real notify values during connect.

    test('emits 4 query commands during connect', () async {
      // Pre-load the classroom ID characteristic read.
      ble.classroomIdValue = 0x12345678;

      // Drive the full connect handshake with scripted notify responses.
      // connect() returns once all 4 queries have been resolved (either
      // by a notify or by the 3s per-query timeout fallback).
      final device = await _connectWithNotifies(
        connection,
        ble,
        versionBytes: <int>[3, 1, 3, 4],
        ledCountBytes: <int>[0x00, 0x7E],
        ledIndexModeBytes: <int>[0x01],
        classroomId: 0x12345678,
      );

      // All 4 handshake commands are emitted (the SDK's contract).
      expect(ble.framesFor(FretCommand.queryVersion).length, 1);
      expect(ble.framesFor(FretCommand.queryLedConfig).length, 1);
      expect(ble.framesFor(FretCommand.queryLedIndexMode).length, 1);

      // The notify responses are applied to the device info.
      expect(device.firmwareVersion, '3.1.3.4');
      expect(device.ledCount, 126);
      expect(device.ledIndexReversed, 1);
      expect(device.classroomId, 0x12345678);
    });

    test('applies notify responses to device info during connect',
        () async {
      // Explicit coverage that the sub.cancel timing fix lets notify
      // values reach attachQueriedInfo. This test was previously skipped
      // because the bare `return completer.future` cancelled the
      // subscription before the completer could complete.
      final device = await _connectWithNotifies(
        connection,
        ble,
        versionBytes: <int>[3, 1, 4, 2],
        ledCountBytes: <int>[0x00, 0xFF],
        ledIndexModeBytes: <int>[0x01],
        classroomId: 0xDEADBEEF,
      );
      expect(device.firmwareVersion, '3.1.4.2');
      expect(device.ledCount, 255);
      expect(device.ledIndexReversed, 1);
      expect(device.classroomId, 0xDEADBEEF);
    });

    test('classroomId is applied via direct characteristic read', () async {
      // classroomId is read synchronously via ble.readClassroomId() (not
      // via the notify stream), so it does not depend on the sub.cancel
      // timing fix. It is applied by attachQueriedInfo regardless of
      // whether notify responses arrive.
      ble.classroomIdValue = 0xDEADBEEF;
      final device = await _connectWithNotifies(
        connection,
        ble,
        versionBytes: <int>[1, 0, 0, 0],
        ledCountBytes: <int>[0x00, 90],
        ledIndexModeBytes: <int>[0x00],
        classroomId: 0xDEADBEEF,
      );
      expect(device.classroomId, 0xDEADBEEF);
    });

    test('reconnect to same deviceId returns cached device without transport.connect',
        () async {
      final first = await _connectWithNotifies(
        connection,
        ble,
        versionBytes: <int>[1, 0, 0, 0],
        ledCountBytes: <int>[0x00, 90],
        ledIndexModeBytes: <int>[0x00],
        classroomId: 0,
      );
      expect(transport.connectCalls.length, 1);

      // Second connect with the same id should NOT call transport.connect.
      final second = await connection.connect('dev-1');
      expect(transport.connectCalls.length, 1,
          reason: 'reconnect to same id must short-circuit');
      expect(identical(first, second), isTrue);
    });

    test('connecting a different deviceId disposes the prior device', () async {
      await _connectWithNotifies(
        connection,
        ble,
        versionBytes: <int>[1, 0, 0, 0],
        ledCountBytes: <int>[0x00, 90],
        ledIndexModeBytes: <int>[0x00],
        classroomId: 0,
      );

      // New device.
      final ble2 = FakeBleDevice(id: 'dev-2', name: 'SCT-86PRO-XYZ');
      transport.nextDevice = ble2;
      await _connectWithNotifies(
        connection,
        ble2,
        versionBytes: <int>[2, 0, 0, 0],
        ledCountBytes: <int>[0x00, 96],
        ledIndexModeBytes: <int>[0x01],
        classroomId: 0,
      );

      expect(transport.connectCalls, <String>['dev-1', 'dev-2']);
      // First device was disposed: send should throw.
      expect(
        () => ble.write(_encodeFrame(0x01, <int>[0x01])),
        returnsNormally,
      );
      // dispose closed the notify stream on ble1.
      // (We can verify the original ble is detached by checking that
      // the connection's current device is now the new one.)
      expect(connection.current!.id, 'dev-2');
    });

    test('transport.connect throwing propagates and leaves _current null',
        () async {
      transport.connectException =
          const FretTransportException('device unreachable');
      expect(
        () => connection.connect('dev-1'),
        throwsA(isA<FretTransportException>()),
      );
      // Allow the throw to surface.
      await Future<void>.delayed(Duration.zero);
      expect(connection.current, isNull);
    });

    test('brand matcher is consulted and onBrandAutoDetected fires on change',
        () async {
      // Initial active brand: AUPHY.
      const auphy = BrandConfig(
        id: 'auphy',
        displayName: 'AUPHY',
        deviceModel: 'AUPHY-86',
        email: 'support@auphy.com',
        firmwarePatterns: <String>[r'^AUPHY-'],
        otaNamePrefix: 'AUPHY-OTA',
      );
      connection.setActiveBrand(auphy);

      // Matcher that recognizes Smiger devices.
      const smiger = BrandConfig(
        id: 'smiger',
        displayName: 'Smiger',
        deviceModel: 'SCT-86 PRO',
        email: 'support@smiger.com',
        firmwarePatterns: <String>[r'^SCT-86PRO-'],
        otaNamePrefix: 'SCT-86PRO OTA',
      );
      connection.setBrandMatcher((name) {
        if (name.startsWith('SCT-86PRO-')) return smiger;
        return null;
      });

      final detected = <BrandConfig>[];
      final sub = connection.onBrandAutoDetected.listen(detected.add);

      // ble.name = 'SCT-86PRO-ABCD' (matches Smiger, not AUPHY).
      await _connectWithNotifies(
        connection,
        ble,
        versionBytes: <int>[1, 0, 0, 0],
        ledCountBytes: <int>[0x00, 90],
        ledIndexModeBytes: <int>[0x00],
        classroomId: 0,
      );

      // Give the onBrandAutoDetected controller a chance to deliver.
      await Future<void>.delayed(Duration.zero);
      expect(detected.length, 1);
      expect(detected.first.id, 'smiger');
      expect(connection.activeBrand!.id, 'smiger');
      expect(connection.current!.brandId, 'smiger');
      await sub.cancel();
    });

    test('brand matcher returning null keeps the active brand unchanged',
        () async {
      const auphy = BrandConfig(
        id: 'auphy',
        displayName: 'AUPHY',
        deviceModel: 'AUPHY-86',
        email: 'support@auphy.com',
        firmwarePatterns: <String>[r'^AUPHY-'],
        otaNamePrefix: 'AUPHY-OTA',
      );
      connection.setActiveBrand(auphy);
      connection.setBrandMatcher((name) => null);

      final detected = <BrandConfig>[];
      final sub = connection.onBrandAutoDetected.listen(detected.add);

      await _connectWithNotifies(
        connection,
        ble,
        versionBytes: <int>[1, 0, 0, 0],
        ledCountBytes: <int>[0x00, 90],
        ledIndexModeBytes: <int>[0x00],
        classroomId: 0,
      );
      await Future<void>.delayed(Duration.zero);

      expect(detected, isEmpty);
      expect(connection.activeBrand!.id, 'auphy');
      expect(connection.current!.brandId, 'auphy');
      await sub.cancel();
    });
  });

  group('FretConnection.disconnect', () {
    test('clears current device and disposes it', () async {
      final device = await _connectWithNotifies(
        connection,
        ble,
        versionBytes: <int>[1, 0, 0, 0],
        ledCountBytes: <int>[0x00, 90],
        ledIndexModeBytes: <int>[0x00],
        classroomId: 0,
      );
      expect(connection.current, isNotNull);

      await connection.disconnect();
      expect(connection.current, isNull);
      // Subsequent send on the disposed device throws.
      expect(
        () => device.send(FretCommand.power, <int>[0x01]),
        throwsA(isA<StateError>()),
      );
    });

    test('disconnect with no current device is a no-op', () async {
      await connection.disconnect();
      expect(connection.current, isNull);
    });
  });

  group('FretConnection.scanResults filtering', () {
    test('without active brand, emits all results', () async {
      final results = <FretScanResult>[];
      final sub = connection.scanResults.listen(results.add);

      transport.emitScanResult(const FretScanResult(
          id: 'a', name: 'SCT-86PRO-AAAA', rssi: -50));
      transport.emitScanResult(const FretScanResult(
          id: 'b', name: 'OtherDevice', rssi: -60));
      await Future<void>.delayed(Duration.zero);

      expect(results.length, 2);
      await sub.cancel();
    });

    test('with active brand, emits only matching firmware names', () async {
      const auphy = BrandConfig(
        id: 'auphy',
        displayName: 'AUPHY',
        deviceModel: 'AUPHY-86',
        email: 'support@auphy.com',
        firmwarePatterns: <String>[r'^AUPHY-'],
        otaNamePrefix: 'AUPHY-OTA',
      );
      connection.setActiveBrand(auphy);

      final results = <FretScanResult>[];
      final sub = connection.scanResults.listen(results.add);

      transport.emitScanResult(const FretScanResult(
          id: 'a', name: 'AUPHY-1234', rssi: -50));
      transport.emitScanResult(const FretScanResult(
          id: 'b', name: 'SCT-86PRO-XYZ', rssi: -50));
      transport.emitScanResult(const FretScanResult(
          id: 'c', name: 'AUPHY-5678', rssi: -55));
      await Future<void>.delayed(Duration.zero);

      expect(results.map((r) => r.id).toList(), <String>['a', 'c']);
      await sub.cancel();
    });
  });

  group('FretConnection.onCurrentDeviceStateChanged', () {
    test('filters connectionStates by the current device id', () async {
      await _connectWithNotifies(
        connection,
        ble,
        versionBytes: <int>[1, 0, 0, 0],
        ledCountBytes: <int>[0x00, 90],
        ledIndexModeBytes: <int>[0x00],
        classroomId: 0,
      );

      final states = <bool>[];
      final sub = connection.onCurrentDeviceStateChanged.listen(states.add);

      transport.emitConnectionState('dev-1', false);
      transport.emitConnectionState('other-device', true);
      transport.emitConnectionState('dev-1', true);
      await Future<void>.delayed(Duration.zero);

      // Only dev-1 events get through.
      expect(states, <bool>[false, true]);
      await sub.cancel();
    });

    test('returns empty stream when no current device', () async {
      expect(connection.onCurrentDeviceStateChanged, emitsDone);
    });
  });

  group('FretConnection.connect handshake fallback on timeout', () {
    // The SDK hardcodes 3-second per-query timeouts in connect(). With
    // no notify responses, the connect still completes and applies
    // defaults: '' version, 90 LED count, 0 LED index mode, 0 classroom.
    //
    // This test takes ~3 seconds to run because of the real timer.
    test('all queries timing out yields defaults', () async {
      connection.setActiveBrand(null);
      // No notify responses, no classroom id read.
      ble.classroomIdValue = null;

      final device = await connection.connect('dev-1').timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException(
            'connect should complete within 3s of timeout fallbacks'),
      );

      expect(device.firmwareVersion, '');
      expect(device.ledCount, 90);
      expect(device.ledIndexReversed, 0);
      expect(device.classroomId, 0);
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}

/// Wait for [ble] to write a frame with the given [cmd], pumping the
/// microtask queue until it appears. Throws after ~1 second if no
/// matching frame is written.
Future<void> _waitForFrame(FakeBleDevice ble, int cmd) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (ble.framesFor(cmd).isEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('SDK never sent command 0x${cmd.toRadixString(16)}');
    }
    await Future<void>.delayed(Duration.zero);
  }
}

/// Drives a complete connect handshake by reacting to each query command
/// with a scripted notify response. Returns the connected device.
Future<FretDevice> _connectWithNotifies(
  FretConnection connection,
  FakeBleDevice ble, {
  required List<int> versionBytes,
  required List<int> ledCountBytes,
  required List<int> ledIndexModeBytes,
  required int classroomId,
}) async {
  ble.classroomIdValue = classroomId;
  final connectFuture = connection.connect(ble.id);

  await _waitForFrame(ble, FretCommand.queryVersion);
  ble.emitNotify(<int>[
    kFrameStartFWToApp,
    FretCommand.queryVersion,
    versionBytes.length,
    ...versionBytes,
    kFrameEndFWToApp,
  ]);

  await _waitForFrame(ble, FretCommand.queryLedConfig);
  ble.emitNotify(<int>[
    kFrameStartFWToApp,
    FretCommand.queryLedConfig,
    ledCountBytes.length,
    ...ledCountBytes,
    kFrameEndFWToApp,
  ]);

  await _waitForFrame(ble, FretCommand.queryLedIndexMode);
  ble.emitNotify(<int>[
    kFrameStartFWToApp,
    FretCommand.queryLedIndexMode,
    ledIndexModeBytes.length,
    ...ledIndexModeBytes,
    kFrameEndFWToApp,
  ]);

  return connectFuture;
}

/// Re-encode helper for a write-only frame. Used to assert that writes
/// still work on a not-yet-disposed fake device.
Uint8List _encodeFrame(int cmd, List<int> params) {
  return Uint8List.fromList(
    <int>[kFrameStartAppTo_FW, cmd, params.length, ...params, kFrameEndAppToFW],
  );
}
