// Test-only fake of [FretOtaTransport] that records every write so
// tests can script the full OTA protocol (START_OTA → PARTITION_INFO →
// 16-packet burst → ACK → REBOOT) without a real BLE stack.

import 'dart:async';
import 'dart:typed_data';

import 'package:fretspark_sdk/src/transport/fret_ota_transport.dart';

/// A fake [FretOtaTransport] that records connect/discover/write calls
/// and lets tests script OTA responses.
///
/// Response scripting:
/// - [cmdResponses]: keyed by cmd byte (data[0]). When [writeCmd] is
///   called with that byte, the next response list is dequeued and
///   emitted on [rspNotifyStream]. Use this for START_OTA /
///   PARTITION_INFO responses.
/// - [responsesAtDataCount]: keyed by cumulative [writeData] count.
///   When [writeData] is called and the count matches a key, all
///   responses for that key are emitted on [rspNotifyStream]. Use this
///   for burst ACKs and the OTA_COMPLETE response (emit both at the
///   last packet of the burst so the SDK picks up the ACK first, then
///   the complete response after the while loop).
///
/// The stream is a broadcast [StreamController]; the SDK subscribes
/// inside `_runOtaProtocol` after [setRspNotifyValue]. Emitted responses
/// are delivered to the listener on the next microtask, so the SDK's
/// `nextResponse()` await picks them up cleanly.
class FakeOtaTransport implements FretOtaTransport {
  FakeOtaTransport();

  /// Every [writeCmd] call, in order.
  final List<Uint8List> cmdWrites = [];

  /// Every [writeData] call, in order.
  final List<Uint8List> dataWrites = [];

  bool connected = false;
  bool discovered = false;
  bool notifyEnabled = false;
  bool disconnected = false;

  /// Scripted responses for [writeCmd], keyed by cmd byte (data[0]).
  /// Each call dequeues the next response list.
  final Map<int, List<List<int>>> cmdResponses = {};

  /// Scripted responses for [writeData], keyed by cumulative write count.
  /// When [writeData] is called and the count matches a key, all
  /// responses for that key are emitted on [rspNotifyStream].
  final Map<int, List<List<int>>> responsesAtDataCount = {};

  /// Optional exception thrown by [connect].
  Object? connectException;

  /// Optional exception thrown by [discoverOtaService].
  Object? discoverException;

  @override
  Future<void> connect(String deviceId, {required Duration timeout}) async {
    if (connectException != null) throw connectException!;
    connected = true;
  }

  @override
  Future<void> discoverOtaService({required Duration timeout}) async {
    if (discoverException != null) throw discoverException!;
    discovered = true;
  }

  @override
  Future<void> setRspNotifyValue(bool enable, {required Duration timeout}) async {
    notifyEnabled = enable;
  }

  @override
  Future<void> writeCmd(Uint8List data) async {
    cmdWrites.add(Uint8List.fromList(data));
    final queue = cmdResponses[data[0]];
    if (queue != null && queue.isNotEmpty) {
      final rsp = queue.removeAt(0);
      _rspController.add(List<int>.from(rsp));
    }
  }

  @override
  Future<void> writeData(Uint8List data, {required bool withoutResponse}) async {
    dataWrites.add(Uint8List.fromList(data));
    final rsps = responsesAtDataCount[dataWrites.length];
    if (rsps != null) {
      for (final rsp in rsps) {
        _rspController.add(List<int>.from(rsp));
      }
    }
  }

  final StreamController<List<int>> _rspController =
      StreamController<List<int>>.broadcast();

  /// Manually emit a response on [rspNotifyStream]. Useful for tests
  /// that need to drive responses outside of the write hooks.
  void emitRsp(List<int> data) {
    _rspController.add(List<int>.from(data));
  }

  @override
  Stream<List<int>> get rspNotifyStream => _rspController.stream;

  @override
  Future<void> disconnect({required Duration timeout}) async {
    disconnected = true;
    await _rspController.close();
  }
}
