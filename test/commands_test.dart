// Unit tests for the command-code constants in FretCommand.
//
// These guard against accidental re-numbering when commands.dart is
// edited, and verify the protocol-level invariants the SDK relies on
// (frame delimiters, coalesce set, packet-size constants).

import 'package:flutter_test/flutter_test.dart';

import 'package:fretspark_sdk/src/core/commands.dart';

void main() {
  group('Frame delimiters', () {
    test('APP -> firmware starts with 0xBC, ends with 0x55', () {
      expect(kFrameStartAppTo_FW, 0xBC);
      expect(kFrameEndAppToFW, 0x55);
    });

    test('firmware -> APP starts with 0xCC, ends with 0xAA', () {
      expect(kFrameStartFWToApp, 0xCC);
      expect(kFrameEndFWToApp, 0xAA);
    });
  });

  group('Command codes are stable (do not renumber)', () {
    // The firmware's other_function.c hard-codes these case values.
    // Renumbering any of them would silently break protocol compat.
    test('power / led / etc.', () {
      expect(FretCommand.power, 0x01);
      expect(FretCommand.linearLayout, 0x02);
      expect(FretCommand.ledCount, 0x03);
      expect(FretCommand.color, 0x04);
      expect(FretCommand.brightness, 0x05);
      expect(FretCommand.mode, 0x06);
      expect(FretCommand.direction, 0x07);
      expect(FretCommand.speed, 0x08);
      expect(FretCommand.musicMode, 0x09);
      expect(FretCommand.batteryNotify, 0x0A);
      expect(FretCommand.rtcTime, 0x0B);
      expect(FretCommand.queryStatus, 0x0C);
      expect(FretCommand.timer, 0x0D);
    });

    test('voice / mic / knob / range', () {
      expect(FretCommand.micSource, 0x0F);
      expect(FretCommand.staticColor, 0x10);
      expect(FretCommand.voiceMode, 0x11);
      expect(FretCommand.voiceSensitivity, 0x12);
      expect(FretCommand.knobHsl, 0x13);
      expect(FretCommand.fillRange, 0x14);
    });

    test('group / music style / batch', () {
      expect(FretCommand.fillColor, 0x15);
      expect(FretCommand.batchData, 0x16);
      expect(FretCommand.groupEnd, 0x17);
      expect(FretCommand.selectionMask, 0x18);
      expect(FretCommand.groupMap, 0x19);
      expect(FretCommand.groupColor, 0x1A);
      expect(FretCommand.musicStyle, 0x1B);
      expect(FretCommand.batchBegin, 0x1C);
      expect(FretCommand.batchEnd, 0x1D);
    });

    test('query / metronome / learning / classroom / energy / index / diy', () {
      expect(FretCommand.queryVersion, 0x1E);
      expect(FretCommand.queryLedConfig, 0x1F);
      expect(FretCommand.metronomeStart, 0x20);
      expect(FretCommand.metronomeStop, 0x21);
      expect(FretCommand.learningLed, 0x22);
      expect(FretCommand.teacherTxStart, 0x23);
      expect(FretCommand.studentRxStart, 0x24);
      expect(FretCommand.classroomStop, 0x25);
      expect(FretCommand.energyInject, 0x26);
      expect(FretCommand.setLedIndexMode, 0x27);
      expect(FretCommand.queryLedIndexMode, 0x28);
      expect(FretCommand.setDiyModeList, 0x29);
      expect(FretCommand.queryDiyModeList, 0x2A);
    });
  });

  group('Coalesce set', () {
    test('contains exactly the high-frequency commands', () {
      expect(FretCommand.coalesceCommands, {
        FretCommand.color,
        FretCommand.brightness,
        FretCommand.speed,
        FretCommand.voiceSensitivity,
        FretCommand.learningLed,
      });
    });

    test('timer is NOT coalesced (would lose scheduled power events)', () {
      expect(FretCommand.coalesceCommands.contains(FretCommand.timer), isFalse);
    });

    test('rtcTime is NOT coalesced (each setRtcTime call matters)', () {
      expect(FretCommand.coalesceCommands.contains(FretCommand.rtcTime), isFalse);
    });

    test('fillRange is NOT coalesced (each frame is its own LED data)', () {
      expect(
        FretCommand.coalesceCommands.contains(FretCommand.fillRange),
        isFalse,
      );
    });

    test('musicStyle is NOT coalesced (each style is a discrete event)', () {
      expect(
        FretCommand.coalesceCommands.contains(FretCommand.musicStyle),
        isFalse,
      );
    });
  });

  group('Packet-size constants', () {
    test('maxLedsPerPacket = 59 (0x22 learningLed frame constraint)', () {
      expect(FretCommand.maxLedsPerPacket, 59);
      // Frame: BC + 0x22 + LEN + 0x02 + count + idx + 4N + 0x55 = 7 + 4N.
      // MTU 247 -> writeWithoutResponse 244 -> N <= (244 - 7) / 4 = 59.25.
      // So 59 is the largest N that fits.
      final frameLen = 7 + 4 * FretCommand.maxLedsPerPacket;
      expect(frameLen, lessThanOrEqualTo(244));
    });

    test('maxLedsPerFillRangePacket = 79 (0x14 fillRange frame constraint)', () {
      expect(FretCommand.maxLedsPerFillRangePacket, 79);
      // Frame: BC + 0x14 + LEN + start + 3N + 0x55 = 6 + 3N.
      // MTU 247 -> writeWithoutResponse 244 -> N <= (244 - 6) / 3 = 79.33.
      // So 79 is the largest N that fits.
      final frameLen = 6 + 3 * FretCommand.maxLedsPerFillRangePacket;
      expect(frameLen, lessThanOrEqualTo(244));
    });

    test('bleRxFrameMaxLen = 250 (firmware BLE_RX_FRAME_MAX_LEN)', () {
      expect(FretCommand.bleRxFrameMaxLen, 250);
    });
  });

  group('enterOta alias', () {
    test('enterOta reuses the 0x01 power command code', () {
      // The firmware branches on the [0x02, 0x01] parameter of 0x01
      // to enter OTA mode, so the SDK alias intentionally shares the
      // command byte with `power`.
      expect(FretCommand.enterOta, FretCommand.power);
      expect(FretCommand.enterOta, 0x01);
    });
  });
}
