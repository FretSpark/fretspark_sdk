import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Status of the firmware-update pipeline. Brand apps can listen to
/// [FretFirmwareDownloader.onStatusChanged] and map each value to a
/// localized UI string.
enum FretFirmwareStatus {
  /// Idle — no operation in progress.
  idle,

  /// Fetching the manifest from the OTA server.
  checking,

  /// Manifest fetched successfully. Brand apps usually transition to
  /// [updateAvailable] or [upToDate] based on version comparison.
  checkDone,

  /// The device is already running the latest firmware available on
  /// the server. No download required.
  upToDate,

  /// A newer firmware version is available on the server.
  updateAvailable,

  /// Manifest fetch failed (network error, non-200 status, etc.).
  checkFailed,

  /// Firmware file is being downloaded.
  downloading,

  /// Download completed successfully and the file is ready on disk.
  downloadComplete,

  /// Download failed (network error, disk full, etc.).
  downloadFailed,

  /// A previously-downloaded firmware file is already on disk and
  /// matches the requested brand. No re-download required.
  ready,
}

/// Resolved firmware metadata for a single brand, extracted from the
/// OTA server's `manifest.json`.
class FretFirmwareInfo {
  /// Brand identifier this firmware belongs to (e.g. `auphy`).
  final String brandId;

  /// Firmware version string (e.g. `3.1.3.4`). Compared semver-style
  /// against [FretDevice.firmwareVersion].
  final String version;

  /// Firmware file name on the OTA server (e.g.
  /// `firmware.auphy.3.1.3.4.hex16`). Used to construct the download
  /// URL: `<manifestBaseUrl>/<fileName>`.
  final String fileName;

  /// Expected file size in bytes. Used to validate the download. `0`
  /// means the manifest did not specify a size and validation is
  /// skipped.
  final int size;

  /// BLE advertised-name prefix the device uses while in OTA mode (e.g.
  /// `AUPHY-OTA`). Used by [FretOTA.scanOtaDevice]. May be `null` if
  /// the manifest did not include it; brand apps should fall back to
  /// [BrandConfig.otaNamePrefix].
  final String? otaNamePrefix;

  /// Human-readable release notes. May be `null`.
  final String? releaseNotes;

  const FretFirmwareInfo({
    required this.brandId,
    required this.version,
    required this.fileName,
    required this.size,
    this.otaNamePrefix,
    this.releaseNotes,
  });

  @override
  String toString() =>
      'FretFirmwareInfo($brandId v$version, $fileName, ${size}B)';
}

/// Optional helper that downloads firmware images from an OTA server
/// and caches them on disk.
///
/// The FretSpark SDK deliberately keeps network concerns out of the
/// core [FretOTA] class — [FretOTA] only handles the BLE transfer.
/// This class provides the missing HTTP layer:
///
/// 1. Fetches `manifest.json` from the OTA server.
/// 2. Resolves the firmware file for the active brand.
/// 3. Compares the cloud version against the device version.
/// 4. Downloads the file with progress reporting.
/// 5. Caches it under `getApplicationSupportDirectory()/ota_firmware/`.
/// 6. Cleans up old versions automatically.
///
/// Brand apps that already have their own download infra can ignore
/// this class and call [FretOTA.upgrade] directly with bytes they
/// obtained some other way.
///
/// Manifest format (JSON):
/// ```json
/// {
///   "version": "3.1.3.4",
///   "releaseNotes": "...",
///   "brands": [
///     {
///       "id": "auphy",
///       "version": "3.1.3.4",
///       "file": "firmware.auphy.3.1.3.4.hex16",
///       "size": 245760,
///       "otaNamePrefix": "AUPHY-OTA"
///     },
///     ...
///   ]
/// }
/// ```
///
/// For backwards compatibility, a single-file manifest without a
/// `brands` array is also accepted (in which case [brandId] is ignored
/// and the top-level `file`/`size`/`version` fields are used).
class FretFirmwareDownloader {
  FretFirmwareDownloader();

  // === Local cache layout ===
  static const String _kLocalFwDir = 'fretspark_ota_firmware';
  static const String _kLocalManifestFile = 'manifest.json';

  // === SharedPreferences keys ===
  static const String _kPrefLastCheck = 'fretspark.fw.last_check_time';
  static const String _kPrefCloudVersion = 'fretspark.fw.cloud_version';
  static const String _kPrefLocalBrand = 'fretspark.fw.local_brand_id';

  /// Re-check the cloud manifest at most once per 24 hours. Brand apps
  /// can override this by passing `force: true` to [checkForUpdate].
  static const Duration checkInterval = Duration(hours: 24);

