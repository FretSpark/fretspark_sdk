library;

import '../models/fret_note.dart';

/// Built-in chord dictionary (60+ common voicings).
///
/// Each chord type is stored as a fret pattern across the 6 strings
/// (string 0 = high E, string 5 = low E). `-1` means "do not play this
/// string"; `0` means "open string"; `n > 0` means "press fret n".
///
/// The patterns are first-position "cowboy chord" voicings that fit
/// within 14 frets and light a sensible number of LEDs per chord. For
/// full-neck chord lookup, brand apps should bundle their own chord
/// database and call [FretLED.lightNotes] directly.

/// Lookup the fret pattern for [root] + [chordType].
///
/// [chordType] is one of: `maj`, `min`, `7`, `maj7`, `m7`, `dim`, `aug`,
/// `sus2`, `sus4`, `6`, `m6`, `9`, `add9`, `11`, `13`.
///
/// Returns a 6-element list `[fret_low_E, fret_A, fret_D, fret_G, fret_B,
/// fret_high_E]` indexed by string number (string 0 = high E per the
/// FretNote convention), or `null` if the chord is unknown.
///
/// Internally the dictionary is keyed by (root, type) on a 12-TET grid
/// using the open-position voicing for the closest root, then transposed
/// by shifting fret numbers. Voicings that exceed fret 13 after
/// transposition are wrapped to the next octave by subtracting 12 from
/// each non-open, non-muted fret.
class ChordDictionary {
  ChordDictionary._();

  /// Open-position voicings relative to root = C (semitone 0).
  /// Index 0 = high E (string 0), index 5 = low E (string 5).
  /// -1 = muted, 0 = open.
  static const Map<String, List<int>> _openVoicings = <String, List<int>>{
    // C major: x32010
    'maj': <int>[0, 1, 0, 2, 3, -1],
    // C minor (barre at 3rd fret A-shape): x35543
    'min': <int>[3, 4, 5, 5, 3, -1],
    // C7: x32310
    '7': <int>[0, 1, 3, 2, 3, -1],
    // Cmaj7: x32000
    'maj7': <int>[0, 0, 0, 2, 3, -1],
    // Cm7: x35343
    'm7': <int>[3, 4, 3, 5, 3, -1],
    // Cdim: x3424x (close voicing)
    'dim': <int>[-1, 4, 2, 4, 3, -1],
    // Caug: x32110
    'aug': <int>[0, 1, 1, 2, 3, -1],
    // Csus2: x35533 (barre)
    'sus2': <int>[3, 3, 5, 5, 3, -1],
    // Csus4: x33011
    'sus4': <int>[1, 1, 0, 3, 3, -1],
    // C6: x32210
    '6': <int>[0, 1, 2, 2, 3, -1],
    // Cm6: x3212x
    'm6': <int>[-1, 2, 1, 2, 3, -1],
    // C9: x32330
    '9': <int>[0, 3, 3, 2, 3, -1],
    // Cadd9: x32030
    'add9': <int>[0, 3, 0, 2, 3, -1],
    // C11: x33333
    '11': <int>[3, 3, 3, 3, 3, -1],
    // C13: x32335 (close)
    '13': <int>[5, 3, 3, 2, 3, -1],
  };

  /// Returns the fret pattern for [root] + [chordType], or `null`.
  static List<int>? fingering(NoteName root, String chordType) {
    final base = _openVoicings[chordType.toLowerCase()];
    if (base == null) return null;
    final shift = root.semitone;
    if (shift == 0) return List<int>.from(base);

    // Transpose: add `shift` to each non-muted, non-open fret. Wrap
    // values > 13 by subtracting 12 (next-octave open-position shape).
    final result = List<int>.from(base);
    for (int i = 0; i < result.length; i++) {
      final f = result[i];
      if (f <= 0) continue; // muted or open
      var nf = f + shift;
      if (nf > 13) nf -= 12;
      result[i] = nf;
    }
    return result;
  }

  /// All supported chord type names (lowercase).
  static List<String> get knownTypes =>
      _openVoicings.keys.toList(growable: false);
}
