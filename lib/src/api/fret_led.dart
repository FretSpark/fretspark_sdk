// ignore_for_file: invalid_use_of_visible_for_testing_member
// FretLED internally needs to call FretDevice.send to send LED commands.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/batch_transfer.dart';
import '../core/commands.dart';
import '../core/fret_spark_exception.dart';
import '../data/chord_dictionary.dart';
import '../data/scale_dictionary.dart';
import '../models/fret_color.dart';
import '../models/fret_device.dart';
import '../models/fret_note.dart';

/// High-level LED control API for a connected [FretDevice].
///
/// Each method is safe to call fire-and-forget from UI event handlers.
/// The SDK internally handles serialization, coalescing, left-handed
/// mirroring, and tracks group control state so it can automatically
/// clean up when exiting group control.
///
/// Left-handed mode is persisted to `SharedPreferences` and shared across
/// all devices through the [FretSpark] singleton.
class FretLED {
  FretLED(this._prefs);

  final SharedPreferences _prefs;
  static const String _kLeftHandedKey = 'fretspark.left_handed_mode';

  /// Per-device state: whether the firmware's group channel is currently
  /// active. The SDK emits a cleanup frame before any non-group command to
  /// avoid the firmware rendering stale group colors.
  final Map<String, bool> _groupActive = <String, bool>{};

  /// Per-device state: whether the group-color render path has already
  /// been forced on for this device. Idempotent until the next cleanup.
  final Map<String, bool> _groupChannelForced = <String, bool>{};

  /// Per-device batch sender. Lazily created because the send callback is
  /// bound to the device's [FretDevice.send] method.
  final Map<String, LedBatchSender> _batchSenders = <String, LedBatchSender>{};

  bool _leftHanded = false;

  /// Whether left-handed (mirrored) mode is active.
  ///
  /// When `true`, string indices are mirrored 0↔5 before being sent to the
  /// firmware, so callers always use right-handed numbering. Fret indices
  /// are never mirrored (the nut→high-fret direction is fixed relative to
  /// the body).
  bool get leftHandedMode => _leftHanded;

  /// Enable or disable left-handed mode. Persisted to `SharedPreferences`
  /// and applied to all subsequently-sent LED commands.
  Future<void> setLeftHandedMode(bool enabled) async {
    _leftHanded = enabled;
    await _prefs.setBool(_kLeftHandedKey, enabled);
  }

  /// Load the persisted left-handed mode flag. Called once during
  /// `FretSpark.initialize`.
  @visibleForTesting
  Future<void> loadPersistedState() async {
    _leftHanded = _prefs.getBool(_kLeftHandedKey) ?? false;
  }

  LedBatchSender _batchSenderFor(FretDevice device) =>
      _batchSenders.putIfAbsent(device.id, () => LedBatchSender(device.send));

  // === Power / brightness / color ===