  final StreamController<FretFirmwareStatus> _statusController =
      StreamController<FretFirmwareStatus>.broadcast();

  /// Emits status transitions. Subscribe to drive UI labels / spinners.
  Stream<FretFirmwareStatus> get onStatusChanged => _statusController.stream;

  Map<String, dynamic>? _cachedManifest;
  bool _isChecking = false;
  bool _isDownloading = false;
  double _downloadProgress = 0;

  /// Whether a manifest check is in progress.
  bool get isChecking => _isChecking;

  /// Whether a firmware download is in progress.
  bool get isDownloading => _isDownloading;

  /// Current download progress in `0.0..1.0`. Resets to `0` at the
  /// start of each download.
  double get downloadProgress => _downloadProgress;

  void _setStatus(FretFirmwareStatus s) => _statusController.add(s);

  // === Public API ===

  /// Fetch the manifest from [manifestUrl] and resolve the firmware
  /// entry for [brandId].
  ///
  /// - [force]: bypass the 24-hour throttle and always re-fetch.
  ///
  /// Returns the resolved [FretFirmwareInfo], or `null` if:
  /// - The fetch failed (network / HTTP error).
  /// - The manifest does not contain an entry for [brandId].
  ///
  /// The manifest is cached on disk so that subsequent calls (and
  /// [getLocalFirmwarePath]) work without network access.
  Future<FretFirmwareInfo?> checkForUpdate({
    required String manifestUrl,
    required String brandId,
    bool force = false,
  }) async {
    if (_isChecking) return null;
    if (!force) {
      final should = await _shouldCheckCloud();
      if (!should && _cachedManifest == null) {
        final prefs = await SharedPreferences.getInstance();
        final cachedVersion = prefs.getString(_kPrefCloudVersion) ?? '';
        if (cachedVersion.isNotEmpty) {
          _cachedManifest = <String, dynamic>{'version': cachedVersion};
        }
      }
    }

    _isChecking = true;
    _setStatus(FretFirmwareStatus.checking);
    try {
      final response = await http
          .get(Uri.parse(manifestUrl))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        _setStatus(FretFirmwareStatus.checkFailed);
        return null;
      }
      final manifest = jsonDecode(response.body) as Map<String, dynamic>;
      _cachedManifest = manifest;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        _kPrefLastCheck,
        DateTime.now().millisecondsSinceEpoch,
      );
      await prefs.setString(
        _kPrefCloudVersion,
        (manifest['version'] as String?) ?? '',
      );
      await _saveManifestToLocal(response.body);

