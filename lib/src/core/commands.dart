/// Firmware command codes (0x01 ~ 0x2A).
///
/// These constants are internal to the SDK. Public API classes wrap each
/// command with guitar-semantic methods; brand apps should never need to
/// reference these codes directly.
///
/// Packet format (APP -> firmware):
///   [0xBC, cmd, paramsLen, ...params, 0x55]
///
/// Notify format (firmware -> APP):
///   [0xCC, cmd, len, ...data, 0xAA]
library;

/// Frame delimiters.
const int kFrameStartAppTo_FW = 0xBC;
const int kFrameEndAppToFW = 0x55;
const int kFrameStartFWToApp = 0xCC;
const int kFrameEndFWToApp = 0xAA;

class FretCommand {
  FretCommand._();

  // === Power / brightness / color ===
  static const int power = 0x01; // [0x01=on / 0x00=off]

  /// 内部使用:让设备重启进入 OTA 模式(通过 runtime command service 发送)。
  /// 复用 [power] 的 0x01 字节但参数不同,故单独命名。
  static const int enterOta = 0x01;

  /// RGB 排列方式 (0=矩阵排列 / 1=线性排列)。
  /// 用于适配 WS2812/SK6812 等不同灯珠排列的硬件。
  static const int linearLayout = 0x02; // [0/1]

  /// 设置 LED 灯珠数量 (uint16 big-endian)。
  /// 用于 APP 端动态调整固件处理的灯珠数,适配不同长度的灯带。
  static const int ledCount = 0x03; // [countH, countL]

  static const int color = 0x04; // [hueH, hueL, satH, satL, 0, 0]
  static const int brightness = 0x05; // [briH, briL, 0, 0, 0, 0] (0-1000)
  static const int mode = 0x06; // [modeH, modeL]
  static const int direction = 0x07; // [dir]
  static const int speed = 0x08; // [speed]
  static const int musicMode = 0x09; // AI rhythm, compound params

  // === Notify: battery ===
  static const int batteryNotify = 0x0A; // [level, mvH, mvL]

  /// 同步 RTC 时间 (固件用于 0x0D 定时开关机的基准时钟)。
  /// payload = [yearH, yearL, month, day, hour, minute, second] (7 字节)
  static const int rtcTime = 0x0B; // [yyH, yyL, MM, dd, HH, mm, ss]

  /// 触发固件主动上报状态 (电量/配置等)。
  /// 固件内部 send_type_request(8) 与 send_type_request(9)。
  /// payload = [0x01] (目前仅支持 0x01)
  static const int queryStatus = 0x0C; // [0x01]

  /// 设置定时开关机 (依赖 0x0B 同步的 RTC 时间)。
  /// payload = [slot, onOff, hour, minute, second, reserved]
  ///   slot: 定时槽编号 (固件保留,通常为 0)
  ///   onOff: 0=定时关, 非0=定时开
  ///   hour/minute/second: 触发时刻
  ///   reserved: 预留字节 (固件写入 device_time_*[4], 目前固定为 0)
  static const int timer = 0x0D; // [slot, onOff, HH, mm, ss, 0x00]

  // === Voice / mic ===
  static const int micSource =
      0x0F; // [0=appMic/1=localMic/6=vibration/0xFF=off]
  /// **已废弃**: 此命令在固件中同时承担"静态色"和"APP 麦克风能量注入"
  /// 两个相互冲突的职责(会把 device_rgb_state 钉到 4 关闭 AI 律动渲染)。
  /// SDK 已用 [fillColor] (0x15) + [energyInject] (0x26) 两条命令替代,
  /// 品牌方应避免使用本命令。详见 CHANGELOG。
  static const int staticColor = 0x10; // legacy, replaced by fillColor + energyInject
  static const int voiceMode = 0x11; // [0x00=on / 0xFF=off]
  static const int voiceSensitivity = 0x12; // [value]

  /// 物理旋钮 HSL 上报 (固件主动通知,APP 也可模拟旋钮输入)。
  /// payload = [knobValueH, knobValueL] (uint16, 0-360)
  /// **注**: 物理旋钮场景,APP 端少用,保留供高级开发者使用。
  static const int knobHsl = 0x13; // [valH, valL]