  /// Turn the LED panel on or off.
  Future<void> setPower(FretDevice device, {required bool on}) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    await _clearGroupIfActive(device);
    await device.send(FretCommand.power, <int>[on ? 0x01 : 0x00]);
  }

  /// Set global brightness. Range 0–1000.
  Future<void> setBrightness(FretDevice device, int brightness) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    if (brightness < 0 || brightness > 1000) {
      throw FretSparkException.validationError(
        'brightness must be 0..1000, got $brightness.',
      );
    }
    await device.send(FretCommand.brightness, <int>[
      (brightness >> 8) & 0xFF,
      brightness & 0xFF,
      0,
      0,
      0,
      0,
    ]);
  }

  /// Set the base color using HSL. Hue: 0–360, Saturation: 0–1000.
  Future<void> setColor(FretDevice device, FretHsl hsl) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    await _clearGroupIfActive(device);
    await _clearSelection(device);
    await device.send(FretCommand.color, <int>[
      (hsl.hue >> 8) & 0xFF,
      hsl.hue & 0xFF,
      (hsl.saturation >> 8) & 0xFF,
      hsl.saturation & 0xFF,
      0,
      0,
    ]);
  }

  /// Fill the entire fretboard with a solid RGB color.
  Future<void> fillColor(FretDevice device, FretColor color) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    await _clearGroupIfActive(device);
    await _clearSelection(device);
    await device.send(
      FretCommand.fillColor,
      <int>[0, color.r, 0, color.g, 0, color.b],
    );
  }

  // === Effect mode ===

  /// Switch to a built-in effect mode. [modeId] is 1-based.
  Future<void> setMode(FretDevice device, int modeId) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    if (modeId < 1 || modeId > 117) {
      throw FretSparkException.validationError(
        'modeId must be 1..117, got $modeId.',
      );
    }
    await _clearSelection(device);
    await device.send(FretCommand.mode, <int>[
      (modeId >> 8) & 0xFF,
      modeId & 0xFF,
    ]);
  }

  /// Set effect speed. Range 0–255.
  Future<void> setSpeed(FretDevice device, int speed) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    if (speed < 0 || speed > 255) {
      throw ArgumentError('speed must be 0..255, got $speed');
    }
    await device.send(FretCommand.speed, <int>[speed]);
  }

  /// Set effect direction. 0 = forward, 1 = reverse.
  Future<void> setDirection(FretDevice device, int direction) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    if (direction < 0 || direction > 1) {
      throw ArgumentError('direction must be 0 or 1, got $direction');
    }
    await device.send(FretCommand.direction, <int>[direction]);
  }

  // === Hardware layout ===

  /// Set the RGB layout mode.
  ///
  /// - `linear=false` (default): matrix layout, used by typical fretboard
  ///   grid wiring.
  /// - `linear=true`: linear layout, used by WS2812/SK6812 strips where
  ///   LEDs are physically arranged in a single line.
  ///
  /// Maps to firmware command 0x02. Must be called *before* any LED
  /// rendering command if the device uses a non-default layout.
  Future<void> setLinearLayout(FretDevice device, {required bool linear}) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    await device.send(FretCommand.linearLayout, <int>[linear ? 0x01 : 0x00]);
  }

  /// Override the total LED count the firmware drives.
  ///
  /// Use this when the connected hardware has a non-default strip length
  /// (e.g. a 21-fret board = 126 LEDs, but firmware defaults to 90).
  /// Range: 1–65535. Maps to firmware command 0x03.
  ///
  /// After calling this, [FretDevice.ledCount] is **not** automatically
  /// updated; subscribe to [FretDevice.onLedCountChanged] or call
  /// [FretDevice.queryLedConfig] to refresh it.
  Future<void> setLedCount(FretDevice device, int count) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    if (count < 1 || count > 0xFFFF) {
      throw ArgumentError('count must be 1..65535, got $count');
    }
    await device.send(FretCommand.ledCount, <int>[
      (count >> 8) & 0xFF,
      count & 0xFF,
    ]);
  }

  // === Music style (independent from mode/musicMode) ===

  /// Set the music style. This triggers a render pipeline independent of
  /// [setMode] (0x06) and [setMusicMode] (0x09).
  ///
  /// Firmware internally calls `apply_music_style(styleId)`. Style IDs ≥ 100
  /// are reset to 0 by the firmware (used internally for mic-source
  /// switching protection). Range: 0–99 for app-defined styles.
  ///
  /// Maps to firmware command 0x1B. **Required for APP/firmware feature
  /// parity** — without this API, brand apps cannot trigger the music-style
  /// render path that the official app uses.
  Future<void> setMusicStyle(FretDevice device, int styleId) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    if (styleId < 0 || styleId > 99) {
      throw FretSparkException.validationError(
        'music styleId must be 0..99, got $styleId.',
      );
    }
    await device.send(FretCommand.musicStyle, <int>[styleId]);
  }

  // === Timer (scheduled power on/off) ===

  /// Configure a scheduled power on/off timer.
  ///
  /// Requires the device RTC to be synced first via
  /// [FretDevice.setRtcTime]; otherwise the firmware's RTC may drift and
  /// fire the timer at the wrong time.
  ///
  /// - [on]: `true` = schedule power-on, `false` = schedule power-off.
  /// - [hour]/[minute]/[second]: trigger time of day (24-hour format).
  /// - [slot]: timer slot index (firmware-reserved, default 0). Multiple
  ///   slots allow independent on/off schedules; check firmware docs for
  ///   slot count.
  ///
  /// Maps to firmware command 0x0D. Payload layout:
  /// `[slot, onOff, hour, minute, second, 0x00]`.
  Future<void> setTimer(
    FretDevice device, {
    required bool on,
    required int hour,
    required int minute,
    required int second,
    int slot = 0,
  }) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    if (hour < 0 || hour > 23) {
      throw ArgumentError('hour must be 0..23, got $hour');
    }
    if (minute < 0 || minute > 59) {
      throw ArgumentError('minute must be 0..59, got $minute');
    }
    if (second < 0 || second > 59) {
      throw ArgumentError('second must be 0..59, got $second');
    }
    if (slot < 0 || slot > 255) {
      throw ArgumentError('slot must be 0..255, got $slot');
    }
    if (!device.isRtcSynced) {
      throw FretSparkException.validationError(
        'RTC time not synchronized. Call setRtcTime() before setTimer().',
      );
    }
    await device.send(FretCommand.timer, <int>[
      slot,
      on ? 0x01 : 0x00,
      hour,
      minute,
      second,
      0x00, // reserved byte (firmware writes to device_time_*[4])
    ]);
  }

  // === Range fill (continuous LED segment) ===

  /// Fill a continuous range of LEDs with individual colors in a single
  /// packet.
  ///
  /// Unlike [fillColor] (which paints the whole board one color) and
  /// [lightNotes] (which uses batched sparse indexing), this method
  /// writes a contiguous segment starting at [startIndex] and refreshes
  /// the LEDs in the same frame. Performance is ~4–5× higher than
  /// batched sparse writes for the same LED count.
  ///
  /// - [startIndex]: first LED index (0-based, APP numbering).
  /// - [colors]: per-LED colors. Length must be ≤
  ///   [FretCommand.maxLedsPerFillRangePacket] (79). For longer ranges,
  ///   call this method in chunks.
  ///
  /// Maps to firmware command 0x14. Payload layout:
  /// `[startIndex, r1,g1,b1, r2,g2,b2, ...]`.
  ///
  /// If [leftHandedMode] is on, [startIndex] is mirrored to the
  /// firmware's internal index via `app_idx_to_fw_idx` (handled by the
  /// firmware, not the SDK).
  Future<void> fillRange(
    FretDevice device, {
    required int startIndex,
    required List<FretColor> colors,
  }) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    if (startIndex < 0 || startIndex > 255) {
      throw ArgumentError('startIndex must be 0..255, got $startIndex');
    }
    if (colors.isEmpty) {
      throw ArgumentError('colors must not be empty');
    }
    if (colors.length > FretCommand.maxLedsPerFillRangePacket) {
      throw FretSparkException.validationError(
        'fillRange supports at most 79 LEDs per call (got ${colors.length}).',
      );
    }
    await _clearGroupIfActive(device);
    final payload = <int>[startIndex];
    for (final c in colors) {
      payload.addAll(<int>[c.r, c.g, c.b]);
    }
    await device.send(FretCommand.fillRange, payload);
  }

  /// Turn all LEDs on. Equivalent to filling with the rainbow effect.
  Future<void> setAllOn(FretDevice device) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    await _clearGroupIfActive(device);
    await _clearSelection(device);
    await setMode(device, 2);
  }

  /// Turn all LEDs off (clears selection + applies a black batch frame).
  ///
  /// Transitions directly from the previous image to black without an
  /// intermediate black-flash.
  Future<void> clearAll(FretDevice device) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    await _clearGroupIfActive(device);
    await _clearSelection(device);
    await device.send(FretCommand.batchBegin, <int>[0]);
    await device.send(FretCommand.batchEnd, <int>[]);
  }

  // === Selection mask ===

  /// Lock the active selection mask so subsequent effect/color commands
  /// only apply to [ledIndices]. Pass an empty list to clear.
  Future<void> lockSelection(FretDevice device, List<int> ledIndices) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    if (ledIndices.isEmpty) {
      await device.send(FretCommand.selectionMask, <int>[]);
      return;
    }
    final mask = List<int>.filled(50, 0);
    for (final idx in ledIndices) {
      if (idx >= 0 && idx < 400) {
        mask[idx ~/ 8] |= (1 << (idx % 8));
      }
    }
    await device.send(FretCommand.selectionMask, mask);
  }

  /// Clear the active selection mask. Effects then apply to all LEDs.
  Future<void> unlockSelection(FretDevice device) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    await device.send(FretCommand.selectionMask, <int>[]);
  }

  // === Single / multiple learning LEDs ===

  /// Light a single note. [string] is 0–5 from high E to low E.
  /// [fret] is 0-indexed (0 = open).
  Future<void> lightNote(FretDevice device, FretNote note) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    await _clearGroupIfActive(device);
    final index = _encodeLedIndex(device, note.string, note.fret);
    if (index == null) return; // out of bounds
    await device.send(FretCommand.learningLed, <int>[
      0x01,
      index,
      note.color.r,
      note.color.g,
      note.color.b,
    ]);
  }

  /// Light multiple notes.
  ///
  /// Notes are de-duplicated by LED index; the last write wins. This
  /// matches the firmware's per-pixel overwrite semantics.
  Future<void> lightNotes(FretDevice device, List<FretNote> notes) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    if (notes.isEmpty) return;
    await _clearGroupIfActive(device);

    // Build {index: (r,g,b)} preserving caller order (last wins).
    final Map<int, (int, int, int)> pixelMap = <int, (int, int, int)>{};
    for (final n in notes) {
      final index = _encodeLedIndex(device, n.string, n.fret);
      if (index == null) continue;
      pixelMap[index] = (n.color.r, n.color.g, n.color.b);
    }
    if (pixelMap.isEmpty) return;

    final pixels = <({int index, int r, int g, int b})>[
      for (final entry in pixelMap.entries)
        (
          index: entry.key,
          r: entry.value.$1,
          g: entry.value.$2,
          b: entry.value.$3,
        ),
    ];

    await _batchSenderFor(device).sendLearningMultiple(
      deviceId: device.id,
      pixels: pixels,
    );
  }

  /// Clear all learning LEDs.
  Future<void> clearLearningLEDs(FretDevice device) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    await _clearGroupIfActive(device);
    await device.send(FretCommand.learningLed, <int>[0x00]);
  }

  // === Chord / scale (compositional helpers) ===

  /// Light a chord across the fretboard using the built-in chord
  /// dictionary. The root note selects the pitch; [chordType] selects the
  /// chord quality (e.g. `maj`, `min`, `7`).
  ///
  /// All lit positions use [color]. Previously-lit learning LEDs are
  /// cleared first.
  Future<void> showChord(
    FretDevice device, {
    required NoteName root,
    required String chordType,
    FretColor color = FretColor.white,
  }) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    final fingers = ChordDictionary.fingering(root, chordType);
    if (fingers == null) {
      throw ArgumentError('Unknown chord: $root $chordType');
    }
    final notes = <FretNote>[];
    for (int s = 0; s < 6; s++) {
      final fret = fingers[s];
      if (fret < 0) continue; // skip unplayed strings
      notes.add(FretNote(string: s, fret: fret, color: color));
    }
    await clearLearningLEDs(device);
    await lightNotes(device, notes);
  }

  /// Light a scale across the fretboard. The root note selects the key;
  /// [scale] selects the scale type. Lights one octave on each string.
  Future<void> showScale(
    FretDevice device, {
    required NoteName root,
    required ScaleType scale,
    FretColor color = FretColor.white,
  }) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    final intervals = ScaleDictionary.intervals(scale);
    if (intervals == null) {
      throw ArgumentError('Unknown scale: $scale');
    }
    final rootSemitone = root.semitone;
    final maxFret = device.maxFret;

    final notes = <FretNote>[];
    // Standard tuning open-string pitches (string 0 = high E = semitone 4,
    // string 5 = low E = semitone 4 mod 12).
    const openSemitones = <int>[4, 11, 7, 2, 9, 4];
    for (int s = 0; s < 6; s++) {
      final open = openSemitones[s];
      for (int fret = 0; fret <= maxFret; fret++) {
        final pitch = (open + fret) % 12;
        final offsetFromRoot = (pitch - rootSemitone + 12) % 12;
        if (intervals.contains(offsetFromRoot)) {
          notes.add(FretNote(string: s, fret: fret, color: color));
        }
      }
    }
    await clearLearningLEDs(device);
    await lightNotes(device, notes);
  }

  // === Voice / mic mode ===

  /// Switch the firmware to a high-level music mode.
  ///
  /// [mode] selects the music mode; [extraParams] is an optional list of
  /// mode-specific parameters (tempo, time signature, etc.) whose layout
  /// is defined by the firmware spec. The SDK does not interpret them.
  ///
  /// Note: this is distinct from the AI rhythm LED *effects* (modes
  /// 124–135), which are sent via the regular [setMode] command.
  Future<void> setMusicMode(
    FretDevice device,
    MusicMode mode, {
    List<int> extraParams = const <int>[],
  }) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    await _clearGroupIfActive(device);
    await device.send(FretCommand.musicMode, <int>[mode.code, ...extraParams]);
  }

  /// Set the active microphone / pickup source.
  ///
  /// The firmware uses this to decide which audio input drives the
  /// voice-reactive LED pipeline. Pass [MicSource.off] to disable.
  Future<void> setMicSource(FretDevice device, MicSource source) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    await device.send(FretCommand.micSource, <int>[source.code]);
  }

  /// Enable or disable voice-reactive mode. Pass `true` to turn on.
  Future<void> setVoiceMode(FretDevice device, {required bool on}) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    await device.send(FretCommand.voiceMode, <int>[on ? 0x00 : 0xFF]);
  }

  /// Set voice-reactive sensitivity. Range 0–255.
  ///
  /// Higher values make the LED react to quieter sounds. Rapid calls are
  /// safe; the SDK only sends the latest value.
  Future<void> setVoiceSensitivity(FretDevice device, int value) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    if (value < 0 || value > 255) {
      throw ArgumentError('voice sensitivity must be 0..255, got $value');
    }
    await device.send(FretCommand.voiceSensitivity, <int>[value]);
  }

  /// Inject a single audio-energy sample from the APP microphone.
  ///
  /// [volume] is a 16-bit unsigned value (0–65535) representing the
  /// current RMS / peak amplitude measured by the APP. The firmware
  /// uses it to drive LED brightness when [MicSource.appMic] is active.
  ///
  /// Call this at ~30–60 Hz while the APP is capturing audio.
  /// High-frequency calls are safe; the SDK optimizes automatically.
  Future<void> injectEnergy(FretDevice device, int volume) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    if (volume < 0 || volume > 0xFFFF) {
      throw ArgumentError('volume must be 0..65535, got $volume');
    }
    await device.send(FretCommand.energyInject, <int>[
      (volume >> 8) & 0xFF,
      volume & 0xFF,
    ]);
  }

  // === Group-color channel ===
  //
  // The firmware exposes a second render channel ("group channel") where
  // LEDs are partitioned into named groups and each group is assigned a
  // single color. This is more efficient than per-pixel writes when the
  // desired image has large contiguous color regions (e.g. each guitar
  // string a different color, or a chord split into root/third/fifth).
  //
  // The SDK tracks per-device group state so that any non-group command
  // (setPower / setColor / lightNote / ...) automatically emits a cleanup
  // frame first. Brand apps normally only need [applyGroupFrame]; the
  // lower-level methods are exposed for advanced use cases.

  /// Render a complete group-color frame in a single batched transaction.
  ///
  /// [groupAssignments] maps each LED index (0-based, after left-handed
  /// mirroring) to a group ID in 1..255. LEDs not in the map (or mapped
  /// to 0) are not assigned to any group and render black.
  ///
  /// [groupColors] maps each group ID to its color. Groups referenced in
  /// [groupAssignments] but missing from [groupColors] default to black.
  ///
  /// No intermediate black flash is produced because the firmware switches
  /// from the previous image directly to the new group-color image inside
  /// the batched transaction.
  Future<void> applyGroupFrame(
    FretDevice device, {
    required Map<int, int> groupAssignments,
    required Map<int, FretColor> groupColors,
  }) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    if (groupAssignments.isEmpty) {
      await clearGroupMap(device);
      return;
    }

    // 1. Enter batch mode (forces group-color render path + clears virt pixels).
    await _forceGroupState4(device);
    _groupActive[device.id] = true;

    // 2. Build a contiguous group-map array starting at the lowest LED
    //    index. Gaps are filled with groupId=0 (no group -> black).
    final sortedIdx = groupAssignments.keys.toList()..sort();
    final baseIdx = sortedIdx.first;
    final lastIdx = sortedIdx.last;
    final groupIds = List<int>.filled(lastIdx - baseIdx + 1, 0);
    for (int i = 0; i < groupIds.length; i++) {
      final gid = groupAssignments[baseIdx + i];
      if (gid != null && gid > 0 && gid <= 255) {
        groupIds[i] = gid;
      }
    }
    await device.send(FretCommand.groupMap, <int>[baseIdx, ...groupIds]);

    // 3. Set color for each unique group referenced in the assignment.
    final usedGroups = <int>{...groupIds.where((g) => g != 0)};
    for (final gid in usedGroups) {
      final color = groupColors[gid] ?? FretColor.black;
      await device.send(FretCommand.groupColor, <int>[
        gid,
        color.r,
        color.g,
        color.b,
      ]);
    }

    // 4. End batch — firmware refreshes once with the new image.
    await device.send(FretCommand.batchEnd, <int>[]);
  }

  /// Set the color of a single group.
  ///
  /// Low-level escape hatch. Use this only when you need to update one
  /// group's color without re-sending the entire group map. The firmware
  /// must already be in group-color mode (call [applyGroupFrame] first).
  ///
  /// After calling this, the LED panel is NOT refreshed until you call
  /// [flushGroupImmediate] or end a batch. For most cases, prefer
  /// [applyGroupFrame].
  Future<void> setGroupColor(
    FretDevice device,
    int groupId,
    FretColor color,
  ) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    if (groupId < 0 || groupId > 255) {
      throw ArgumentError('groupId must be 0..255, got $groupId');
    }
    await _markGroupActive(device);
    await device.send(FretCommand.groupColor, <int>[
      groupId,
      color.r,
      color.g,
      color.b,
    ]);
  }

  /// Assign LEDs to groups.
  ///
  /// Low-level escape hatch. The list [groupIds] is interpreted as:
  /// `groupIds[i]` is the group ID of the LED at index `baseIdx + i`.
  /// A groupId of 0 means "no group" (renders black).
  ///
  /// After calling this, the firmware is in group-color mode and any
  /// non-group command from the SDK will emit a cleanup frame first
  /// (see [_clearGroupIfActive]).
  Future<void> applyGroupMap(
    FretDevice device,
    int baseIdx,
    List<int> groupIds,
  ) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    if (baseIdx < 0 || baseIdx >= 400) {
      throw ArgumentError('baseIdx must be 0..399, got $baseIdx');
    }
    for (final gid in groupIds) {
      if (gid < 0 || gid > 255) {
        throw ArgumentError('groupId must be 0..255, got $gid');
      }
    }
    await _markGroupActive(device);
    await device.send(FretCommand.groupMap, <int>[baseIdx, ...groupIds]);
  }

  /// Clear all group assignments and exit group-color mode.
  ///
  /// This is the public counterpart of the internal cleanup frame. After
  /// calling it, subsequent non-group commands (setColor / fillColor /
  /// lightNote / ...) will not emit a redundant cleanup frame.
  Future<void> clearGroupMap(FretDevice device) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    await device.send(FretCommand.groupMap, <int>[]);
    _groupActive[device.id] = false;
    _groupChannelForced[device.id] = false;
  }

  /// Trigger an immediate LED refresh in the group channel.
  ///
  /// Legacy primitive. The SDK normally uses a batch-end refresh instead,
  /// which is the proper companion to batch-begin. Exposed for
  /// compatibility with older firmware that may not implement the
  /// batch protocol.
  Future<void> flushGroupImmediate(FretDevice device) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    await device.send(FretCommand.groupEnd, <int>[]);
  }

  // === DIY mode list ===

  /// Set the user's "DIY" mode list.
  ///
  /// The firmware ships with 117 built-in effect modes (1..117). Brand
  /// apps can curate a subset as the "DIY list" — only modes in this
  /// list are shown in the APP's mode picker. Pass an empty list to
  /// reset to the firmware default.
  ///
  /// [modeIds] must contain values in 1..117. The list is sent as a
  /// single packet; if it exceeds the firmware frame limit it is
  /// silently truncated.
  Future<void> setDiyModeList(FretDevice device, List<int> modeIds) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    for (final modeId in modeIds) {
      if (modeId < 1 || modeId > 117) {
        throw FretSparkException.validationError(
          'DIY modeId must be 1-117 (got $modeId).',
        );
      }
    }
    final capped = modeIds.length > (FretCommand.bleRxFrameMaxLen - 1)
        ? modeIds.sublist(0, FretCommand.bleRxFrameMaxLen - 1)
        : modeIds;
    await device.send(FretCommand.setDiyModeList, <int>[
      capped.length,
      ...capped,
    ]);
  }

  /// Query the current DIY mode list.
  ///
  /// The firmware responds asynchronously via [FretDevice.onDiyModeList].
  /// Brand apps should subscribe to that stream before calling this
  /// method.
  Future<void> queryDiyModeList(FretDevice device) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    await device.send(FretCommand.queryDiyModeList, <int>[]);
  }

  // === LED index mode ===

  /// Set the LED index order.
  ///
  /// Pass `true` to reverse the firmware's LED indexing (for newer
  /// hardware revisions where the LED strip is wired right-to-left).
  /// The SDK transparently handles left-handed mirroring on top of
  /// this, so callers should pass the device's hardware revision flag.
  ///
  /// Query result and confirmations are delivered via
  /// [FretDevice.onLedIndexModeChanged].
  Future<void> setLedIndexMode(
    FretDevice device, {
    required bool reversed,
  }) async {
    if (!device.isConnected) {
      throw FretSparkException.deviceDisconnected();
    }
    await device.send(FretCommand.setLedIndexMode, <int>[reversed ? 1 : 0]);
  }

  // === Internal: group-channel state machine ===

  /// Emit a cleanup frame once when transitioning out of the group
  /// channel. Resets the group-entry idempotency flag so the next group
  /// entry re-forces the group-color render path.
  Future<void> _clearGroupIfActive(FretDevice device) async {
    if (_groupActive[device.id] == true) {
      await device.send(FretCommand.groupMap, <int>[]);
      _groupActive[device.id] = false;
      _groupChannelForced[device.id] = false;
    }
  }

  /// Force the firmware's group-color render path on. This both:
  /// 1) Switches the render pipeline to the group-color path.
  /// 2) Clears the pixel buffer without an intermediate black flash.
  /// Idempotent until [_clearGroupIfActive] resets the flag.
  Future<void> _forceGroupState4(FretDevice device) async {
    if (_groupChannelForced[device.id] == true) return;
    await device.send(FretCommand.batchBegin, <int>[0]);
    _groupChannelForced[device.id] = true;
  }

  /// Mark the firmware as currently in group-color mode. Used by the
  /// low-level [setGroupColor] / [applyGroupMap] escape hatches. They
  /// do NOT call [_forceGroupState4] themselves because brand apps are
  /// expected to call [applyGroupFrame] (or batch begin directly) first
  /// to set up the batched transaction.
  Future<void> _markGroupActive(FretDevice device) async {
    _groupActive[device.id] = true;
  }

  Future<void> _clearSelection(FretDevice device) async {
    await device.send(FretCommand.selectionMask, <int>[]);
  }

  /// Encode a (string, fret) pair into a firmware LED index, applying
  /// left-handed mirroring. Returns `null` if out of bounds.
  int? _encodeLedIndex(FretDevice device, int string, int fret) {
    if (string < 0 || string > 5) return null;
    if (fret < 0 || fret > device.maxFret) return null;
    final mirroredString = _leftHanded ? (5 - string) : string;
    return fret * 6 + mirroredString;
  }

  /// Mirror a raw LED index (used when callers already have an absolute
  /// index). Internal helper for tests.
  @visibleForTesting
  int mirrorLedIndex(FretDevice device, int ledIndex) {
    if (!_leftHanded) return ledIndex;
    final fret = ledIndex ~/ 6;
    final stringOffset = ledIndex % 6;
    return fret * 6 + (5 - stringOffset);
  }
}