      final info = _resolveBrandFirmware(manifest, brandId);
      if (info == null) {
        _setStatus(FretFirmwareStatus.checkFailed);
      } else {
        _setStatus(FretFirmwareStatus.checkDone);
      }
      return info;
    } catch (_) {
      _setStatus(FretFirmwareStatus.checkFailed);
      return null;
    } finally {
      _isChecking = false;
    }
  }

  /// Download the firmware file for [brandId] to the local cache
  /// directory.
  ///
  /// [manifestUrl] is the base URL — the file name from the manifest
  /// is appended to it. [onProgress] is invoked with values in
  /// `0.0..1.0` as bytes arrive.
  ///
  /// Returns the absolute path of the downloaded file, or `null` on
  /// failure.
  Future<String?> download({
    required String manifestUrl,
    required String brandId,
    void Function(double progress)? onProgress,
  }) async {
    if (_isDownloading) return null;

    final manifest = _cachedManifest ?? await _readLocalManifest();
    if (manifest == null) {
      _setStatus(FretFirmwareStatus.downloadFailed);
      return null;
    }
    final info = _resolveBrandFirmware(manifest, brandId);
    if (info == null) {
      _setStatus(FretFirmwareStatus.downloadFailed);
      return null;
    }

    _isDownloading = true;
    _downloadProgress = 0;
    _setStatus(FretFirmwareStatus.downloading);
    try {
      final baseUrl =
          manifestUrl.substring(0, manifestUrl.lastIndexOf('/') + 1);
      final url = '$baseUrl${info.fileName}';
      final localDir = await _getLocalFirmwareDir();
      final localFile = File(p.join(localDir.path, info.fileName));

      // Skip if the same version is already on disk.
      if (await localFile.exists()) {
        final fileSize = await localFile.length();
        if (info.size <= 0 || fileSize == info.size) {
          _downloadProgress = 1;
          _setStatus(FretFirmwareStatus.downloadComplete);
          return localFile.path;
        }
      }

      final request = http.Request('GET', Uri.parse(url));
      final response = await request.send();
      if (response.statusCode != 200) {
        _setStatus(FretFirmwareStatus.downloadFailed);
        return null;
      }

      final totalBytes = response.contentLength ?? 0;
      int receivedBytes = 0;
      final sink = localFile.openWrite();
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          receivedBytes += chunk.length;
          if (totalBytes > 0) {
            _downloadProgress = receivedBytes / totalBytes;
            onProgress?.call(_downloadProgress);
          }
        }
      } finally {
        await sink.close();
      }
      _downloadProgress = 1;
      onProgress?.call(1);

      // Record the brand this file belongs to.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPrefLocalBrand, brandId);

      // Clean up older firmware files (keep manifest + current file).
      await _cleanOldFirmwareFiles(info.fileName);

      _setStatus(FretFirmwareStatus.downloadComplete);
      return localFile.path;
    } catch (_) {
      _setStatus(FretFirmwareStatus.downloadFailed);
      return null;
    } finally {
      _isDownloading = false;
    }
  }

  /// One-shot "check + download if needed".
  ///
  /// - [manifestUrl]: OTA server manifest URL.
  /// - [brandId]: required. The SDK refuses to download if the brand
  ///   is not present in the manifest (prevents cross-brand mismatches).
  /// - [currentVersion]: the device's current firmware version (e.g.
  ///   `3.1.2.1`). When non-empty, the SDK only downloads when the
  ///   cloud version is strictly newer.
  /// - [onProgress]: download progress callback.
  /// - [force]: bypass the 24-hour throttle.
  ///
  /// Returns:
  /// - The local file path if a download happened or a matching file
  ///   was already on disk.
  /// - `null` if the device is up to date, the check failed, or the
  ///   download failed. Brand apps should inspect [onStatusChanged]
  ///   to distinguish these cases.
  Future<String?> checkAndDownload({
    required String manifestUrl,
    required String brandId,
    String? currentVersion,
    void Function(double progress)? onProgress,
    bool force = false,
  }) async {
    // 1. Check cloud.
    final info = await checkForUpdate(
      manifestUrl: manifestUrl,
      brandId: brandId,
      force: force,
    );

    // 2. If brand changed since last download, wipe the cache.
    final prefs = await SharedPreferences.getInstance();
    final lastBrand = prefs.getString(_kPrefLocalBrand);
    if (lastBrand != null && lastBrand != brandId) {
      await deleteLocalFirmware();
    }

    if (info == null) return null;

    // 3. Compare versions.
    if (currentVersion != null && currentVersion.isNotEmpty) {
      final cmp = compareVersions(info.version, currentVersion);
      if (cmp <= 0) {
        _setStatus(FretFirmwareStatus.upToDate);
        // Return existing local file (if any) so the caller can still
        // upgrade from cache if it wants to.
        return getLocalFirmwarePath(brandId: brandId);
      }
    }

    // 4. Cloud is newer (or no device version supplied) — download.
    _setStatus(FretFirmwareStatus.updateAvailable);
    return download(
      manifestUrl: manifestUrl,
      brandId: brandId,
      onProgress: onProgress,
    );
  }

  /// Path to a previously-downloaded firmware file matching [brandId].
  ///
  /// Returns `null` if no cached file exists, or if the cached manifest
  /// does not contain an entry for [brandId] (prevents using a file
  /// downloaded for a different brand).
  Future<String?> getLocalFirmwarePath({required String brandId}) async {
    try {
      final localDir = await _getLocalFirmwareDir();
      if (!await localDir.exists()) return null;
      final manifest = await _readLocalManifest();
      if (manifest == null) return null;
      final info = _resolveBrandFirmware(manifest, brandId);
      if (info == null) return null;
      final fwFile = File(p.join(localDir.path, info.fileName));
      return await fwFile.exists() ? fwFile.path : null;
    } catch (_) {
      return null;
    }
  }

  /// Version string of the locally-cached firmware for [brandId], or
  /// `null` if no cache exists.
  Future<String?> getLocalFirmwareVersion({required String brandId}) async {
    final manifest = await _readLocalManifest();
    if (manifest == null) return null;
    final info = _resolveBrandFirmware(manifest, brandId);
    return info?.version;
  }

  /// Read the locally-cached firmware file as bytes. Convenience for
  /// passing straight to [FretOTA.upgrade].
  Future<Uint8List?> readLocalFirmwareBytes({required String brandId}) async {
    final path = await getLocalFirmwarePath(brandId: brandId);
    if (path == null) return null;
    try {
      return await File(path).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// Delete all cached firmware files and the local manifest. Call
  /// after a successful OTA upgrade to reclaim space, or when the user
  /// switches brands.
  Future<void> deleteLocalFirmware() async {
    try {
      final localDir = await _getLocalFirmwareDir();
      if (!await localDir.exists()) return;
      final entities = localDir.listSync();
      for (final entity in entities) {
        if (entity is File) await entity.delete();
      }
      _cachedManifest = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kPrefLocalBrand);
    } catch (_) {
      // Best-effort cleanup.
    }
  }

  /// Compare two `major.minor.revision.sub` version strings.
  ///
  /// Returns a positive int if [a] is newer, `0` if equal, negative if
  /// [b] is newer. Missing segments default to `0`. Non-numeric
  /// segments also default to `0`.
  static int compareVersions(String a, String b) {
    final pa = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final pb = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    for (int i = 0; i < 4; i++) {
      final cmp = (i < pa.length ? pa[i] : 0) - (i < pb.length ? pb[i] : 0);
      if (cmp != 0) return cmp;
    }
    return 0;
  }

  /// Release resources. Safe to call multiple times.
  void dispose() {
    _statusController.close();
  }

  // === Internal helpers ===

  Future<bool> _shouldCheckCloud() async {
    final prefs = await SharedPreferences.getInstance();
    final lastCheck = prefs.getInt(_kPrefLastCheck) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    return (now - lastCheck) > checkInterval.inMilliseconds;
  }

  Future<Directory> _getLocalFirmwareDir() async {
    final appDir = await getApplicationSupportDirectory();
    final dir = Directory(p.join(appDir.path, _kLocalFwDir));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> _saveManifestToLocal(String content) async {
    try {
      final localDir = await _getLocalFirmwareDir();
      final file = File(p.join(localDir.path, _kLocalManifestFile));
      await file.writeAsString(content);
    } catch (_) {
      // Cache failure is non-fatal.
    }
  }

  Future<Map<String, dynamic>?> _readLocalManifest() async {
    try {
      final localDir = await _getLocalFirmwareDir();
      final file = File(p.join(localDir.path, _kLocalManifestFile));
      if (!await file.exists()) return null;
      final content = await file.readAsString();
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Resolve the firmware entry for [brandId] from [manifest].
  ///
  /// Rules:
  /// 1. If `manifest.brands[]` exists and is non-empty, find the entry
  ///    whose `id` matches [brandId]. If [brandId] is empty or not
  ///    found, return `null` (refuse to download — prevents cross-brand
  ///    firmware mismatch).
  /// 2. If `brands[]` is absent (legacy single-file manifest), fall
  ///    back to top-level `file` / `size` / `version`.
  FretFirmwareInfo? _resolveBrandFirmware(
    Map<String, dynamic> manifest,
    String brandId,
  ) {
    final brands = manifest['brands'];
    if (brands is List && brands.isNotEmpty) {
      if (brandId.isEmpty) return null;
      for (final b in brands) {
        if (b is Map<String, dynamic> && b['id'] == brandId) {
          final fileName = b['file'] as String?;
          if (fileName == null || fileName.isEmpty) return null;
          return FretFirmwareInfo(
            brandId: brandId,
            version: (b['version'] as String?) ??
                (manifest['version'] as String?) ??
                '',
            fileName: fileName,
            size: (b['size'] as num?)?.toInt() ?? 0,
            otaNamePrefix: b['otaNamePrefix'] as String?,
            releaseNotes: b['releaseNotes'] as String? ??
                manifest['releaseNotes'] as String?,
          );
        }
      }
      return null;
    }

    // Legacy single-file manifest.
    final fileName = manifest['file'] as String?;
    if (fileName == null || fileName.isEmpty) return null;
    return FretFirmwareInfo(
      brandId: brandId,
      version: (manifest['version'] as String?) ?? '',
      fileName: fileName,
      size: (manifest['size'] as num?)?.toInt() ?? 0,
      otaNamePrefix: null,
      releaseNotes: manifest['releaseNotes'] as String?,
    );
  }

  Future<void> _cleanOldFirmwareFiles(String keepFileName) async {
    try {
      final localDir = await _getLocalFirmwareDir();
      final entities = localDir.listSync();
      for (final entity in entities) {
        if (entity is File) {
          final name = p.basename(entity.path);
          if (name == _kLocalManifestFile || name == keepFileName) continue;
          // Heuristic: assume any non-manifest file is an old firmware.
          await entity.delete();
        }
      }
    } catch (_) {
      // Best-effort.
    }
  }
}
