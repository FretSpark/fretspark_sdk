/// A parsed firmware notification frame.
///
/// Emitted by [FretDevice.onUnknownNotify] for firmware commands not
/// handled by the typed streams. Brand apps inspect [cmd] to decide how
/// to interpret [data].
class FretNotify {
  FretNotify({required this.cmd, required this.data});

  /// Firmware command id.
  final int cmd;

  /// Payload bytes (excluding the frame delimiters and length byte).
  final List<int> data;

  @override
  String toString() =>
      'FretNotify(cmd=0x${cmd.toRadixString(16).padLeft(2, '0')}, '
      'data=${data.length} bytes)';
}

/// Latest battery reading parsed from a firmware notify frame.
class FretBattery {
  /// Battery level (0-100).
  final int level;

  /// Battery voltage in millivolts.
  final int voltageMv;

  const FretBattery({required this.level, required this.voltageMv});

  @override
  String toString() => 'FretBattery($level%, ${voltageMv}mV)';
}

/// Firmware version parsed from a firmware notify frame.
class FretFirmwareVersion {
  final int major;
  final int minor;
  final int revision;
  final int subCode;

  const FretFirmwareVersion({
    required this.major,
    required this.minor,
    required this.revision,
    required this.subCode,
  });

  /// Dot-separated version string (e.g. `1.2.3.4`).
  String get formatted => '$major.$minor.$revision.$subCode';

  @override
  String toString() => 'FretFirmwareVersion($formatted)';
}
