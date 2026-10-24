import 'dart:convert';

import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('parseReport - running print (X1-style)', () {
    final state = parseReport(jsonDecode(_runningReport))!;

    test('job state and progress', () {
      expect(state.gcodeState, GcodeState.running);
      expect(state.progress, 42);
      expect(state.remainingMinutes, 55);
      expect(state.layerNum, 120);
      expect(state.totalLayers, 288);
      expect(state.subtaskName, 'benchy.gcode.3mf');
      expect(state.stgCur, 0);
    });

    test('temperatures', () {
      expect(state.nozzleTemp, 220.0);
      expect(state.nozzleTarget, 220.0);
      expect(state.bedTemp, 55.0);
      expect(state.bedTarget, 55.0);
      expect(state.chamberTemp, 33.0);
    });

    test('fans from legacy 0-15 values', () {
      expect(state.fans.cooling, 60); // 9/15
      expect(state.fans.aux, 60); // 9/15
      expect(state.fans.chamber, 0);
      expect(state.fans.heatbreak, 100);
    });

    test('device fields', () {
      expect(state.wifiSignal, -52);
      expect(state.speedLevel, 2);
      expect(state.localIp, '192.168.1.42');
      expect(state.lightState, 1);
      expect(state.doorOpen, isFalse); // home_flag bit 23 clear
    });

    test('hms worst-first with severity', () {
      expect(state.hms, hasLength(2));
      expect(state.hms.first.severity, HmsSeverity.fatal); // code 00010000
      expect(state.hms.last.severity, HmsSeverity.common); // code 00030000
      expect(state.hasError, isTrue);
    });

    test('ams trays and active tray from snow', () {
      expect(state.ams, isNotNull);
      final ams = state.ams!;
      expect(ams.units, hasLength(1));
      expect(ams.units.first.id, 0);
      expect(ams.units.first.humidityRaw, 40);
      expect(ams.units.first.tempC, 28.0);
      expect(ams.units.first.trays, hasLength(4));
      expect(ams.units.first.trays[0].type, 'PLA Matte');
      expect(ams.units.first.trays[0].colorRrggbb, 0x1A2B3C);
      expect(ams.units.first.trays[0].remain, 77);
      expect(ams.units.first.trays[1].present, isFalse);
      // extruder.snow = 0x0001 -> ams 0, tray 1... but tray 1 is empty; snow
      // points at what the printer is feeding regardless.
      expect(ams.activeSource, ActiveTraySource.snow);
      expect(ams.activeTrayId, 0);
      expect(ams.activeTrayIndex, 1);
    });

    test('print mapping', () {
      expect(state.mappings, hasLength(1));
      expect(state.mappings.first.amsUnitId, 0);
      expect(state.mappings.first.trayId, 1);
    });
  });

  group('parseReport - idle snapshot (P1-style pushall)', () {
    final state = parseReport(jsonDecode(_idleReport))!;

    test('state', () {
      expect(state.gcodeState, GcodeState.idle);
      expect(state.printing, isFalse);
      expect(state.progress, 0);
    });

    test('door via stat hex bit', () {
      // 0x00800000 set -> door open
      expect(state.doorOpen, isTrue);
    });

    test('fan_gear wins over legacy values', () {
      // fan_gear 0x000000FF -> cooling 100%, aux byte 0 -> 0%.
      expect(state.fans.cooling, 100);
      expect(state.fans.aux, 0);
    });

    test('chamber temp via legacy ctc path', () {
      expect(state.chamberTemp, 31.0);
    });

    test('ams tray_now flat index resolves positionally', () {
      final ams = state.ams!;
      expect(ams.activeSource, ActiveTraySource.trayNow);
      // tray_now "1" -> flat index 1 -> unit position 0, tray 1.
      expect(ams.activeTrayId, 0);
      expect(ams.activeTrayIndex, 1);
    });

    test('external spool via vt_tray + tray_now 254', () {
      final ams = parseReport(jsonDecode(_vtTrayReport))!.ams!;
      expect(ams.activeTrayId, 254);
      expect(ams.vtTray, isNotNull);
      expect(ams.vtTray!.type, 'PLA');
      expect(ams.activeTray!.type, 'PLA');
    });
  });

  group('parseReport - dual nozzle (H2D-style)', () {
    final state = parseReport(jsonDecode(_dualNozzleReport))!;

    test('per-nozzle temps replace shared fields', () {
      expect(state.nozzles, hasLength(2));
      // extruder.state 0x10 -> active nozzle 1 (left).
      // nozzle 1 packed temp: target 220 << 16 | 219.
      expect(state.nozzleTemp, 219.0);
      expect(state.nozzleTarget, 220.0);
      expect(state.nozzles[0].tempC, 210.0);
      expect(state.nozzles[0].targetC, 210.0);
    });

    test('chamber temp via device.ctc path', () {
      expect(state.chamberTemp, 45.0);
    });

    test('snow resolves against AMS HT unit id 128', () {
      final ams = state.ams!;
      expect(ams.units.first.id, 128);
      expect(ams.activeTrayId, 128);
      expect(ams.activeTrayIndex, 0);
    });
  });

  group('partial frame merge (previous state)', () {
    final full = parseReport(jsonDecode('''
      {"print": {
        "gcode_state": "RUNNING",
        "mc_percent": 42,
        "mc_remaining_time": 55,
        "subtask_name": "benchy.gcode.3mf",
        "task_id": "12345",
        "layer_num": 120,
        "total_layer_num": 288,
        "nozzle_temper": "220.0",
        "bed_temper": "55.0",
        "spd_lvl": 2,
        "hms": [{"attr": 50331648, "code": 65536}]
      }}
    '''))!;

    // A typical incremental push: only the sensor values changed.
    final partial = parseReport(
      jsonDecode('{"print": {"nozzle_temper": "205.5", "bed_temper": "50.0"}}'),
      previous: full,
    )!;

    test('identity survives a partial frame', () {
      expect(partial.gcodeState, GcodeState.running);
      expect(partial.subtaskName, 'benchy.gcode.3mf');
      expect(partial.taskId, '12345');
      expect(partial.progress, 42);
      expect(partial.remainingMinutes, 55);
      expect(partial.layerNum, 120);
      expect(partial.totalLayers, 288);
      expect(partial.speedLevel, 2);
    });

    test('changed fields update through a partial frame', () {
      expect(partial.nozzleTemp, 205.5);
      expect(partial.bedTemp, 50.0);
    });

    test('alarms persist without an hms key', () {
      expect(partial.hms.length, 1);
      expect(partial.hasError, isTrue);
    });

    test('no previous state still yields static defaults', () {
      final state =
          parseReport(jsonDecode('{"print":{"nozzle_temper":"30.0"}}'))!;
      expect(state.gcodeState, GcodeState.unknown);
      expect(state.subtaskName, '');
      expect(state.nozzleTemp, 30.0);
    });
  });

  group('edge cases', () {
    test('rejects non-print envelopes', () {
      expect(parseReport('not json'), isNull);
      expect(parseReport(jsonDecode('{"device":{"ip":"1.2.3.4"}}')), isNull);
    });

    test('missing optional fields default sanely', () {
      final state = parseReport(jsonDecode('{"print":{"gcode_state":"IDLE"}}'))!;
      expect(state.doorOpen, isNull);
      expect(state.wifiSignal, isNull);
      expect(state.lightState, -1);
      expect(state.ams, isNull);
      expect(state.hasError, isFalse);
    });

    test('pause state', () {
      final state =
          parseReport(jsonDecode('{"print":{"gcode_state":"PAUSE"}}'))!;
      expect(state.gcodeState, GcodeState.pause);
      expect(state.printing, isTrue);
    });

    test('calibration job flags', () {
      final state = parseReport(
          jsonDecode('{"print":{"gcode_state":"RUNNING",'
              '"print_type":"system","subtask_name":"flow_x_calib_mode"}}'))!;
      expect(state.isCalibrationJob, isTrue);
    });
  });
}

