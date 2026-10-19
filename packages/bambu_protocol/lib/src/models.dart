/// Printer state models for BambuDeck.
///
/// Field-for-field port of the BambuHelper ESP32 state model
/// (`include/bambu_state.h`), translated from fixed C buffers to immutable
/// Dart classes. The MQTT report parser in `report_parser.dart` produces
/// these; the app and the future hub consume them.

/// Connection mode for a printer slot.
enum PrinterMode { lan, cloud }

/// Bambu cloud region.
///
/// API hosts follow BambuHelper's measured table: everything non-CN answers
/// on api.bambulab.com (api.us.* 401s CN-issued tokens), CN is its own site.
enum CloudRegion {
  us('us.mqtt.bambulab.com', 'https://api.bambulab.com'),
  eu('eu.mqtt.bambulab.com', 'https://api.eu.bambulab.com'),
  cn('cn.mqtt.bambulab.com', 'https://api.bambulab.cn');

  const CloudRegion(this.mqttHost, this.apiBase);
  final String mqttHost;
  final String apiBase;
}

/// Canonical gcode state, mapped from the raw `gcode_state` string.
enum GcodeState {
  unknown('UNKNOWN'),
  idle('IDLE'),
  running('RUNNING'),
  pause('PAUSE'),
  prepare('PREPARE'),
  finish('FINISH'),
  failed('FAILED'),
  other('OTHER');

  const GcodeState(this.label);
  final String label;

  static GcodeState fromRaw(String raw) {
    switch (raw) {
      case 'UNKNOWN':
        return GcodeState.unknown;
      case 'IDLE':
        return GcodeState.idle;
      case 'RUNNING':
        return GcodeState.running;
      case 'PAUSE':
        return GcodeState.pause;
      case 'PREPARE':
        return GcodeState.prepare;
      case 'FINISH':
        return GcodeState.finish;
      case 'FAILED':
        return GcodeState.failed;
      case '':
        return GcodeState.unknown;
      default:
        return GcodeState.other;
    }
  }

  bool get isPrinting =>
      this == GcodeState.running ||
      this == GcodeState.pause ||
      this == GcodeState.prepare;
}

/// HMS severity, encoded in the high 16 bits of the HMS code:
/// 1 fatal, 2 serious, 3 common; anything else is unknown.
enum HmsSeverity { fatal, serious, common, unknown }

class HmsEntry {
  const HmsEntry({required this.attr, required this.code});

  factory HmsEntry.fromDynamic(dynamic json) {
    // The printer sends both numbers and decimal strings depending on field.
    int toInt(dynamic v) =>
        v is int ? v : int.tryParse(v?.toString() ?? '') ?? 0;
    return HmsEntry(attr: toInt(json['attr']), code: toInt(json['code']));
  }

  /// Module in the top byte, per BambuHelper `HmsEntry.attr`.
  final int attr;
  final int code;

  HmsSeverity get severity {
    final sev = (code >> 16) & 0xFF;
    switch (sev) {
      case 1:
        return HmsSeverity.fatal;
      case 2:
        return HmsSeverity.serious;
      case 3:
        return HmsSeverity.common;
      default:
        return HmsSeverity.unknown;
    }
  }

  /// Full 16-hex-char lookup key, matching Bambu's ecode format
  /// (e.g. `HMS_0300-0200-0002-0005` splits as attr=0x0300 code=0x0200...).
  String get hexKey =>
      attr.toRadixString(16).padLeft(8, '0') +
      code.toRadixString(16).padLeft(8, '0');

  /// Official ecode spelling, e.g. `HMS_0300-0100-0001-0003` (same format
  /// the printer screen and Bambu's wiki pages use).
  String get ecode => 'HMS_${hexKey.substring(0, 4)}-'
      '${hexKey.substring(4, 8)}-${hexKey.substring(8, 12)}-'
      '${hexKey.substring(12, 16)}'.toUpperCase();

  @override
  bool operator ==(Object other) =>
      other is HmsEntry && other.attr == attr && other.code == code;

  @override
  int get hashCode => Object.hash(attr, code);

  @override
  String toString() => 'HmsEntry(${hexKey.toUpperCase()})';
}

