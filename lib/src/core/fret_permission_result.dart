/// Result of a Bluetooth permission request.
///
/// Distinguishes between the possible outcomes so brand apps can
/// show appropriate UI (e.g. "go to Settings" for permanent denial).
class FretPermissionResult {
  FretPermissionResult._({
    required this.granted,
    this.reason = FretPermissionDeniedReason.unknown,
  });

  /// Whether all required permissions were granted.
  final bool granted;

  /// When [granted] is false, the reason why.
  final FretPermissionDeniedReason reason;

  /// All permissions granted.
  factory FretPermissionResult.granted() =>
      FretPermissionResult._(granted: true);

  /// Permission denied by the user.
  factory FretPermissionResult.denied(
          [FretPermissionDeniedReason reason =
              FretPermissionDeniedReason.userDenied]) =>
      FretPermissionResult._(granted: false, reason: reason);

  @override
  String toString() => granted
      ? 'FretPermissionResult(granted)'
      : 'FretPermissionResult(denied: $reason)';
}

/// Reasons why Bluetooth permission was denied.
enum FretPermissionDeniedReason {
  /// User denied the permission (can ask again).
  userDenied,

  /// User permanently denied (must go to system Settings).
  permanentlyDenied,

  /// Bluetooth adapter is off.
  adapterOff,

  /// The platform does not support Bluetooth.
  notSupported,

  /// Unknown reason.
  unknown,
}