const _runningReport = '''
{
  "print": {
    "gcode_state": "RUNNING",
    "stg_cur": 0,
    "mc_percent": 42,
    "mc_remaining_time": 55,
    "nozzle_temper": "220.0",
    "nozzle_target_temper": "220",
    "bed_temper": "55.0",
    "bed_target_temper": "55",
    "chamber_temper": "33.0",
    "subtask_name": "benchy.gcode.3mf",
    "task_id": "123456",
    "plate_idx": 1,
    "layer_num": 120,
    "total_layer_num": 288,
    "cooling_fan_speed": "9",
    "big_fan1_speed": "9",
    "big_fan2_speed": "0",
    "heatbreak_fan_speed": "15",
    "wifi_signal": "-52dBm",
    "spd_lvl": 2,
    "home_flag": 0,
    "lights_report": [{"node": "chamber_light", "mode": "on"}],
    "print_error": 0,
    "hms": [
      {"attr": 50331648, "code": 65536},
      {"attr": 50331648, "code": 196608}
    ],
    "mapping": [{"ams_id": 0, "tray_id": 1}],
    "ams": {
      "tray_now": "255",
      "ams": [
        {
          "id": "0",
          "humidity": "4",
          "humidity_raw": "40",
          "temp": "28.0",
          "dry_time": "0",
          "tray": [
            {"id": "0", "tray_type": "PLA Matte", "tray_color": "1A2B3CFF", "remain": 77},
            {"id": "1"},
            {"id": "2", "tray_type": "PETG", "tray_color": "FF0000FF", "remain": -1},
            {"id": "3"}
          ]
        }
      ]
    },
    "extruder": {
      "info": [{"id": 0, "snow": 1}],
      "state": 0
    },
    "net": {"info": [{"ip": 704751808}]}
  }
}
''';

