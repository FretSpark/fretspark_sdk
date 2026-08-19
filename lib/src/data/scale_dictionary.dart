library;

import '../models/fret_note.dart';

/// Lookup table for the 10 [ScaleType]s supported by [FretLED.showScale].
///
/// Each scale is stored as the set of semitone offsets from the root
/// (0–11). The root pitch is always 0 (included in every scale except
/// where the formula naturally omits it).

class ScaleDictionary {
  ScaleDictionary._();

  /// Returns the semitone offsets (0–11) for [scale], or `null` if the
  /// scale is unknown.
  static List<int>? intervals(ScaleType scale) {
    switch (scale) {
      case ScaleType.major:
        return const <int>[0, 2, 4, 5, 7, 9, 11];
      case ScaleType.naturalMinor:
        return const <int>[0, 2, 3, 5, 7, 8, 10];
      case ScaleType.harmonicMinor:
        return const <int>[0, 2, 3, 5, 7, 8, 11];
      case ScaleType.melodicMinor:
        // Jazz melodic minor (ascending form, used both directions).
        return const <int>[0, 2, 3, 5, 7, 9, 11];
      case ScaleType.majorPentatonic:
        return const <int>[0, 2, 4, 7, 9];
      case ScaleType.minorPentatonic:
        return const <int>[0, 3, 5, 7, 10];
      case ScaleType.blues:
        return const <int>[0, 3, 5, 6, 7, 10];
      case ScaleType.dorian:
        return const <int>[0, 2, 3, 5, 7, 9, 10];
      case ScaleType.mixolydian:
        return const <int>[0, 2, 4, 5, 7, 9, 10];
      case ScaleType.chromatic:
        return const <int>[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
    }
  }
}
