// ignore_for_file: invalid_use_of_visible_for_testing_member
// FretClassroom internally needs to call FretDevice.send to send
// classroom-mode commands.

import '../core/commands.dart';
import '../models/fret_device.dart';

/// Classroom / local-teaching mode API.
///
/// Syncs LED state across devices via a dedicated broadcast channel
/// between devices: a single "teacher" device can push its current LED
/// state to one or more "student" devices (a side channel outside BLE
/// GATT). Suitable for classroom scenarios where the teacher wants every
/// student's fretboard to mirror their own fretboard in real time.
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
  /// After this call, the firmware enters teacher broadcast mode and
  /// pushes each rendered LED frame to the classroom channel identified
  /// by the device's classroom ID.
  ///
  /// Only one device in a classroom should call this; the others should
  /// call [startStudent]. The brand APP is responsible for enforcing
  /// this invariant.
  Future<void> startTeacher(FretDevice device) async {
    await device.send(FretCommand.teacherTxStart, <int>[]);
  }

  /// Start listening for teacher broadcasts as a student.
  ///
  /// After this call, the firmware enters student listener mode and
  /// overwrites its own LED state with whatever the teacher broadcasts
  /// on the same classroom ID. Local LED commands sent to this device
  /// are ignored until [stop] is called.
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
