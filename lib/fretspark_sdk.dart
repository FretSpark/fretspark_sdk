/// FretSpark SDK — public API surface.
///
/// Brand apps import this single file:
///
/// ```dart
/// import 'package:fretspark_sdk/fretspark_sdk.dart';
///
/// await FretSpark.instance.initialize(brandId: 'auphy');
/// ```
///
/// Internal modules under `src/core/` (protocol codec, send queue, batch
/// transfer, notify dispatcher) are NOT re-exported. Brand apps interact
/// with the device exclusively via the [FretSpark] singleton,
/// [FretDevice], and the api/ classes.
///
/// The default BLE transport implementation is also internal — it is
/// created automatically by [FretSpark.initialize]. Brand apps that need
/// a custom BLE stack implement [FretTransport] and pass it to
/// [FretSpark.initialize].
library;

// === Singleton entry point ===
export 'src/fretspark.dart';

// === Public API classes ===
export 'src/api/fret_advanced.dart';
export 'src/api/fret_brand.dart';
export 'src/api/fret_classroom.dart';
export 'src/api/fret_connection.dart';
export 'src/api/fret_firmware.dart';
export 'src/api/fret_led.dart';
export 'src/api/fret_metronome.dart';
export 'src/api/fret_ota.dart';

// === Public models ===
export 'src/models/brand_config.dart';
export 'src/models/fret_color.dart';
export 'src/models/fret_device.dart';
export 'src/models/fret_note.dart';
export 'src/models/fret_notify.dart';

// === Public transport interface (for custom transport injection) ===
// Only the abstract [FretTransport] type and its value classes
// ([FretScanResult], [FretConnectionState], [FretBleDevice],
// [FretTransportException]) are exported. The default BLE transport
// implementation is internal — the SDK instantiates it automatically when
// no custom transport is passed to [FretSpark.initialize].
export 'src/transport/fret_transport.dart';
