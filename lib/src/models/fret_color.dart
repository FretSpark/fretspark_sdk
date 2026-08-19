import 'package:flutter/foundation.dart';

/// An RGB color used for fretboard LEDs.
@immutable
class FretColor {
  final int r; // 0-255
  final int g; // 0-255
  final int b; // 0-255

  const FretColor(this.r, this.g, this.b);

  /// Black (off).
  static const FretColor black = FretColor(0, 0, 0);

  /// Pure white.
  static const FretColor white = FretColor(255, 255, 255);

  /// Pure red.
  static const FretColor red = FretColor(255, 0, 0);

  /// Pure green.
  static const FretColor green = FretColor(0, 255, 0);

  /// Pure blue.
  static const FretColor blue = FretColor(0, 0, 255);

  /// Magenta.
  static const FretColor magenta = FretColor(255, 0, 255);

  /// Cyan.
  static const FretColor cyan = FretColor(0, 255, 255);

  /// Yellow.
  static const FretColor yellow = FretColor(255, 255, 0);

  /// Construct from a 0xRRGGBB integer.
  factory FretColor.fromRgbInt(int value) => FretColor(
        (value >> 16) & 0xFF,
        (value >> 8) & 0xFF,
        value & 0xFF,
      );

  /// Convert to a 0xRRGGBB integer.
  int toRgbInt() => (r << 16) | (g << 8) | b;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FretColor && r == other.r && g == other.g && b == other.b;

  @override
  int get hashCode => Object.hash(r, g, b);

  @override
  String toString() =>
      'FretColor(#${toRgbInt().toRadixString(16).padLeft(6, '0').toUpperCase()})';
}

/// HSL color, used by the firmware's color command.
/// Hue: 0-360, Saturation: 0-1000.
@immutable
class FretHsl {
  final int hue;
  final int saturation;
  const FretHsl(this.hue, this.saturation);

  /// Red.
  static const FretHsl red = FretHsl(0, 1000);

  /// Green.
  static const FretHsl green = FretHsl(120, 1000);

  /// Blue.
  static const FretHsl blue = FretHsl(240, 1000);
}
