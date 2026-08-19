import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api/fret_brand.dart';
import 'api/fret_classroom.dart';
import 'api/fret_connection.dart';
import 'api/fret_firmware.dart';
import 'api/fret_led.dart';
import 'api/fret_metronome.dart';
import 'api/fret_ota.dart';
import 'transport/flutter_blue_transport.dart';
import 'transport/fret_transport.dart';

// This file is the SDK's internal bootstrap. FretSpark.initialize() wires
// up the sub-APIs by calling their @visibleForTesting setters/loaders, which
// are not meant for brand-app use but are required during normal init.
// ignore_for_file: invalid_use_of_visible_for_testing_member

/// Top-level singleton entry point for the FretSpark SDK.
///
/// Brand apps call [initialize] once at startup, then access the various
/// sub-APIs through the getters:
///
/// ```dart
/// await FretSpark.instance.initialize(brandId: 'auphy');
/// final device = await FretSpark.instance.connection.connect(deviceId);
/// FretSpark.instance.led.fillColor(device, FretColor.red);
/// ```
///
/// The singleton is intentionally a single-instance class: most brand
/// apps only manage one brand+device at a time. For multi-brand apps,
/// create separate [FretSpark] instances via the private constructor
/// (contribute a public `FretSpark.new(...)` factory if you need this).
class FretSpark {
  FretSpark._();

  static final FretSpark _instance = FretSpark._();

  /// The shared singleton.
  static FretSpark get instance => _instance;

  bool _initialized = false;
  late final SharedPreferences _prefs;
  late final FretTransport _transport;
  late final FretBrand _brand;
  late final FretConnection _connection;
  late final FretLED _led;
  late final FretOTA _ota;
  late final FretMetronome _metronome;
  late final FretClassroom _classroom;
  late final FretFirmwareDownloader _firmware;

  /// Optional default manifest URL for [FretFirmwareDownloader]. Set
  /// via [initialize]. When `null`, brand apps must pass `manifestUrl`
  /// explicitly to every firmware call.
  String? _manifestUrl;

  /// Optional default brand-config URL for [FretBrand.syncFromCloudUrl].
  String? _brandConfigUrl;

  /// Whether [initialize] has been called.
  bool get isInitialized => _initialized;

  /// Initialize the SDK.
  ///
  /// - [brandId]: required. The brand's [BrandConfig.id] (e.g. `auphy`).
  ///   The SDK loads the bundled `brands_fallback.json` first; if you
  ///   have a cloud config, call [FretBrand.syncFromCloud] after this
  ///   returns.
  /// - [transport]: optional. Defaults to the default BLE transport. Pass
  ///   a custom [FretTransport] implementation to use a different BLE
  ///   stack.
  /// - [licenseKey]: optional. Reserved for future commercial licensing;
  ///   currently unused.
  Future<void> initialize({
    required String brandId,
    FretTransport? transport,
    String? licenseKey,
    String? manifestUrl,
    String? brandConfigUrl,
  }) async {
    if (_initialized) {
      throw StateError('FretSpark.instance is already initialized');
    }
    _prefs = await SharedPreferences.getInstance();
    _transport = transport ?? FlutterBlueTransport();
    _brand = FretBrand();
    await _brand.loadFallback();
    // If a cloud brand-config URL is provided, fetch it (with cache +
    // version check). Network failure is non-fatal; fallback remains.
    if (brandConfigUrl != null && brandConfigUrl.isNotEmpty) {
      await _brand.syncFromCloudUrl(brandConfigUrl);
    }
    // Try to restore the previously-saved active brand. If the cache is
    // empty (first launch), fall back to the explicitly-passed [brandId].
    await _brand.loadActiveFromCache();
    if (_brand.activeBrand == null && brandId.isNotEmpty) {
      await _brand.setActive(brandId);
    }
    _brandConfigUrl = brandConfigUrl;
    _connection = FretConnection(_transport)
      ..setActiveBrand(_brand.activeBrand)
      ..setBrandMatcher((name) => _brand.matchByFirmwareName(name));
    // Persist auto-detected brand changes.
    _connection.onBrandAutoDetected.listen((brand) {
      _brand.setActive(brand.id);
    });
    _led = FretLED(_prefs);
    await _led.loadPersistedState();
    _ota = FretOTA();
    _metronome = FretMetronome();
    _classroom = FretClassroom();
    _firmware = FretFirmwareDownloader();
    _manifestUrl = manifestUrl;
    _initialized = true;
  }

  /// Reset the singleton to its pre-initialize state. Mostly useful in
  /// tests.
  @visibleForTesting
  Future<void> dispose() async {
    if (!_initialized) return;
    await _connection.disconnect();
    _ota.dispose();
    _initialized = false;
  }

  // === Sub-API getters ===

  /// Brand configuration.
  FretBrand get brand {
    _checkInit();
    return _brand;
  }

  /// Connection / scan.
  FretConnection get connection {
    _checkInit();
    return _connection;
  }

  /// LED control.
  FretLED get led {
    _checkInit();
    return _led;
  }

  /// OTA firmware upgrade.
  FretOTA get ota {
    _checkInit();
    return _ota;
  }

  /// Firmware metronome.
  FretMetronome get metronome {
    _checkInit();
    return _metronome;
  }

  /// Classroom / local-teaching mode.
  FretClassroom get classroom {
    _checkInit();
    return _classroom;
  }

  /// Firmware downloader (HTTP manifest + file cache).
  ///
  /// Requires [initialize]'s optional `manifestUrl` parameter to be
  /// set; otherwise brand apps must pass `manifestUrl` explicitly to
  /// each downloader method.
  FretFirmwareDownloader get firmware {
    _checkInit();
    return _firmware;
  }

  /// The default manifest URL configured at [initialize], or `null`.
  String? get manifestUrl => _manifestUrl;

  /// The default brand-config URL configured at [initialize], or `null`.
  String? get brandConfigUrl => _brandConfigUrl;

  /// The underlying transport, exposed for advanced brand apps that need
  /// to access BLE-specific operations (e.g. reading the adapter state).
  FretTransport get transport {
    _checkInit();
    return _transport;
  }

  void _checkInit() {
    if (!_initialized) {
      throw StateError(
        'FretSpark.instance is not initialized. Call FretSpark.instance.initialize(...) first.',
      );
    }
  }
}
