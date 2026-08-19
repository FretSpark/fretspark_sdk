// ignore_for_file: invalid_use_of_visible_for_testing_member
// FretClassroom 内部需要调用 FretDevice.send 发送课堂模式命令。

import '../core/commands.dart';
import '../models/fret_device.dart';

/// Classroom / local-teaching mode API.
///
/// 通过设备间专用广播信道同步 LED 状态:一台"教师"设备可将其当前 LED
/// 状态推送给一台或多台"学生"设备(不经 BLE GATT 的侧信道)。适用于课堂
/// 场景,教师希望所有学生的指板实时镜像自己的指板。
///
/// The SDK only exposes the start/stop primitives; the brand APP is
/// responsible for:
/// - Coordinating classroom IDs (see [FretDevice.classroomId] /
///   [FretDevice.setClassroomId]) so teacher and students share the same
///   channel.
/// - UI for role selection (teacher vs student).
/// - Calling [stop] on every device when the session ends.
///
/// All three commands take no parameters. The firmware handles channel
/// negotiation, packet framing, and retransmission internally.
class FretClassroom {
  /// Start broadcasting LED state as a teacher.
  ///
  /// After this call, the firmware enters 教师广播模式 and pushes each
  /// rendered LED frame to the classroom channel identified by the
  /// device's classroom ID.
  ///
  /// Only one device in a classroom should call this; the others should
  /// call [startStudent]. The brand APP is responsible for enforcing
  /// this invariant.
  Future<void> startTeacher(FretDevice device) async {
    await device.send(FretCommand.teacherTxStart, <int>[]);
  }

  /// Start listening for teacher broadcasts as a student.
  ///
  /// After this call, the firmware enters 学生监听模式 and overwrites
  /// its own LED state with whatever the teacher broadcasts on the same
  /// classroom ID. Local LED commands sent to this device are ignored
  /// until [stop] is called.
  Future<void> startStudent(FretDevice device) async {
    await device.send(FretCommand.studentRxStart, <int>[]);
  }

  /// Stop classroom mode.
  ///
  /// Works for both teacher and student roles. After this call the
  /// firmware returns to normal BLE-driven rendering and the device
  /// stops broadcasting / listening on the classroom channel.
  Future<void> stop(FretDevice device) async {
    await device.send(FretCommand.classroomStop, <int>[]);
  }
}
