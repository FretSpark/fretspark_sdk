import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/brand_config.dart';

/// Brand configuration loader with cloud sync.
///
/// Resolves the active brand's [BrandConfig] at app startup. Loading
/// strategy (mirrors the OTA firmware downloader):
///
/// 1. **Built-in fallback** (`assets/brands_fallback.json`) — always
///    available, ships with the SDK. Contains the six FretSpark-
///    compatible brands (FretSpark, AUPHY, Smiger, NATASHA, Bullfighter,
///    Deviser).
/// 2. **Local cache** (SharedPreferences) — the last successfully-fetched
///    cloud config. Survives app restarts.
/// 3. **Cloud** ([syncFromCloudUrl]) — fresh config from your OTA server
///    (e.g. `partner.json`). Version-checked; skipped if the version
///    number hasn't changed.
///
/// Brand apps typically call `FretSpark.initialize(brandConfigUrl: ...)`
/// and the SDK runs all three layers automatically.
class FretBrand {
  FretBrand();

  final Map<String, BrandConfig> _brands = <String, BrandConfig>{};
  BrandConfig? _active;

  // === Cloud sync state ===
  static const String _kCacheKey = 'fretspark.brand.cache';
  static const String _kVersionKey = 'fretspark.brand.remote_version';
  static const String _kActiveBrandKey = 'fretspark.brand.active_id';
  int? _remoteVersion;

  /// All known brands, keyed by [BrandConfig.id].
  Map<String, BrandConfig> get allBrands =>
      Map<String, BrandConfig>.unmodifiable(_brands);

  /// The currently-active brand. Set by [setActive] or by
  /// `FretSpark.initialize`.
  BrandConfig? get activeBrand => _active;

  /// Load the bundled `brands_fallback.json` into [allBrands].
  /// Safe to call multiple times; later calls replace the map.
  Future<void> loadFallback() async {
    final raw = await rootBundle.loadString(
      'packages/fretspark_sdk/assets/brands_fallback.json',
    );
    final json = jsonDecode(raw) as Map<String, dynamic>;
    _applyJson(json);
  }

  /// Replace the in-memory brand list with a cloud-fetched payload.
  /// The payload must match the `brands_fallback.json` schema:
  /// `{ "version": int, "list": [ {id, display_name, ...}, ... ] }`.
  Future<void> syncFromCloud(String jsonPayload) async {
    final json = jsonDecode(jsonPayload) as Map<String, dynamic>;
    _applyJson(json);
  }

  /// Fetch brand config from [url], with caching and version checking.
  ///
  /// Layers (in order):
  /// 1. If [allBrands] is empty, load the bundled fallback first.
  /// 2. Load the local cache (so the brand list is usable immediately).
  /// 3. HTTP GET [url] with [timeout]. If the cloud `version` field
  ///    matches the cached version, skip. Otherwise apply the new config
  ///    and save it to cache.
  ///
  /// Returns `true` if the cloud config was freshly applied, `false` if
  /// the version was unchanged or the fetch failed (in which case the
  /// cache/fallback remains active).
  Future<bool> syncFromCloudUrl(
    String url, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    // 1. Ensure fallback is loaded so _brands is never empty.
    if (_brands.isEmpty) {
      await loadFallback();
    }

    // 2. Load cached config (if any).
    await _loadFromCache();

    // 3. Fetch from cloud.
    try {
      final response = await http.get(Uri.parse(url)).timeout(timeout);
      if (response.statusCode != 200) return false;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final version = data['version'] as int?;

      // Version check: skip if same as cached.
      if (_remoteVersion != null && version == _remoteVersion) {
        return false;
      }

      _applyJson(data);
      _remoteVersion = version;

      // Save to cache.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCacheKey, response.body);
      if (version != null) {
        await prefs.setInt(_kVersionKey, version);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Set the active brand by id. Throws [ArgumentError] if the brand is
  /// not in [allBrands] or is disabled. Persists the choice to
  /// SharedPreferences so it survives app restarts.
  Future<void> setActive(String brandId) async {
    final brand = _brands[brandId];
    if (brand == null) {
      throw ArgumentError(
          'Unknown brand: $brandId. Call loadFallback() first.');
    }
    if (!brand.enabled) {
      throw StateError('Brand $brandId is disabled in the current config');
    }
    _active = brand;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kActiveBrandKey, brandId);
  }

  /// Load the previously-saved active brand from SharedPreferences.
  /// Called by `FretSpark.initialize`.
  @visibleForTesting
  Future<void> loadActiveFromCache() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_kActiveBrandKey);
    if (id != null && _brands.containsKey(id)) {
      _active = _brands[id];
    }
  }

  /// Find the brand whose [BrandConfig.firmwarePatterns] match
  /// [firmwareName]. Returns `null` if no brand matches.
  BrandConfig? matchByFirmwareName(String firmwareName) {
    for (final brand in _brands.values) {
      if (brand.enabled && brand.matches(firmwareName)) return brand;
    }
    return null;
  }

  /// Auto-detect the brand from a connected device's BLE advertised name.
  ///
  /// If a matching brand is found AND differs from the current
  /// [activeBrand], switches [activeBrand] to the matched brand and
  /// persists the choice. Returns the matched brand (or `null`).
  ///
  /// Called by [FretConnection.connect] after the BLE connection is
  /// established. Brand apps normally don't call this directly.
  @visibleForTesting
  Future<BrandConfig?> autoDetectFromDeviceName(String deviceName) async {
    final matched = matchByFirmwareName(deviceName);
    if (matched == null) return null;
    if (_active?.id != matched.id) {
      _active = matched;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kActiveBrandKey, matched.id);
    }
    return matched;
  }

  // === Internal ===

  void _applyJson(Map<String, dynamic> json) {
    final list = (json['list'] as List?)?.cast<Map<String, dynamic>>();
    if (list == null || list.isEmpty) return;
    _brands
      ..clear()
      ..addEntries(
        list.map((e) => MapEntry(e['id'] as String, BrandConfig.fromJson(e))),
      );
  }

  Future<void> _loadFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _remoteVersion = prefs.getInt(_kVersionKey);
      final cacheStr = prefs.getString(_kCacheKey);
      if (cacheStr == null || cacheStr.isEmpty) return;
      final data = jsonDecode(cacheStr) as Map<String, dynamic>;
      _applyJson(data);
    } catch (_) {
      // Cache corruption is non-fatal; fallback remains.
    }
  }
}
