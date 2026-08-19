// Integration tests for [FretClassroom].
//
// Coverage:
//   - startTeacher: encodes 0x23 with empty payload
//   - startStudent: encodes 0x24 with empty payload
//   - stop: encodes 0x25 with empty payload
//   - disposed device throws FretSparkException
//   - full session cycle: teacher → stop → student → stop

import 'package:flutter_test/flutter_test.dart';
import 'package:fretspark_sdk/src/api/fret_classroom.dart';
import 'package:fretspark_sdk/src/core/commands.dart';
import 'package:fretspark_sdk/src/core/fret_spark_exception.dart';
import 'package:fretspark_sdk/src/models/fret_device.dart';

import 'helpers/fake_ble_device.dart';

void main() {
  group('FretClassroom', () {
    late FakeBleDevice ble;
    late FretDevice device;
    late FretClassroom classroom;

    setUp(() {
      ble = FakeBleDevice(id: 'dev-classroom', name: 'SCT-86PRO-TEST');
      device = FretDevice.forBle(
        ble: ble,
        displayName: 'Test',
        brandId: 'fretspark',
      );
      classroom = FretClassroom();
    });

    test('startTeacher encodes 0x23 with empty payload', () async {
      await classroom.startTeacher(device);

      expect(ble.framesFor(FretCommand.teacherTxStart).length, 1);
      final params = ble.paramsFor(FretCommand.teacherTxStart).single;
      expect(params, isEmpty);
    });

    test('startStudent encodes 0x24 with empty payload', () async {
      await classroom.startStudent(device);

      expect(ble.framesFor(FretCommand.studentRxStart).length, 1);
      final params = ble.paramsFor(FretCommand.studentRxStart).single;
      expect(params, isEmpty);
    });

    test('stop encodes 0x25 with empty payload', () async {
      await classroom.stop(device);

      expect(ble.framesFor(FretCommand.classroomStop).length, 1);
      final params = ble.paramsFor(FretCommand.classroomStop).single;
      expect(params, isEmpty);
    });

    test('teacher session: startTeacher then stop', () async {
      await classroom.startTeacher(device);
      await classroom.stop(device);

      expect(ble.writtenFrames.length, 2);
      expect(ble.writtenFrames[0][1], FretCommand.teacherTxStart);
      expect(ble.writtenFrames[1][1], FretCommand.classroomStop);
    });

    test('student session: startStudent then stop', () async {
      await classroom.startStudent(device);
      await classroom.stop(device);

      expect(ble.writtenFrames.length, 2);
      expect(ble.writtenFrames[0][1], FretCommand.studentRxStart);
      expect(ble.writtenFrames[1][1], FretCommand.classroomStop);
    });

    test('full cycle: teacher → stop → student → stop', () async {
      await classroom.startTeacher(device);
      await classroom.stop(device);
      await classroom.startStudent(device);
      await classroom.stop(device);

      expect(ble.writtenFrames.length, 4);
      final cmds = ble.writtenFrames.map((f) => f[1]).toList();
      expect(cmds, <int>[
        FretCommand.teacherTxStart,
        FretCommand.classroomStop,
        FretCommand.studentRxStart,
        FretCommand.classroomStop,
      ]);
    });

    test('startTeacher on disposed device throws FretSparkException', () async {
      await device.dispose();
      expect(
        () => classroom.startTeacher(device),
        throwsA(isA<FretSparkException>()),
      );
    });

    test('startStudent on disposed device throws FretSparkException', () async {
      await device.dispose();
      expect(
        () => classroom.startStudent(device),
        throwsA(isA<FretSparkException>()),
      );
    });

    test('stop on disposed device throws FretSparkException', () async {
      await device.dispose();
      expect(
        () => classroom.stop(device),
        throwsA(isA<FretSparkException>()),
      );
    });
  });
}
