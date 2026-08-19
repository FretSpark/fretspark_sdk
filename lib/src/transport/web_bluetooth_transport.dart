// Conditional export entry for [WebBluetoothTransport].
//
// On Web platforms (where `dart:js_interop` is available), this exports
// the real [WebBluetoothTransport] implementation backed by the Web
// Bluetooth API.
//
// On non-Web platforms (Android, iOS, desktop), this exports a stub
// that throws [UnsupportedError] when constructed, allowing the SDK to
// compile on all platforms without requiring `package:web` on mobile.
//
// Developers typically do not import this file directly. The class is
// re-exported via `package:fretspark_sdk/fretspark_sdk.dart`.
export 'web_bluetooth_stub.dart'
    if (dart.library.js_interop) 'web_bluetooth_web.dart';
