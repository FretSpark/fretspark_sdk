# FretSpark SDK 开发者接入指南

本指南帮助第三方开发者快速接入 FretSpark SDK，实现智能吉他指板设备的 BLE 连接、LED 控制、固件升级等功能。

## 目录

- [环境要求](#环境要求)
- [安装](#安装)
- [平台配置](#平台配置)
- [快速开始](#快速开始)
- [核心 API 总览](#核心-api-总览)
- [设备连接](#设备连接)
- [LED 控制](#led-控制)
- [指板学习](#指板学习)
- [课堂模式](#课堂模式)
- [节拍器](#节拍器)
- [OTA 固件升级](#ota-固件升级)
- [固件下载器](#固件下载器)
- [品牌配置](#品牌配置)
- [高级用法](#高级用法)
- [错误处理](#错误处理)
- [FAQ](#faq)

---

## 环境要求

| 项目 | 最低版本 |
|---|---|
| Flutter | 3.24.0 |
| Dart SDK | 3.5.0 |
| Android minSdkVersion | 21 |
| iOS | 12.0 |

---

## 安装

在 `pubspec.yaml` 中添加依赖：

```yaml
dependencies:
  fretspark_sdk:
    git:
      url: https://github.com/FretSpark/fretspark_sdk.git
      ref: main  # 或指定版本 tag，如 v1.4.0
```

然后执行：

```bash
flutter pub get
```

---

## 平台配置

### Android

在 `android/app/src/main/AndroidManifest.xml` 中添加 BLE 权限：

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <!-- BLE 扫描权限 -->
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN"
        android:usesPermissionFlags="neverForLocation" />
    <!-- BLE 连接权限 -->
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
    <!-- 如果需要定位才能扫描（Android 11 及以下） -->
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />

    <!-- BLE 硬件声明 -->
    <uses-feature android:name="android.hardware.bluetooth_le" android:required="true" />

    <application>
        <!-- ... -->
    </application>
</manifest>
```

### iOS

在 `ios/Runner/Info.plist` 中添加蓝牙使用描述：

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>需要蓝牙权限来连接和控制吉他指板设备</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>需要蓝牙权限来连接和控制吉他指板设备</string>
```

---

## 快速开始

5 分钟实现「扫描设备 → 连接 → 点亮和弦」的完整流程：

```dart
import 'package:flutter/material.dart';
import 'package:fretspark_sdk/fretspark_sdk.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: HomePage());
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<FretScanResult> _results = [];
  FretDevice? _device;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // 1. 初始化 SDK（传入你的 brandId）
    await FretSpark.instance.initialize(brandId: 'auphy');

    // 2. 请求蓝牙权限
    await FretSpark.instance.connection.requestPermissions();

    // 3. 监听扫描结果
    FretSpark.instance.connection.scanResults.listen((r) {
      if (!_results.any((e) => e.id == r.id)) {
        setState(() => _results.add(r));
      }
    });

    // 4. 开始扫描
    await FretSpark.instance.connection.startScan();
  }

  Future<void> _connect(FretScanResult r) async {
    await FretSpark.instance.connection.stopScan();
    _device = await FretSpark.instance.connection.connect(r.id);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_device != null) {
      return Scaffold(
        appBar: AppBar(title: Text(_device!.displayName)),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('固件版本: ${_device!.firmwareVersion}'),
              Text('LED 数量: ${_device!.ledCount}'),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () async {
                  // 点亮 C 大调和弦
                  await FretSpark.instance.led.showChord(
                    _device!,
                    root: NoteName.c,
                    chordType: 'maj',
                    color: FretColor.green,
                  );
                },
                child: const Text('显示 C 大调和弦'),
              ),
              ElevatedButton(
                onPressed: () async {
                  // 清除所有 LED
                  await FretSpark.instance.led.clearAll(_device!);
                },
                child: const Text('清除 LED'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('扫描设备')),
      body: ListView(
        children: _results
            .map((r) => ListTile(
                  leading: const Icon(Icons.bluetooth),
                  title: Text(r.name),
                  subtitle: Text('rssi: ${r.rssi}'),
                  onTap: () => _connect(r),
                ))
            .toList(),
      ),
    );
  }
}
```

---

## 核心 API 总览

SDK 通过 `FretSpark.instance` 单例提供以下子 API：

| Getter | 类型 | 用途 |
|---|---|---|
| `.connection` | FretConnection | BLE 扫描、连接、握手 |
| `.led` | FretLED | LED 颜色、效果、模式、学习灯 |
| `.ota` | FretOTA | 固件 OTA 升级 |
| `.metronome` | FretMetronome | 节拍器 |
| `.classroom` | FretClassroom | 课堂模式（教师/学生） |
| `.firmware` | FretFirmwareDownloader | 固件下载、版本检查 |
| `.brand` | FretBrand | 品牌配置管理 |
| `.transport` | FretTransport | 底层 BLE 传输（高级） |

使用前必须先初始化：

```dart
await FretSpark.instance.initialize(
  brandId: 'auphy',       // 必填：你的品牌 ID
  manifestUrl: 'https://your-server.com/manifest.json',  // 可选：固件 manifest URL
  brandConfigUrl: 'https://your-server.com/brands.json',  // 可选：云端品牌配置 URL
);
```

---

## 设备连接

### 扫描

```dart
// 监听扫描结果（自动按品牌过滤）
FretSpark.instance.connection.scanResults.listen((result) {
  print('发现设备: ${result.name} (${result.id})');
});

// 开始扫描（默认 10 秒超时）
await FretSpark.instance.connection.startScan();

// 手动停止
await FretSpark.instance.connection.stopScan();
```

### 连接

```dart
// 连接设备（自动执行握手：查询固件版本、LED 数量、索引模式、课堂 ID）
final device = await FretSpark.instance.connection.connect(deviceId);

// 连接后可直接读取设备信息
print('固件版本: ${device.firmwareVersion}');    // e.g. "3.1.3.4"
print('LED 数量: ${device.ledCount}');          // e.g. 126
print('最大品数: ${device.maxFret}');           // e.g. 20
print('课堂 ID: ${device.classroomId}');        // e.g. 0
print('电量: ${device.batteryLevel}%');         // e.g. 85
```

### 监听设备状态

```dart
// 监听断线
FretSpark.instance.connection.onCurrentDeviceStateChanged.listen((connected) {
  if (!connected) print('设备已断开');
});

// 监听电量变化
device.onBatteryChanged.listen((battery) {
  print('电量: ${battery.level}%, 电压: ${battery.voltageMv}mV');
});

// 监听固件版本变化
device.onFirmwareVersionQueried.listen((version) {
  print('固件版本: ${version.formatted}');
});
```

### 断开

```dart
await FretSpark.instance.connection.disconnect();
```

---

## LED 控制

### 开关与亮度

```dart
// 开关
await FretSpark.instance.led.setPower(device, on: true);

// 亮度（0-1000）
await FretSpark.instance.led.setBrightness(device, 500);
```

### 颜色

```dart
// 用 RGB 填充整个指板
await FretSpark.instance.led.fillColor(device, FretColor(255, 0, 0));  // 红色

// 用 HSL 设置基础色
await FretSpark.instance.led.setColor(device, FretHsl(hue: 120, saturation: 800));

// 内置预设
await FretSpark.instance.led.fillColor(device, FretColor.red);
await FretSpark.instance.led.fillColor(device, FretColor.blue);
```

### 效果模式

```dart
// 切换内置效果（1-117）
await FretSpark.instance.led.setMode(device, 5);

// 速度（0-255）
await FretSpark.instance.led.setSpeed(device, 128);

// 方向（0=正向, 1=反向）
await FretSpark.instance.led.setDirection(device, 0);
```

### 硬件布局

```dart
// 设置线性布局（WS2812 灯条）
await FretSpark.instance.led.setLinearLayout(device, linear: true);

// 覆盖 LED 数量（如 21 品 = 126 灯）
await FretSpark.instance.led.setLedCount(device, 126);
```

### 范围填充

```dart
// 从第 0 个 LED 开始填充 5 个不同颜色
await FretSpark.instance.led.fillRange(
  device,
  startIndex: 0,
  colors: [
    FretColor.red, FretColor.green, FretColor.blue,
    FretColor.yellow, FretColor.cyan,
  ],
);
// 最多 79 个 LED/包，超过则分多次调用
```

### 音乐风格与定时器

```dart
// 设置音乐风格（0-99）
await FretSpark.instance.led.setMusicStyle(device, 5);

// 定时开关机（需先同步 RTC）
await device.setRtcTime(DateTime.now());
await FretSpark.instance.led.setTimer(
  device,
  on: true,
  hour: 8,
  minute: 0,
  second: 0,
);
```

### 组控

```dart
// 按组分配颜色（一次帧渲染）
await FretSpark.instance.led.applyGroupFrame(
  device,
  groupAssignments: {0: 1, 1: 1, 2: 1, 3: 2, 4: 2, 5: 2},  // LED 索引 → 组 ID
  groupColors: {
    1: FretColor.red,    // 组 1 = 红色
    2: FretColor.blue,   // 组 2 = 蓝色
  },
);

// 清除组控
await FretSpark.instance.led.clearGroupMap(device);
```

### 左手模式

```dart
// 启用左手模式（自动镜像 string 索引 0↔5）
await FretSpark.instance.led.setLeftHandedMode(true);
// 持久化到 SharedPreferences，跨设备共享
```

---

## 指板学习

### 点亮单个音符

```dart
// 第 1 弦（高 E）第 5 品，红色
await FretSpark.instance.led.lightNote(
  device,
  FretNote(string: 0, fret: 5, color: FretColor.red),
);
```

### 批量点亮

```dart
// 同时点亮多个音符（自动去重，最后写入优先）
await FretSpark.instance.led.lightNotes(
  device,
  [
    FretNote(string: 0, fret: 0, color: FretColor.red),    // 高 E 空弦
    FretNote(string: 1, fret: 2, color: FretColor.green),  // B 弦 2 品
    FretNote(string: 2, fret: 3, color: FretColor.blue),   // G 弦 3 品
  ],
);
```

### 和弦

```dart
// 显示 C 大调和弦
await FretSpark.instance.led.showChord(
  device,
  root: NoteName.c,
  chordType: 'maj',
  color: FretColor.green,
);

// 支持的和弦类型：maj, min, 7, maj7, min7, dim, aug, sus2, sus4, ...
```

### 音阶

```dart
// 显示 C 大调音阶
await FretSpark.instance.led.showScale(
  device,
  root: NoteName.c,
  scale: ScaleType.major,
  color: FretColor.cyan,
);

// 支持的音阶：major, minor, pentatonic, blues, dorian, mixolydian, ...
```

### 清除学习灯

```dart
await FretSpark.instance.led.clearLearningLEDs(device);
```

---

## 课堂模式

课堂模式允许多台设备同步 LED 状态，适用于教学场景。

```dart
// 教师端：开始广播
await FretSpark.instance.classroom.startTeacher(device);

// 学生端：开始监听
await FretSpark.instance.classroom.startStudent(device);

// 停止
await FretSpark.instance.classroom.stop(device);
```

---

## 节拍器

```dart
// 启动节拍器（BPM 40-240，拍号可选）
await FretSpark.instance.metronome.start(
  device,
  bpm: 120,
  timeSignature: FretTimeSignature.fourFour,  // 默认 4/4
);

// 切换拍号
await FretSpark.instance.metronome.start(
  device,
  bpm: 100,
  timeSignature: FretTimeSignature.sixEight,  // 6/8 拍
);

// 停止
await FretSpark.instance.metronome.stop(device);
```

支持的拍号：

| 枚举 | 拍数 | 含义 |
|---|---|---|
| `FretTimeSignature.twoFour` | 2 | 2/4 拍 |
| `FretTimeSignature.threeFour` | 3 | 3/4 拍 |
| `FretTimeSignature.fourFour` | 4 | 4/4 拍（默认） |
| `FretTimeSignature.sixEight` | 6 | 6/8 拍 |

---

## OTA 固件升级

OTA 升级分三步：进入 OTA 模式 → 扫描 OTA 设备 → 传输固件。

```dart
final ota = FretSpark.instance.ota;

// 1. 通知已连接的设备进入 OTA 模式（设备会重启并改变蓝牙名）
await ota.enterOtaMode(device);

// 2. 扫描 OTA 模式设备（按 OTA 名称前缀匹配）
final otaDevice = await ota.scanOtaDevice('AUPHY-OTA');
if (otaDevice == null) {
  print('未找到 OTA 设备');
  return;
}

// 3. 监听升级进度
final sub = ota.onProgress.listen((p) {
  print('${p.phase.name}: ${p.sent}/${p.total} bytes');
});

// 4. 传输固件
try {
  await ota.upgrade(otaDevice.id, firmwareBytes);
  print('升级成功');
} on FretOtaException catch (e) {
  print('升级失败: $e');
} finally {
  await sub.cancel();
}
```

进度阶段：

| 阶段 | 含义 |
|---|---|
| `connecting` | 正在连接 OTA 设备 |
| `starting` | 发送 START_OTA 命令 |
| `transferring` | 传输固件数据 |
| `rebooting` | 设备重启中 |
| `success` | 升级成功 |

### 自定义 BLE 栈

如果不用 `flutter_blue_plus`，可以实现自己的 `FretOtaTransport`：

```dart
class MyOtaTransport implements FretOtaTransport {
  // 实现 connect / discoverOtaService / writeCmd / writeData
  // / rspNotifyStream / disconnect
}

final ota = FretOTA(transport: MyOtaTransport());
```

---

## 固件下载器

```dart
final fw = FretSpark.instance.firmware;

// 检查更新
final info = await fw.checkForUpdate(
  manifestUrl: 'https://your-server.com/manifest.json',
  brandId: 'auphy',
);
if (info != null) {
  print('新版本: ${info.version} (${info.size} bytes)');
}

// 下载固件
final localPath = await fw.checkAndDownload(
  manifestUrl: 'https://your-server.com/manifest.json',
  brandId: 'auphy',
  currentVersion: '3.1.3.4',
);
if (localPath != null) {
  // 用 localPath 读取固件文件，然后调用 ota.upgrade()
  final bytes = await File(localPath).readAsBytes();
  await FretSpark.instance.ota.upgrade(deviceId, bytes);
}

// 查询本地缓存的固件
final cachedPath = await fw.getLocalFirmwarePath(brandId: 'auphy');
final cachedVersion = await fw.getLocalFirmwareVersion(brandId: 'auphy');

// 删除本地缓存
await fw.deleteLocalFirmware();
```

### 版本比较

```dart
// 静态方法，可直接使用
final cmp = FretFirmwareDownloader.compareVersions('3.1.3.4', '3.1.3.5');
// cmp < 0: 当前版本旧
// cmp == 0: 相同
// cmp > 0: 当前版本新
```

---

## 品牌配置

SDK 内置 6 个品牌的 fallback 配置。如果需要从云端同步品牌列表：

```dart
final brand = FretSpark.instance.brand;

// 从云端同步品牌配置（JSON 格式）
await brand.syncFromCloud(jsonString);

// 或从 URL 同步
await FretSpark.instance.initialize(
  brandId: 'auphy',
  brandConfigUrl: 'https://your-server.com/brands.json',
);

// 按设备名匹配品牌
final matched = brand.matchByFirmwareName('AUPHY-1234');
if (matched != null) {
  print('匹配到品牌: ${matched.displayName}');
}

// 设置活跃品牌
await brand.setActive('auphy');

// 从缓存恢复
await brand.loadActiveFromCache();
```

---

## 高级用法

### 发送原始命令

当 SDK 高阶 API 没有包装某个固件命令时，可用 `FretAdvanced` 逃生通道：

```dart
// 等待队列完成（推荐）
await FretAdvanced.sendRaw(
  device,
  FretCommand.musicStyle,
  <int>[42],
);

// Fire-and-forget（高频动画帧场景）
FretAdvanced.sendRawFireAndForget(
  device,
  FretCommand.energyInject,
  <int>[0x01, 0x00],
);
```

> **警告**：`sendRaw` 绕过 SDK 状态机优化。使用前请确认 SDK 高阶 API 确实没有等价方法。详见 [FretCommand] 命令码注释。

### 监听未知通知

```dart
// 捕获 SDK 未识别的固件通知
device.setUnknownNotifyHandler((notify) {
  print('未知通知: cmd=0x${notify.cmd.toRadixString(16)} data=${notify.data}');
});
```

### 查询设备状态

```dart
// 重新查询固件版本
await device.queryVersion();

// 重新查询 LED 配置
await device.queryLedConfig();

// 触发固件推送状态（电量等）
await device.queryStatus();
// 然后监听 onBatteryChanged 获取结果

// 设置课堂 ID
await device.setClassroomId(1234);

// 同步 RTC 时间
await device.setRtcTime(DateTime.now());
```

---

## 错误处理

### 常见异常类型

| 异常 | 含义 | 处理建议 |
|---|---|---|
| `FretTransportException` | BLE 连接/扫描失败 | 检查蓝牙开关、权限、设备距离 |
| `FretOtaException` | OTA 升级失败 | 检查固件文件、设备电量、重试 |
| `ArgumentError` | 参数校验失败 | 检查参数范围 |
| `StateError` | 设备已断开或未初始化 | 重新连接/初始化 |

### 错误处理示例

```dart
try {
  final device = await FretSpark.instance.connection.connect(deviceId);
  await FretSpark.instance.led.setBrightness(device, 500);
} on FretTransportException catch (e) {
  // BLE 层错误
  print('连接失败: $e');
} on StateError catch (e) {
  // 设备已断开
  print('设备状态错误: $e');
} catch (e) {
  // 其他错误
  print('未知错误: $e');
}
```

### 连接状态监听

```dart
FretSpark.instance.connection.onCurrentDeviceStateChanged.listen((connected) {
  if (!connected) {
    // 设备意外断开，可以在这里触发重连逻辑
    print('设备断开，尝试重连...');
  }
});
```

---

## FAQ

### Q: 支持哪些品牌？

A: SDK 内置 6 个品牌：FretSpark、AUPHY、Smiger、NATASHA、Bullfighter、Deviser。可通过云端配置添加自定义品牌。

### Q: 扫描不到设备？

A: 依次检查：
1. 手机蓝牙是否已开启
2. APP 是否已获取蓝牙权限
3. 设备是否已开机并在广播范围内
4. Android 12+ 需要运行时动态申请 `BLUETOOTH_SCAN` 和 `BLUETOOTH_CONNECT` 权限

### Q: 连接后设备信息为空？

A: 连接握手有 3 秒超时。如果固件版本/LED 数量显示为空/默认值，可能是固件响应超时。可手动调用 `device.queryVersion()` 重新查询。

### Q: LED 命令发出后没反应？

A: 检查设备是否已连接（`device.isConnected`），以及是否处于组控模式（如果是，先调用 `led.clearGroupMap(device)` 退出组控）。

### Q: OTA 升级失败怎么办？

A: 检查：
1. 固件文件是否为空（`fileBytes.isEmpty`）
2. 设备电量是否充足（建议 >20%）
3. OTA 设备名前缀是否正确（如 `AUPHY-OTA`）
4. 确认固件文件品牌与设备品牌一致

### Q: 如何在多品牌 APP 中切换品牌？

```dart
await FretSpark.instance.brand.setActive('smiger');
// SDK 会自动用新品牌过滤扫描结果
```

### Q: 支持同时连接多个设备吗？

A: `FretSpark.instance` 是单例，同时只管理一个设备。如需多设备，需自行管理多个 `FretConnection` 实例（需要自行初始化 transport）。

### Q: 如何添加自定义品牌？

A: 两种方式：
1. 通过云端配置（推荐）：提供品牌 JSON URL，调用 `syncFromCloud`
2. 在 `assets/brands_fallback.json` 中添加品牌（需 fork SDK 仓库）

品牌 JSON 格式：
```json
{
  "version": 1,
  "list": [
    {
      "id": "mybrand",
      "display_name": "My Brand",
      "device_model": "MB-1",
      "firmware_patterns": [".*MYBRAND.*"],
      "ota_name_prefix": "MYBRAND-OTA",
      "email": "support@mybrand.com",
      "enabled": true
    }
  ]
}
```

### Q: 如何查看完整命令码列表？

A: 参阅 [README.md](README.md) 中的固件命令覆盖表，或查看 SDK 源码 `lib/src/core/commands.dart`。

---

## 更多资源

- [README.md](README.md) — SDK 完整 API 参考与命令覆盖表
- [CHANGELOG.md](CHANGELOG.md) — 版本变更记录
- [example/](example/) — 完整示例 Flutter 应用
- [GitHub Issues](https://github.com/FretSpark/fretspark_sdk/issues) — 问题反馈与建议
