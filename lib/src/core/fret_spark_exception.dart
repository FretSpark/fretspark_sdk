/// Unified exception type for all FretSpark SDK errors.
///
/// Brand apps can catch [FretSparkException] to handle all SDK errors
/// in a uniform way, or catch specific [code] values for fine-grained
/// handling.
class FretSparkException implements Exception {
  FretSparkException(this.code, this.message, [this.deviceId]);

  /// The error code categorizing this error.
  final FretSparkErrorCode code;

  /// Human-readable description of the error.
  final String message;

  /// The device id this error relates to, if applicable.
  final String? deviceId;

  /// Create a device-disconnected error.
  factory FretSparkException.deviceDisconnected([String? deviceId]) =>
      FretSparkException(
        FretSparkErrorCode.deviceDisconnected,
        'Device is not connected or has been disposed.',
        deviceId,
      );

  /// Create a not-initialized error.
  factory FretSparkException.notInitialized() => FretSparkException(
        FretSparkErrorCode.notInitialized,
        'FretSpark.instance is not initialized. Call FretSpark.instance.initialize(...) first.',
      );

  /// Create a permission-denied error.
  factory FretSparkException.permissionDenied(String detail) =>
      FretSparkException(
        FretSparkErrorCode.permissionDenied,
        'Bluetooth permission denied: $detail',
      );

  /// Create an adapter-off error.
  factory FretSparkException.adapterOff() => FretSparkException(
        FretSparkErrorCode.adapterOff,
        'Bluetooth adapter is off. Please turn on Bluetooth.',
      );

  /// Create an OTA error.
  factory FretSparkException.otaError(String detail) => FretSparkException(
        FretSparkErrorCode.otaError,
        'OTA upgrade failed: $detail',
      );

  /// Create a validation error (invalid parameter).
  factory FretSparkException.validationError(String detail) =>
      FretSparkException(
        FretSparkErrorCode.validationError,
        'Parameter validation failed: $detail',
      );

  /// Create a connection error.
  factory FretSparkException.connectionError(String detail) =>
      FretSparkException(
        FretSparkErrorCode.connectionError,
        'BLE connection failed: $detail',
      );

  @override
  String toString() {
    final id = deviceId != null ? ' (device: $deviceId)' : '';
    return 'FretSparkException($code): $message$id';
  }
}

/// Error codes for [FretSparkException].
enum FretSparkErrorCode {
  /// FretSpark.instance.initialize() has not been called.
  notInitialized,

  /// A required Bluetooth permission was denied.
  permissionDenied,

  /// The Bluetooth adapter is off.
  adapterOff,

  /// A BLE connection failed or timed out.
  connectionError,

  /// The device is not connected or has been disposed.
  deviceDisconnected,

  /// An OTA upgrade operation failed.
  otaError,

  /// A parameter failed validation (out of range, invalid format, etc.).
  validationError,
}