/// One filament slot inside an AMS unit.
class AmsTray {
  const AmsTray({
    required this.present,
    this.colorRrggbb,
    this.type = '',
    this.remain = -1,
  });

  final bool present;

  /// 0xRRGGBB parsed from the printer's `RRGGBBAA` hex string, null if absent.
  final int? colorRrggbb;

  /// Filament type, e.g. `PLA Matte`.
  final String type;

  /// Remaining filament 0-100, -1 = unknown / third-party spool.
  final int remain;

  AmsTray copyWith({bool? present, int? colorRrggbb, String? type, int? remain}) =>
      AmsTray(
        present: present ?? this.present,
        colorRrggbb: colorRrggbb ?? this.colorRrggbb,
        type: type ?? this.type,
        remain: remain ?? this.remain,
      );
}

/// One AMS unit (box). H2 series can report 5+ units (ids 0,1,2,128,129...);
/// we keep unit-level data for all of them and tray arrays as reported.
class AmsUnit {
  const AmsUnit({
    required this.id,
    this.humidity = 0,
    this.humidityRaw = 0,
    this.tempC = 0,
    this.dryRemainMin = 0,
    this.trays = const [],
  });

  final int id;
  final int humidity; // 0-5 scale reported by the printer
  final int humidityRaw; // raw RH percent when reported
  final double tempC;
  final int dryRemainMin; // minutes remaining, 0 = not drying
  final List<AmsTray> trays; // as reported (4 for AMS/AMS2, 1 for AMS HT)

  bool get drying => dryRemainMin > 0;

  @override
  String toString() => 'AmsUnit(id:$id, trays:${trays.length}, '
      'humidity:$humidity/$humidityRaw, temp:$tempC, dry:$dryRemainMin)';
}

class AmsState {
  const AmsState({
    required this.units,
    this.activeTrayId,
    this.activeTrayIndex,
    this.activeSource = ActiveTraySource.none,
    this.vtTray,
  });

  final List<AmsUnit> units;

  /// Active (feeding) tray: raw unit id + tray index within that unit.
  /// Raw ids follow the printer: 0-3 for AMS/AMS2, 128+ for AMS HT,
  /// 254 = external spool (see [vtTray]), 253 = overflow unit id
  /// (parser resolves it against the unit list in report order).
  final int? activeTrayId;
  final int? activeTrayIndex;

  /// Where the active tray id came from (snow > tray_now > none).
  final ActiveTraySource activeSource;

  /// External spool (virtual tray) when configured.
  final AmsTray? vtTray;

  bool get present => units.isNotEmpty || vtTray != null;
  bool get anyDrying => units.any((u) => u.drying);

  /// Look up the feeding tray swatch: external spool first, then by unit/tray.
  AmsTray? get activeTray {
    if (activeTrayId == 254) return vtTray;
    if (activeTrayId == null || activeTrayIndex == null) return null;
    for (final unit in units) {
      if (unit.id == activeTrayId) {
        final trays = unit.trays;
        if (activeTrayIndex! < trays.length) return trays[activeTrayIndex!];
      }
    }
    return null;
  }

  @override
  String toString() => 'AmsState(units:${units.length}, '
      'active:($activeTrayId,$activeTrayIndex), vt:${vtTray != null})';
}

enum ActiveTraySource { none, snow, trayNow }

/// Per-nozzle snapshot for dual-extruder printers (H2D/H2C).
class NozzleTemp {
  const NozzleTemp({required this.id, required this.tempC, required this.targetC});
  final int id; // 0 = right, 1 = left
  final double tempC;
  final double targetC;
}

/// Fan percentages, all 0-100.
class FanSpeeds {
  const FanSpeeds({
    this.cooling = 0,
    this.aux = 0,
    this.auxRight = 0,
    this.chamber = 0,
    this.exhaust = 0,
    this.heatbreak = 0,
  });

  final int cooling; // part cooling fan
  final int aux; // aux fan (left on dual-duct printers)
  final int auxRight;
  final int chamber;
  final int exhaust;
  final int heatbreak;

  @override
  String toString() => 'Fans(cool:$cooling aux:$aux chamber:$chamber '
      'hb:$heatbreak)';
}

