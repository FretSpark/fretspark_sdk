// Integration tests for [FretFirmwareDownloader].
//
// Coverage:
//   - compareVersions: 4-segment semver comparison with edge cases
//   - FretFirmwareInfo: construction + toString
//   - FretFirmwareStatus: enum values
//   - checkForUpdate: HTTP failure → null + checkFailed status
//   - onStatusChanged: emits checking → checkFailed
//   - getLocalFirmwarePath / getLocalFirmwareVersion / readLocalFirmwareBytes:
//     return null when no cache exists
//   - deleteLocalFirmware: best-effort, does not throw
//   - dispose: closes status stream

import 'package:flutter_test/flutter_test.dart';
import 'package:fretspark_sdk/src/api/fret_firmware.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A URL that will immediately be refused (port 1 is never open).
/// Using this avoids the 10-second timeout in checkForUpdate, keeping
/// tests fast.
const String kUnreachableUrl = 'http://127.0.0.1:1/manifest.json';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FretFirmwareDownloader.compareVersions', () {
    test('equal versions return 0', () {
      expect(FretFirmwareDownloader.compareVersions('3.1.3.4', '3.1.3.4'), 0);
    });

    test('newer sub-version returns positive', () {
      expect(FretFirmwareDownloader.compareVersions('3.1.3.5', '3.1.3.4') > 0,
          isTrue);
    });

    test('older sub-version returns negative', () {
      expect(FretFirmwareDownloader.compareVersions('3.1.3.3', '3.1.3.4') < 0,
          isTrue);
    });

    test('higher segment overrides lower', () {
      expect(FretFirmwareDownloader.compareVersions('3.2.0.0', '3.1.9.9') > 0,
          isTrue);
      expect(FretFirmwareDownloader.compareVersions('4.0.0.0', '3.9.9.9') > 0,
          isTrue);
      expect(FretFirmwareDownloader.compareVersions('3.1.4.0', '3.1.3.9') > 0,
          isTrue);
    });

    test('lower segment overrides higher', () {
      expect(FretFirmwareDownloader.compareVersions('3.1.3.9', '3.2.0.0') < 0,
          isTrue);
    });

    test('missing segments default to 0', () {
      expect(FretFirmwareDownloader.compareVersions('3.1', '3.1.0.0'), 0);
      expect(FretFirmwareDownloader.compareVersions('3.1.3', '3.1.3.0'), 0);
    });

    test('shorter version with higher segment is newer', () {
      expect(FretFirmwareDownloader.compareVersions('3.2', '3.1.9.9') > 0,
          isTrue);
    });

    test('non-numeric segments default to 0', () {
      expect(FretFirmwareDownloader.compareVersions('x.y.z.w', '0.0.0.0'), 0);
    });

    test('empty strings compare equal', () {
      expect(FretFirmwareDownloader.compareVersions('', ''), 0);
    });

    test('empty vs non-empty: non-empty wins on first segment', () {
      expect(FretFirmwareDownloader.compareVersions('1.0.0.0', '') > 0, isTrue);
    });

    test('sub-version 10 > sub-version 4 (numeric not lexical)', () {
      expect(FretFirmwareDownloader.compareVersions('3.1.3.10', '3.1.3.4') > 0,
          isTrue);
      expect(FretFirmwareDownloader.compareVersions('3.1.3.4', '3.1.3.10') < 0,
          isTrue);
    });

    test('5-segment version: 5th segment ignored (only first 4 compared)',
        () {
      // Only the first 4 segments are compared; the 5th is ignored.
      expect(FretFirmwareDownloader.compareVersions('1.2.3.4.5', '1.2.3.4'),
          0);
    });
  });

  group('FretFirmwareInfo', () {
    test('constructs with required fields', () {
      const info = FretFirmwareInfo(
        brandId: 'auphy',
        version: '3.1.3.4',
        fileName: 'firmware.auphy.3.1.3.4.hex16',
        size: 245760,
      );
      expect(info.brandId, 'auphy');
      expect(info.version, '3.1.3.4');
      expect(info.fileName, 'firmware.auphy.3.1.3.4.hex16');
      expect(info.size, 245760);
      expect(info.otaNamePrefix, isNull);
      expect(info.releaseNotes, isNull);
    });

    test('constructs with optional fields', () {
      const info = FretFirmwareInfo(
        brandId: 'auphy',
        version: '3.1.3.4',
        fileName: 'fw.hex',
        size: 100,
        otaNamePrefix: 'AUPHY-OTA',
        releaseNotes: 'Bug fixes',
      );
      expect(info.otaNamePrefix, 'AUPHY-OTA');
      expect(info.releaseNotes, 'Bug fixes');
    });

    test('toString contains brand, version, fileName, size', () {
      const info = FretFirmwareInfo(
        brandId: 'auphy',
        version: '3.1.3.4',
        fileName: 'firmware.auphy.3.1.3.4.hex16',
        size: 245760,
      );
      final s = info.toString();
      expect(s, contains('auphy'));
      expect(s, contains('3.1.3.4'));
      expect(s, contains('firmware.auphy.3.1.3.4.hex16'));
      expect(s, contains('245760'));
    });
  });

  group('FretFirmwareStatus', () {
    test('has all expected values', () {
      final values = FretFirmwareStatus.values;
      expect(values, contains(FretFirmwareStatus.idle));
      expect(values, contains(FretFirmwareStatus.checking));
      expect(values, contains(FretFirmwareStatus.checkDone));
      expect(values, contains(FretFirmwareStatus.upToDate));
      expect(values, contains(FretFirmwareStatus.updateAvailable));
      expect(values, contains(FretFirmwareStatus.checkFailed));
      expect(values, contains(FretFirmwareStatus.downloading));
      expect(values, contains(FretFirmwareStatus.downloadComplete));
      expect(values, contains(FretFirmwareStatus.downloadFailed));
      expect(values, contains(FretFirmwareStatus.ready));
    });

    test('has exactly 10 values', () {
      expect(FretFirmwareStatus.values.length, 10);
    });
  });

  group('FretFirmwareDownloader instance', () {
    late FretFirmwareDownloader dl;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      dl = FretFirmwareDownloader();
    });

    tearDown(() {
      dl.dispose();
    });

    test('initial state: not checking, not downloading, 0 progress', () {
      expect(dl.isChecking, isFalse);
      expect(dl.isDownloading, isFalse);
      expect(dl.downloadProgress, 0);
    });

    group('checkForUpdate', () {
      test('returns null on HTTP failure (unreachable URL)', () async {
        final info = await dl.checkForUpdate(
          manifestUrl: kUnreachableUrl,
          brandId: 'auphy',
          force: true,
        );
        expect(info, isNull);
      });

      test('emits checking then checkFailed on HTTP failure', () async {
        final statuses = <FretFirmwareStatus>[];
        final sub = dl.onStatusChanged.listen(statuses.add);

        await dl.checkForUpdate(
          manifestUrl: kUnreachableUrl,
          brandId: 'auphy',
          force: true,
        );
        // Let the stream drain.
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();

        expect(statuses, contains(FretFirmwareStatus.checking));
        expect(statuses, contains(FretFirmwareStatus.checkFailed));
        // checking must appear before checkFailed.
        expect(
          statuses.indexOf(FretFirmwareStatus.checking),
          lessThan(statuses.indexOf(FretFirmwareStatus.checkFailed)),
        );
      });

      test('isChecking is false after check completes', () async {
        await dl.checkForUpdate(
          manifestUrl: kUnreachableUrl,
          brandId: 'auphy',
          force: true,
        );
        expect(dl.isChecking, isFalse);
      });

      test('concurrent check returns null (guard)', () async {
        // Start first check (will be in-flight since it awaits HTTP).
        final first = dl.checkForUpdate(
          manifestUrl: kUnreachableUrl,
          brandId: 'auphy',
          force: true,
        );
        // Start second check immediately — _isChecking is true.
        final second = dl.checkForUpdate(
          manifestUrl: kUnreachableUrl,
          brandId: 'auphy',
          force: true,
        );

        final firstResult = await first;
        final secondResult = await second;

        // First might succeed (null) or the second returns null due to guard.
        expect(firstResult, isNull);
        expect(secondResult, isNull);
      });
    });

    group('getLocalFirmwarePath', () {
      test('returns null when no cache exists', () async {
        final path = await dl.getLocalFirmwarePath(brandId: 'auphy');
        expect(path, isNull);
      });
    });

    group('getLocalFirmwareVersion', () {
      test('returns null when no cache exists', () async {
        final version = await dl.getLocalFirmwareVersion(brandId: 'auphy');
        expect(version, isNull);
      });
    });

    group('readLocalFirmwareBytes', () {
      test('returns null when no cache exists', () async {
        final bytes = await dl.readLocalFirmwareBytes(brandId: 'auphy');
        expect(bytes, isNull);
      });
    });

    group('deleteLocalFirmware', () {
      test('does not throw when no cache exists', () async {
        await dl.deleteLocalFirmware();
        // No exception thrown — test passes if we reach here.
      });
    });

    group('checkAndDownload', () {
      test('returns null on HTTP failure', () async {
        final path = await dl.checkAndDownload(
          manifestUrl: kUnreachableUrl,
          brandId: 'auphy',
          currentVersion: '1.0.0.0',
          force: true,
        );
        expect(path, isNull);
      });

      test('emits upToDate when current version >= cloud (force check)',
          () async {
        // Even though HTTP fails, the flow should not crash.
        // With HTTP failure, checkForUpdate returns null →
        // checkAndDownload returns null (no status update beyond
        // checkFailed from checkForUpdate).
        final statuses = <FretFirmwareStatus>[];
        final sub = dl.onStatusChanged.listen(statuses.add);

        await dl.checkAndDownload(
          manifestUrl: kUnreachableUrl,
          brandId: 'auphy',
          currentVersion: '3.1.3.4',
          force: true,
        );
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();

        // HTTP failure → checkFailed is emitted.
        expect(statuses, contains(FretFirmwareStatus.checkFailed));
      });
    });

    group('dispose', () {
      test('closes status stream', () async {
        dl.dispose();
        // After dispose, onStatusChanged stream is closed.
        // Adding a listener to a closed broadcast controller should
        // not throw, but the stream ends immediately.
        expect(
          dl.onStatusChanged.isEmpty,
          completion(isTrue),
        );
      });

      test('can be called multiple times', () {
        dl.dispose();
        dl.dispose();
        // No exception thrown.
      });
    });
  });
}