/// Audio input source for voice-reactive LED mode.
enum MicSource {
  /// APP-side microphone. Requires the brand APP to capture audio and
  /// feed energy samples via [FretLED.injectEnergy] at 30–60 Hz.
  appMic(0x00),

  /// Device-local microphone (built into the guitar hardware).
  localMic(0x01),

  /// Vibration / pickup sensor (piezo) on the hardware.
  vibration(0x06),

  /// Disable voice input entirely.
  off(0xFF);

  final int code;
  const MicSource(this.code);
}

/// High-level music mode.
///
/// This is distinct from the AI rhythm LED *effects* (modes 124–135),
/// which are sent via the standard [FretLED.setMode] command. This sets
/// the firmware's overall music operating mode and accepts mode-specific
/// extra parameters.
enum MusicMode {
  /// Normal operation — no special music mode active.
  normal(0x00),

  /// Built-in metronome. Extra params: `[bpmH, bpmL, timeSig]`.
  metronome(0x01),

  /// Looper mode. Extra params: firmware-defined.
  looper(0x02),

  /// Drum machine mode. Extra params: firmware-defined.
  drums(0x03),

  /// Bass accompaniment mode. Extra params: firmware-defined.
  bass(0x04);

  final int code;
  const MusicMode(this.code);
}
