// Integration tests for [FretBrand].
//
// Coverage:
//   - syncFromCloud: parses JSON payload into allBrands
//   - allBrands: returns unmodifiable map
//   - activeBrand: null until setActive
//   - setActive: sets active brand, rejects unknown / disabled
//   - matchByFirmwareName: matches by regex patterns, skips disabled
//   - autoDetectFromDeviceName: switches active brand, persists to prefs
//   - loadActiveFromCache: restores active brand from SharedPreferences

import 'package:flutter_test/flutter_test.dart';
import 'package:fretspark_sdk/src/api/fret_brand.dart';
import 'package:fretspark_sdk/src/models/brand_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Test brand config with 3 brands (2 enabled, 1 disabled).
const String kTestBrandJson = '''
{
  "version": 2,
  "list": [
    {
      "id": "fretspark",
      "display_name": "FretSpark",
      "device_model": "FS-86 PRO",
      "firmware_patterns": [".*FretSpark.*"],
      "ota_name_prefix": "FretSpark-OTA",
      "enabled": true
    },
    {
      "id": "auphy",
      "display_name": "AUPHY",
      "device_model": "SCT-86 PRO",
      "firmware_patterns": [".*AUPHY.*", ".*SCT.*"],
      "ota_name_prefix": "AUPHY-OTA",
      "enabled": true
    },
    {
      "id": "ghost",
      "display_name": "Ghost",
      "device_model": "GHOST-1",
      "firmware_patterns": [".*Ghost.*"],
      "enabled": false
    }
  ]
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FretBrand', () {
    late FretBrand brand;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      brand = FretBrand();
    });

    group('syncFromCloud', () {
      test('loads 3 brands from JSON payload', () async {
        await brand.syncFromCloud(kTestBrandJson);

        expect(brand.allBrands.length, 3);
        expect(brand.allBrands.keys, containsAll(<String>['fretspark', 'auphy', 'ghost']));
      });

      test('parses brand fields correctly', () async {
        await brand.syncFromCloud(kTestBrandJson);

        final auphy = brand.allBrands['auphy']!;
        expect(auphy.displayName, 'AUPHY');
        expect(auphy.deviceModel, 'SCT-86 PRO');
        expect(auphy.otaNamePrefix, 'AUPHY-OTA');
        expect(auphy.enabled, isTrue);
        expect(auphy.firmwarePatterns, <String>['.*AUPHY.*', '.*SCT.*']);
      });

      test('disabled brand has enabled=false', () async {
        await brand.syncFromCloud(kTestBrandJson);

        expect(brand.allBrands['ghost']!.enabled, isFalse);
      });

      test('replaces previous brands on second call', () async {
        await brand.syncFromCloud(kTestBrandJson);
        expect(brand.allBrands.length, 3);

        await brand.syncFromCloud('''
          {"version": 3, "list": [
            {"id": "newbrand", "display_name": "New", "device_model": "X", "firmware_patterns": [".*New.*"], "enabled": true}
          ]}
        ''');
        expect(brand.allBrands.length, 1);
        expect(brand.allBrands.keys.single, 'newbrand');
      });

      test('empty list does not clear existing brands', () async {
        await brand.syncFromCloud(kTestBrandJson);
        await brand.syncFromCloud('{"version": 4, "list": []}');
        // Empty list is ignored — existing brands remain.
        expect(brand.allBrands.length, 3);
      });
    });

    group('allBrands', () {
      test('is empty before any load', () {
        expect(brand.allBrands, isEmpty);
      });

      test('returns unmodifiable map', () async {
        await brand.syncFromCloud(kTestBrandJson);
        expect(
          () => brand.allBrands['x'] = BrandConfig(
            id: 'x',
            displayName: 'X',
            deviceModel: 'X',
            firmwarePatterns: <String>['.*X.*'],
          ),
          throwsUnsupportedError,
        );
      });
    });

    group('activeBrand', () {
      test('is null before setActive', () {
        expect(brand.activeBrand, isNull);
      });

      test('is set after setActive', () async {
        await brand.syncFromCloud(kTestBrandJson);
        await brand.setActive('auphy');

        expect(brand.activeBrand, isNotNull);
        expect(brand.activeBrand!.id, 'auphy');
      });
    });

    group('setActive', () {
      setUp(() async {
        await brand.syncFromCloud(kTestBrandJson);
      });

      test('succeeds for enabled brand', () async {
        await brand.setActive('fretspark');
        expect(brand.activeBrand!.id, 'fretspark');
      });

      test('throws ArgumentError for unknown brand', () {
        expect(
          () => brand.setActive('unknown'),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('throws StateError for disabled brand', () {
        expect(
          () => brand.setActive('ghost'),
          throwsA(isA<StateError>()),
        );
      });

      test('persists choice to SharedPreferences', () async {
        await brand.setActive('auphy');

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('fretspark.brand.active_id'), 'auphy');
      });
    });

    group('matchByFirmwareName', () {
      setUp(() async {
        await brand.syncFromCloud(kTestBrandJson);
      });

      test('matches AUPHY name to auphy brand', () {
        final matched = brand.matchByFirmwareName('AUPHY-1234');
        expect(matched, isNotNull);
        expect(matched!.id, 'auphy');
      });

      test('matches SCT name to auphy brand (second pattern)', () {
        final matched = brand.matchByFirmwareName('SCT-86PRO');
        expect(matched, isNotNull);
        expect(matched!.id, 'auphy');
      });

      test('matches FretSpark name to fretspark brand', () {
        final matched = brand.matchByFirmwareName('FretSpark v2');
        expect(matched, isNotNull);
        expect(matched!.id, 'fretspark');
      });

      test('returns null for non-matching name', () {
        expect(brand.matchByFirmwareName('UnknownDevice'), isNull);
      });

      test('returns null for empty string', () {
        expect(brand.matchByFirmwareName(''), isNull);
      });

      test('skips disabled brands even if pattern matches', () {
        // Ghost brand has pattern .*Ghost.* but is disabled.
        expect(brand.matchByFirmwareName('Ghost-1234'), isNull);
      });

      test('matching is case-insensitive', () {
        final matched = brand.matchByFirmwareName('auphy-1234');
        expect(matched, isNotNull);
        expect(matched!.id, 'auphy');
      });
    });

    group('autoDetectFromDeviceName', () {
      setUp(() async {
        await brand.syncFromCloud(kTestBrandJson);
      });

      test('returns matched brand and switches active', () async {
        final matched = await brand.autoDetectFromDeviceName('AUPHY-1234');
        expect(matched, isNotNull);
        expect(matched!.id, 'auphy');
        expect(brand.activeBrand!.id, 'auphy');
      });

      test('returns null for non-matching name', () async {
        final matched = await brand.autoDetectFromDeviceName('Unknown');
        expect(matched, isNull);
      });

      test('does not persist when no match', () async {
        await brand.autoDetectFromDeviceName('Unknown');
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('fretspark.brand.active_id'), isNull);
      });

      test('persists switch to SharedPreferences', () async {
        await brand.autoDetectFromDeviceName('AUPHY-1234');
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('fretspark.brand.active_id'), 'auphy');
      });

      test('no-op when matched brand is already active', () async {
        await brand.setActive('auphy');
        final matched = await brand.autoDetectFromDeviceName('AUPHY-1234');
        expect(matched!.id, 'auphy');
        expect(brand.activeBrand!.id, 'auphy');
      });
    });

    group('loadActiveFromCache', () {
      setUp(() async {
        await brand.syncFromCloud(kTestBrandJson);
      });

      test('restores active brand from prefs', () async {
        // Simulate a previous session persisting the choice.
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('fretspark.brand.active_id', 'fretspark');

        await brand.loadActiveFromCache();

        expect(brand.activeBrand, isNotNull);
        expect(brand.activeBrand!.id, 'fretspark');
      });

      test('does nothing when prefs has no active id', () async {
        await brand.loadActiveFromCache();
        expect(brand.activeBrand, isNull);
      });

      test('does nothing when cached id is not in brands list', () async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('fretspark.brand.active_id', 'nonexistent');

        await brand.loadActiveFromCache();
        expect(brand.activeBrand, isNull);
      });
    });
  });

  group('BrandConfig', () {
    test('matches returns true for matching pattern', () {
      const config = BrandConfig(
        id: 'test',
        displayName: 'Test',
        deviceModel: 'TM-1',
        firmwarePatterns: <String>['.*Test.*'],
      );
      expect(config.matches('TestDevice123'), isTrue);
    });

    test('matches returns false for non-matching pattern', () {
      const config = BrandConfig(
        id: 'test',
        displayName: 'Test',
        deviceModel: 'TM-1',
        firmwarePatterns: <String>['.*Test.*'],
      );
      expect(config.matches('OtherDevice'), isFalse);
    });

    test('matches returns false for empty string', () {
      const config = BrandConfig(
        id: 'test',
        displayName: 'Test',
        deviceModel: 'TM-1',
        firmwarePatterns: <String>['.*Test.*'],
      );
      expect(config.matches(''), isFalse);
    });

    test('matches is case-insensitive', () {
      const config = BrandConfig(
        id: 'test',
        displayName: 'Test',
        deviceModel: 'TM-1',
        firmwarePatterns: <String>['.*TEST.*'],
      );
      expect(config.matches('test-1234'), isTrue);
    });

    test('fromJson parses all fields', () {
      final config = BrandConfig.fromJson(<String, dynamic>{
        'id': 'brand1',
        'display_name': 'Brand One',
        'device_model': 'B1',
        'email': 'help@brand1.com',
        'firmware_patterns': <String>['.*Brand1.*'],
        'ota_name_prefix': 'Brand1-OTA',
        'enabled': true,
      });
      expect(config.id, 'brand1');
      expect(config.displayName, 'Brand One');
      expect(config.deviceModel, 'B1');
      expect(config.email, 'help@brand1.com');
      expect(config.otaNamePrefix, 'Brand1-OTA');
      expect(config.enabled, isTrue);
    });

    test('fromJson accepts product_model as fallback for device_model', () {
      final config = BrandConfig.fromJson(<String, dynamic>{
        'id': 'brand1',
        'display_name': 'Brand One',
        'product_model': 'PM-1',
        'firmware_patterns': <String>['.*Brand1.*'],
      });
      expect(config.deviceModel, 'PM-1');
    });

    test('fromJson defaults email and enabled', () {
      final config = BrandConfig.fromJson(<String, dynamic>{
        'id': 'brand1',
        'display_name': 'Brand One',
        'device_model': 'B1',
        'firmware_patterns': <String>['.*Brand1.*'],
      });
      expect(config.email, 'support@fretspark.com');
      expect(config.enabled, isTrue);
    });

    test('toJson round-trips all fields', () {
      const config = BrandConfig(
        id: 'brand1',
        displayName: 'Brand One',
        deviceModel: 'B1',
        email: 'help@brand1.com',
        firmwarePatterns: <String>['.*Brand1.*'],
        otaNamePrefix: 'Brand1-OTA',
        enabled: true,
      );
      final json = config.toJson();
      expect(json['id'], 'brand1');
      expect(json['display_name'], 'Brand One');
      expect(json['device_model'], 'B1');
      expect(json['email'], 'help@brand1.com');
      expect(json['ota_name_prefix'], 'Brand1-OTA');
      expect(json['enabled'], true);
    });
  });
}
