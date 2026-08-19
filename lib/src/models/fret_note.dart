import 'package:flutter/foundation.dart';

import 'fret_color.dart';

/// A single lit note on the fretboard.
///
/// [string] is 0-indexed from the highest pitch (high E = 0) to the lowest
/// (low E = 5), matching standard tablature convention. If the SDK is in
/// left-handed mode, the string index is mirrored to 5 - [string] before
/// being sent to the firmware, so callers always use right-handed numbering.
///
/// [fret] is 0-indexed (0 = open string, 1 = first fret, ...). The maximum
/// valid value is `device.maxFret` (e.g. 13 for a 14-fret board, 20 for a
/// 21-fret board).
@immutable
class FretNote {
  final int string;
  final int fret;
  final FretColor color;

  const FretNote({
    required this.string,
    required this.fret,
    this.color = FretColor.white,
  })  : assert(string >= 0 && string <= 5, 'string must be 0..5'),
        assert(fret >= 0, 'fret must be >= 0');

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FretNote &&
          string == other.string &&
          fret == other.fret &&
          color == other.color;

  @override
  int get hashCode => Object.hash(string, fret, color);

  @override
  String toString() => 'FretNote(string=$string, fret=$fret, color=$color)';
}

/// Scale types supported by [FretLED.showScale].
enum ScaleType {
  major,
  naturalMinor,
  harmonicMinor,
  melodicMinor,
  majorPentatonic,
  minorPentatonic,
  blues,
  dorian,
  mixolydian,
  chromatic,
}

/// Music note names used for chord/scale root lookup.
enum NoteName {
  c, cSharp, d, dSharp, e, f, fSharp, g, gSharp, a, aSharp, b;
}

extension NoteNameParser on NoteName {
  static NoteName? parse(String name) {
    switch (name.toUpperCase()) {
      case 'C': return NoteName.c;
      case 'C#': case 'DB': return NoteName.cSharp;
      case 'D': return NoteName.d;
      case 'D#': case 'EB': return NoteName.dSharp;
      case 'E': return NoteName.e;
      case 'F': return NoteName.f;
      case 'F#': case 'GB': return NoteName.fSharp;
      case 'G': return NoteName.g;
      case 'G#': case 'AB': return NoteName.gSharp;
      case 'A': return NoteName.a;
      case 'A#': case 'BB': return NoteName.aSharp;
      case 'B': return NoteName.b;
    }
    return null;
  }

  int get semitone => index;
}
