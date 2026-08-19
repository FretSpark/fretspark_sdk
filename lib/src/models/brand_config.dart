import 'package:flutter/foundation.dart';

/// A FretSpark-compatible brand configuration.
///
/// Brand apps must call `FretSpark.initialize(brandId: ...)` with one of the
/// IDs returned by [BrandConfig.id]. The SDK uses [firmwarePatterns] to
/// filter BLE scan results so that a brand's app only sees its own devices.
@immutable
class BrandConfig {
  /// Brand unique identifier (lowercase English, e.g. `fretspark`, `smiger`).
  final String id;

  /// Display name shown in the brand app's UI.
  final String displayName;

  /// Device model label (e.g. `FS-86 PRO`, `SCT-86 PRO`).
  final String deviceModel;

  /// Customer support email.
  final String email;

  /// Regex patterns that match this brand's firmware BLE advertising names.
  /// Patterns are case-insensitive. The first matching brand in the list wins.
  final List<String> firmwarePatterns;

  /// Prefix used by the firmware when advertising in OTA mode
  /// (e.g. `SCT-86PRO OTA`). Used by [FretOTA.scanOtaDevice].
  final String? otaNamePrefix;

  /// Whether this brand is currently enabled in the cloud config.
  final bool enabled;

  const BrandConfig({
    required this.id,
    required this.displayName,
    required this.deviceModel,
    this.email = 'auphy@auphymusic.com',
    required this.firmwarePatterns,
    this.otaNamePrefix,
    this.enabled = true,
  });

  factory BrandConfig.fromJson(Map<String, dynamic> json) => BrandConfig(
        id: json['id'] as String,
        displayName: json['display_name'] as String,
        deviceModel:
            (json['device_model'] as String?) ?? json['product_model'] as String? ?? '',
        email: (json['email'] as String?) ?? 'auphy@auphymusic.com',
        firmwarePatterns:
            (json['firmware_patterns'] as List).map((e) => e as String).toList(),
        otaNamePrefix: json['ota_name_prefix'] as String?,
        enabled: (json['enabled'] as bool?) ?? true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'display_name': displayName,
        'device_model': deviceModel,
        'email': email,
        'firmware_patterns': firmwarePatterns,
        if (otaNamePrefix != null) 'ota_name_prefix': otaNamePrefix,
        'enabled': enabled,
      };

  /// Test whether [firmwareName] matches any of [firmwarePatterns].
  bool matches(String firmwareName) {
    if (firmwareName.isEmpty) return false;
    final upper = firmwareName.toUpperCase();
    for (final p in firmwarePatterns) {
      if (RegExp(p.toUpperCase()).hasMatch(upper)) return true;
    }
    return false;
  }

  @override
  String toString() =>
      'BrandConfig(id=$id, displayName=$displayName, deviceModel=$deviceModel)';
}
