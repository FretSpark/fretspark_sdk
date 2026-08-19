import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fretspark_sdk/fretspark_sdk.dart';

/// Minimal FretSpark SDK example.
///
/// Flow:
///   1. Initialize the SDK with the AUPHY brand.
///   2. Request Bluetooth permissions.
///   3. Scan for AUPHY-branded devices (filtered automatically).
///   4. Tap a scan result to connect.
///   5. Once connected, three demo buttons:
///      - Light a C-major chord
///      - Light a C-major scale
///      - Clear all LEDs
void main() {
  runApp(const FretSparkExampleApp());
}

class FretSparkExampleApp extends StatelessWidget {
  const FretSparkExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'FretSpark SDK Example',
      home: _HomePage(),
    );
  }
}

class _HomePage extends StatefulWidget {
  const _HomePage();

  @override
  State<_HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<_HomePage> {
  final List<FretScanResult> _results = <FretScanResult>[];
  FretDevice? _device;
  bool _busy = false;
  String? _error;
  StreamSubscription<FretScanResult>? _scanSub;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await FretSpark.instance.initialize(brandId: 'auphy');
      final ok = await FretSpark.instance.connection.requestPermissions();
      if (!ok) {
        setState(() => _error = 'Bluetooth permissions denied');
        return;
      }
      _scanSub = FretSpark.instance.connection.scanResults.listen((r) {
        if (!_results.any((e) => e.id == r.id)) {
          setState(() => _results.add(r));
        }
      });
      await FretSpark.instance.connection.startScan();
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect(FretScanResult r) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await FretSpark.instance.connection.stopScan();
      _device = await FretSpark.instance.connection.connect(r.id);
    } catch (e) {
      setState(() => _error = 'connect failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chord() async {
    final d = _device;
    if (d == null) return;
    await FretSpark.instance.led.showChord(
      d,
      root: NoteName.c,
      chordType: 'maj',
      color: FretColor.green,
    );
  }

  Future<void> _scale() async {
    final d = _device;
    if (d == null) return;
    await FretSpark.instance.led.showScale(
      d,
      root: NoteName.c,
      scale: ScaleType.major,
      color: FretColor.cyan,
    );
  }

  Future<void> _clear() async {
    final d = _device;
    if (d == null) return;
    await FretSpark.instance.led.clearAll(d);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('FretSpark SDK Example')),
      body: _busy && _device == null && _results.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _device == null
              ? _buildScanList()
              : _buildDeviceControls(),
      floatingActionButton: _device != null
          ? FloatingActionButton(
              onPressed: () async {
                await FretSpark.instance.connection.disconnect();
                setState(() => _device = null);
              },
              child: const Icon(Icons.bluetooth_disabled),
            )
          : null,
    );
  }

  Widget _buildScanList() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, style: const TextStyle(color: Colors.red)),
        ),
      );
    }
    return ListView(
      children: [
        for (final r in _results)
          ListTile(
            leading: const Icon(Icons.bluetooth),
            title: Text(r.name),
            subtitle: Text('${r.id}  (rssi=${r.rssi})'),
            onTap: () => _connect(r),
          ),
      ],
    );
  }

  Widget _buildDeviceControls() {
    final d = _device!;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(d.displayName,
                    style: Theme.of(context).textTheme.titleLarge),
                Text('Firmware: ${d.firmwareVersion.isEmpty ? "(no response)" : d.firmwareVersion}'),
                Text('LED count: ${d.ledCount}  (max fret ${d.maxFret})'),
                Text('Battery: ${d.batteryLevel}%  (${d.batteryVoltageMv} mV)'),
                Text('Classroom ID: ${d.classroomId}'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: _busy ? null : _chord,
          icon: const Icon(Icons.music_note),
          label: const Text('Show C major chord'),
        ),
        const SizedBox(height: 8),
        ElevatedButton.icon(
          onPressed: _busy ? null : _scale,
          icon: const Icon(Icons.library_music),
          label: const Text('Show C major scale'),
        ),
        const SizedBox(height: 8),
        ElevatedButton.icon(
          onPressed: _busy ? null : _clear,
          icon: const Icon(Icons.highlight_off),
          label: const Text('Clear all LEDs'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(_error!, style: const TextStyle(color: Colors.red)),
        ],
      ],
    );
  }
}