/// One slicer-filament -> AMS tray mapping entry of the current job.
class PrintMapping {
  const PrintMapping({required this.amsUnitId, required this.trayId});
  final int amsUnitId;
  final int trayId;
}

/// Immutable snapshot of one printer, produced by the report parser.
class BambuState {
  const BambuState({
    required this.updatedAt,
    this.gcodeState = GcodeState.unknown,
    this.rawGcodeState = '',
    this.progress = 0,
    this.remainingMinutes = 0,
    this.stgCur = -1,
    this.nozzleTemp = 0,
    this.nozzleTarget = 0,
    this.nozzles = const [],
    this.bedTemp = 0,
    this.bedTarget = 0,
    this.chamberTemp = 0,
    this.fans = const FanSpeeds(),
    this.subtaskName = '',
    this.taskId = '',
    this.plateIdx = 0,
    this.layerNum = 0,
    this.totalLayers = 0,
    this.mappings = const [],
    this.wifiSignal,
    this.localIp = '',
    this.speedLevel = 0,
    this.doorOpen,
    this.lightState = -1,
    this.printError = 0,
    this.hms = const [],
    this.ams,
    this.isCalibrationJob = false,
  });

  final DateTime updatedAt;
  final GcodeState gcodeState;
  final String rawGcodeState;
  final int progress; // 0-100
  final int remainingMinutes;
  final int stgCur; // -1/255 idle, 0 printing, >0 substage
  final double nozzleTemp;
  final double nozzleTarget;

  /// Dual-extruder per-nozzle temps; empty for single-nozzle printers.
  final List<NozzleTemp> nozzles;
  final double bedTemp;
  final double bedTarget;
  final double chamberTemp;
  final FanSpeeds fans;
  final String subtaskName;
  final String taskId;
  final int plateIdx;
  final int layerNum;
  final int totalLayers;
  final List<PrintMapping> mappings;
  final int? wifiSignal; // RSSI dBm
  final String localIp;
  final int speedLevel; // 1 silent .. 4 ludicrous, 0 unknown
  final bool? doorOpen; // null until the printer reports a door field
  final int lightState; // -1 unknown, 0 off, 1 on
  final int printError; // print.print_error, 0 = none
  final List<HmsEntry> hms; // worst-first

  final AmsState? ams;
  final bool isCalibrationJob;

  bool get printing => gcodeState.isPrinting;
  bool get hasError => printError != 0 || hms.isNotEmpty;

  /// Worst HMS severity rank present (0 = fatal .. 3 = unknown/none).
  int get hmsWorstRank {
    var rank = 3;
    for (final e in hms) {
      final r = switch (e.severity) {
        HmsSeverity.fatal => 0,
        HmsSeverity.serious => 1,
        HmsSeverity.common => 2,
        HmsSeverity.unknown => 3,
      };
      if (r < rank) rank = r;
    }
    return rank;
  }

  /// Substage label for `stg_cur` while RUNNING (Bed Leveling, Heating...).
  String? stageLabel({bool zh = false}) => stageLabelFor(stgCur, zh: zh);

  @override
  String toString() => 'BambuState(${gcodeState.label} $progress% '
      'nozzle:$nozzleTemp/$nozzleTarget bed:$bedTemp/$bedTarget '
      'layer:$layerNum/$totalLayers hms:${hms.length})';
}