  /// 自定义连续段 LED 颜色 (从 start_index 开始连续写入 N 个 LED)。
  /// payload = [startIndex, r1, g1, b1, r2, g2, b2, ...]
  ///   len (BLE 帧中的 LEN 字段) = 1 + 3N (N = LED 个数)
  /// 与 [batchData] (0x16) 的区别:
  ///   - 0x14 是连续段(每颗 LED 索引递增),单帧即刷新,性能高
  ///   - 0x16 是稀疏段(每颗 LED 索引独立指定),需 0x1C/0x1D 批量包装
  /// 单包 N ≤ [maxLedsPerFillRangePacket] (BLE 帧长约束)。
  static const int fillRange = 0x14; // [start, r,g,b, r,g,b, ...]

  // === Drawing / fill ===
  static const int fillColor = 0x15; // [0, r, 0, g, 0, b]
  static const int batchData = 0x16; // [seq, count, idx, r, g, b, ...]
  static const int groupEnd = 0x17; // []
  static const int selectionMask = 0x18; // [50-byte bitmap] or [] to clear
  static const int groupMap = 0x19; // [baseIdx, ...groupIds] or [] to clear
  static const int groupColor = 0x1A; // [gid, r, g, b]

  /// 设置音乐风格 (独立于 [mode] 0x06 与 [musicMode] 0x09 的另一套风格系统)。
  /// 固件内调用 apply_music_style(styleId),触发独立的渲染管线。
  /// payload = [styleId] (单字节,0-255)
  /// **注**: 固件中 styleId >= 100 会被重置为 0 (用于切换拾音源时的保护逻辑)。
  static const int musicStyle = 0x1B; // [styleId]

  static const int batchBegin = 0x1C; // [packetCount] (0 = state-only)
  static const int batchEnd = 0x1D; // []

  // === Query (notify response) ===
  static const int queryVersion = 0x1E; // -> [major, minor, rev, sub]
  static const int queryLedConfig = 0x1F; // -> [ledCountH, ledCountL]

  // === Metronome ===
  static const int metronomeStart = 0x20; // [bpmH, bpmL, timeSig]
  static const int metronomeStop = 0x21; // []

  // === Learning LED ===
  static const int learningLed = 0x22; // [0=clear / 1=single / 2=multi, ...]

  // === Classroom (Nordic PPP) ===
  static const int teacherTxStart = 0x23; // []
  static const int studentRxStart = 0x24; // []
  static const int classroomStop = 0x25; // []

  // === Energy injection (app mic) ===
  static const int energyInject = 0x26; // [eH, eL]

  // === LED index mode ===
  static const int setLedIndexMode = 0x27; // [0=normal / 1=reversed]
  static const int queryLedIndexMode = 0x28; // -> [0/1]

  // === DIY mode list ===
  static const int setDiyModeList = 0x29; // [count, ...modeIds]
  static const int queryDiyModeList = 0x2A; // -> list

  /// Commands that should be coalesced in the send queue (only the latest
  /// param wins). High-frequency commands that would otherwise flood the
  /// firmware BLE_RX_QUEUE_DEPTH=4.
  static const Set<int> coalesceCommands = {
    color,
    brightness,
    speed,
    voiceSensitivity,
    learningLed,
  };

  /// Max LEDs per single packet (protocol constraint).
  /// Frame = [0xBC, 0x22, len, 0x02, count, idx, r, g, b × N, 0x55] = 7 + 4N.
  /// MTU=247 -> writeWithoutResponse max 244 -> N <= 59.
  static const int maxLedsPerPacket = 59;

  /// Max LEDs per [fillRange] (0x14) single packet.
  /// Frame = [0xBC, 0x14, len, start, r,g,b × N, 0x55] = 6 + 3N.
  /// MTU=247 -> writeWithoutResponse max 244 -> N <= 79 (留余量取 79).
  static const int maxLedsPerFillRangePacket = 79;

  /// Firmware BLE_RX_FRAME_MAX_LEN. Single packets must not exceed this.
  static const int bleRxFrameMaxLen = 250;
}
