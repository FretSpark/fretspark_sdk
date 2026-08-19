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

  /// Internal use: tells the device to reboot into OTA mode (sent via
  /// the runtime command service). Reuses the [power] 0x01 byte but
  /// with different params, hence the separate name.
  static const int enterOta = 0x01;

  /// RGB layout mode (0 = matrix layout / 1 = linear layout).
  /// Used to adapt to hardware with different LED arrangements such
  /// as WS2812/SK6812.
  static const int linearLayout = 0x02; // [0/1]

  /// Set the LED count (uint16 big-endian).
  /// Used by the APP to dynamically adjust the number of LEDs the
  /// firmware drives, adapting to strips of different lengths.
  static const int ledCount = 0x03; // [countH, countL]

  static const int color = 0x04; // [hueH, hueL, satH, satL, 0, 0]
  static const int brightness = 0x05; // [briH, briL, 0, 0, 0, 0] (0-1000)
  static const int mode = 0x06; // [modeH, modeL]
  static const int direction = 0x07; // [dir]
  static const int speed = 0x08; // [speed]
  static const int musicMode = 0x09; // AI rhythm, compound params

  // === Notify: battery ===
  static const int batteryNotify = 0x0A; // [level, mvH, mvL]

  /// Sync the RTC time (firmware uses this as the reference clock for
  /// the 0x0D scheduled power on/off).
  /// payload = [yearH, yearL, month, day, hour, minute, second] (7 bytes)
  static const int rtcTime = 0x0B; // [yyH, yyL, MM, dd, HH, mm, ss]

  /// Trigger the firmware to proactively report its status (battery,
  /// config, etc.). Firmware internally calls send_type_request(8) and
  /// send_type_request(9).
  /// payload = [0x01] (currently only 0x01 is supported)
  static const int queryStatus = 0x0C; // [0x01]

  /// Set scheduled power on/off (depends on the RTC time synced via 0x0B).
  /// payload = [slot, onOff, hour, minute, second, reserved]
  ///   slot: timer slot index (firmware-reserved, usually 0)
  ///   onOff: 0 = scheduled power-off, non-zero = scheduled power-on
  ///   hour/minute/second: trigger time of day
  ///   reserved: reserved byte (firmware writes to device_time_*[4],
  ///     currently fixed at 0)
  static const int timer = 0x0D; // [slot, onOff, HH, mm, ss, 0x00]

  // === Voice / mic ===
  static const int micSource =
      0x0F; // [0=appMic/1=localMic/6=vibration/0xFF=off]
  /// **Deprecated**: this command serves two conflicting duties in the
  /// firmware — "static color" and "APP mic energy injection" (it pins
  /// device_rgb_state to 4, disabling AI rhythm rendering).
  /// The SDK has replaced it with [fillColor] (0x15) + [energyInject]
  /// (0x26). Brand apps should avoid this command. See CHANGELOG.
  static const int staticColor = 0x10; // legacy, replaced by fillColor + energyInject
  static const int voiceMode = 0x11; // [0x00=on / 0xFF=off]
  static const int voiceSensitivity = 0x12; // [value]

  /// Physical knob HSL report (firmware-pushed notify; the APP may
  /// also simulate knob input).
  /// payload = [knobValueH, knobValueL] (uint16, 0-360)
  /// **Note**: rarely used on the APP side in the physical-knob
  /// scenario; kept for advanced developers.
  static const int knobHsl = 0x13; // [valH, valL]

  /// Custom continuous-segment LED colors (writes N consecutive LEDs
  /// starting at start_index).
  /// payload = [startIndex, r1, g1, b1, r2, g2, b2, ...]
  ///   len (the LEN field in the BLE frame) = 1 + 3N (N = LED count)
  /// Difference from [batchData] (0x16):
  ///   - 0x14 is a contiguous segment (each LED index increments by 1),
  ///     refreshed in a single frame, high performance.
  ///   - 0x16 is a sparse segment (each LED index is specified
  ///     independently) and must be wrapped by 0x1C/0x1D batch transfer.
  /// Single-packet N <= [maxLedsPerFillRangePacket] (BLE frame length
  /// constraint).
  static const int fillRange = 0x14; // [start, r,g,b, r,g,b, ...]

  // === Drawing / fill ===
  static const int fillColor = 0x15; // [0, r, 0, g, 0, b]
  static const int batchData = 0x16; // [seq, count, idx, r, g, b, ...]
  static const int groupEnd = 0x17; // []
  static const int selectionMask = 0x18; // [50-byte bitmap] or [] to clear
  static const int groupMap = 0x19; // [baseIdx, ...groupIds] or [] to clear
  static const int groupColor = 0x1A; // [gid, r, g, b]

  /// Set the music style (a style system independent of [mode] 0x06 and
  /// [musicMode] 0x09).
  /// The firmware internally calls apply_music_style(styleId), triggering
  /// an independent render pipeline.
  /// payload = [styleId] (single byte, 0-255)
  /// **Note**: in the firmware, styleId >= 100 is reset to 0 (protection
  /// logic used when switching the pickup source).
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
  /// MTU=247 -> writeWithoutResponse max 244 -> N <= 79 (kept at 79 with margin).
  static const int maxLedsPerFillRangePacket = 79;

  /// Firmware BLE_RX_FRAME_MAX_LEN. Single packets must not exceed this.
  static const int bleRxFrameMaxLen = 250;
}