/// English + Chinese labels for `print.stg_cur` substages, ported from
/// BambuHelper `stgCurLabel()` (ids from BambuStudio CURRENT_STAGE_IDS).
String? stageLabelFor(int stg, {bool zh = false}) {
  const en = {
    1: 'Bed Leveling', 2: 'Preheating Bed', 3: 'Sweeping XY',
    4: 'Changing Filament', 7: 'Heating Nozzle', 8: 'Calibrating Flow',
    9: 'Scanning Bed', 10: 'Inspecting Layer 1', 11: 'Detecting Plate',
    12: 'Calibrating Lidar', 18: 'Calibrating Lidar', 13: 'Homing',
    14: 'Cleaning Nozzle', 15: 'Checking Temp', 19: 'Calibrating Flow',
    22: 'Unloading Filament', 24: 'Loading Filament', 25: 'Motor Noise Cali',
    31: 'Motor Noise Cali', 29: 'Cooling Chamber', 36: 'Accuracy Check',
    37: 'Accuracy Cali', 38: 'Accuracy Verify', 39: 'Nozzle Offset Cali',
    40: 'Hot Bed Leveling', 41: 'Quick Release Chk', 42: 'Door/Cover Check',
    43: 'Laser Cali', 44: 'Platform Check', 45: 'Cam Position Chk',
    46: 'Camera Cali', 47: 'Bed Leveling 1', 48: 'Bed Leveling 2',
    49: 'Heating Chamber', 50: 'Cooling Bed', 51: 'Cali Lines',
    52: 'Checking Material', 53: 'Live Cam Cali', 54: 'Waiting for Bed',
    55: 'Material Pos Chk', 56: 'Cutter Offset Cali', 57: 'Measuring Surface',
    58: 'Thermal Precond', 59: 'Homing Blade', 60: 'Camera Offset Cali',
    61: 'Blade Pos Cali', 62: 'Hotend Test', 63: 'Chamber Temp Wait',
    64: 'Preparing Hotend', 65: 'Nozzle Clump Cali', 66: 'Purifying Air',
    67: 'Rotary Measure', 68: 'Moving to Purge', 69: 'Cooling Nozzle',
    70: 'Centering Head', 71: 'Arc Fitting', 72: 'Hotend Detect',
    73: 'Plate Align Chk', 74: 'Foreign Object Chk', 75: 'Bed Underside Chk',
    76: 'Pre-Extruding', 77: 'Preparing AMS',
  };
  const zhMap = {
    1: '调平热床', 2: '预热热床', 3: 'XY 扫描', 4: '更换耗材', 7: '加热喷嘴',
    8: '流量校准', 9: '热床扫描', 10: '首层检测', 11: '检测打印板',
    12: '激光雷达校准', 18: '激光雷达校准', 13: '回零', 14: '清理喷嘴',
    15: '检查温度', 19: '流量校准', 22: '退料', 24: '进料', 25: '电机噪声校准',
    31: '电机噪声校准', 29: '腔体散热', 36: '精度检查', 37: '精度校准',
    38: '精度验证', 39: '喷嘴偏移校准', 40: '热床调平', 41: '快拆检查',
    42: '舱门检查', 43: '激光校准', 44: '平台检查', 45: '相机位置检查',
    46: '相机校准', 47: '热床调平 1', 48: '热床调平 2', 49: '加热腔体',
    50: '热床散热', 51: '校准线', 52: '检查耗材', 53: '实时相机校准',
    54: '等待热床', 55: '耗材位置检查', 56: '切刀偏移校准', 57: '表面测量',
    58: '热预处理', 59: '切刀回零', 60: '相机偏移校准', 61: '切刀位置校准',
    62: '喷嘴测试', 63: '等待腔温', 64: '准备喷嘴', 65: '喷嘴堵塞校准',
    66: '净化空气', 67: '旋转测量', 68: '移动到擦拭位', 69: '喷嘴散热',
    70: '打印头居中', 71: '弧线拟合', 72: '喷嘴检测', 73: '打印板对齐检查',
    74: '异物检查', 75: '热床底面检查', 76: '预挤出', 77: '准备 AMS',
  };
  if (stg <= 0 || stg == 255) return null;
  return zh ? zhMap[stg] : en[stg];
}

/// Human label for gcode states (zh + en).
String gcodeStateLabel(GcodeState s, {bool zh = false}) => switch (s) {
      GcodeState.unknown => zh ? '未知' : 'Unknown',
      GcodeState.idle => zh ? '空闲' : 'Idle',
      GcodeState.running => zh ? '打印中' : 'Printing',
      GcodeState.pause => zh ? '已暂停' : 'Paused',
      GcodeState.prepare => zh ? '准备中' : 'Preparing',
      GcodeState.finish => zh ? '已完成' : 'Finished',
      GcodeState.failed => zh ? '失败' : 'Failed',
      GcodeState.other => zh ? '其他' : 'Other',
    };