// 3232235594 little-endian uint32 -> 192.168.1.42

const _idleReport = '''
{
  "print": {
    "gcode_state": "IDLE",
    "stg_cur": 255,
    "mc_percent": 0,
    "nozzle_temper": "28.5",
    "nozzle_target_temper": "0",
    "bed_temper": "27.0",
    "bed_target_temper": "0",
    "ctc": {"info": {"temp": "31.0"}},
    "fan_gear": 255,
    "stat": "800000",
    "spd_lvl": 2,
    "lights_report": [{"node": "chamber_light", "mode": "off"}],
    "ams": {
      "tray_now": "1",
      "ams": [
        {"id": "0", "humidity": "3", "humidity_raw": "35", "temp": "27.0",
         "tray": [
           {"id": "0", "tray_type": "PLA", "tray_color": "00FF00FF", "remain": 50},
           {"id": "1", "tray_type": "ABS", "tray_color": "0000FFFF", "remain": 20},
           {"id": "2"},
           {"id": "3"}
         ]}
      ]
    }
  }
}
''';

const _vtTrayReport = '''
{
  "print": {
    "gcode_state": "RUNNING",
    "ams": {
      "tray_now": "254",
      "ams": []
    },
    "vt_tray": {"tray_type": "PLA", "tray_color": "ABCDEF01", "remain": 66}
  }
}
''';

const _dualNozzleReport = '''
{
  "print": {
    "gcode_state": "RUNNING",
    "nozzle_temper": "210.0",
    "nozzle_target_temper": "210",
    "bed_temper": "50.0",
    "bed_target_temper": "50",
    "device": {"ctc": {"info": {"temp": "45.0"}}},
    "ams": {
      "ams": [
        {"id": "128", "humidity": "2", "humidity_raw": "20", "temp": "26.0",
         "tray": [{"id": "0", "tray_type": "PA", "tray_color": "123456FF", "remain": 90}]}
      ]
    },
    "extruder": {
      "info": [
        {"id": 0, "temp": 13762770, "snow": 0},
        {"id": 1, "temp": 14418139, "snow": 32768}
      ],
      "state": 16
    }
  }
}
''';
// 13762770 = (210 << 16) | 210 -> nozzle 0: 210.0 / 210.0
// 14418139 = (220 << 16) | 219 -> nozzle 1: 219.0 / 220.0
// state 16 -> active nozzle 1; snow 32768 = 0x8000 -> ams id 128, tray 0
