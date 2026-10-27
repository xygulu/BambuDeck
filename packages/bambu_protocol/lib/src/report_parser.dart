/// Parses Bambu printer MQTT report payloads into [BambuState].
///
/// The wire format is `{"print": { ...fields... }}` on topic
/// `device/{serial}/report`. Field names and conversion rules follow the
/// BambuHelper ESP32 parser (`src/bambu_mqtt.cpp`), minus the ESP32-only
/// memory tricks (JSON filters, memmem bypasses): Dart parses the whole
/// document with dart:convert.
library;

import 'dart:convert';

import 'models.dart';

/// Parse a full report envelope. Returns null when the payload is not a
/// valid `{"print": ...}` document (e.g. `{"device":...}` only frames).
///
/// Pass the previous state as [previous]: Bambu sends PARTIAL frames (only
/// the fields that changed) between full reports, and a missing key must
/// keep the previous value instead of resetting to defaults.
BambuState? parseReport(dynamic payloadOrJson, {BambuState? previous}) {
  dynamic doc = payloadOrJson;
  if (doc is String) {
    try {
      doc = jsonDecode(doc);
    } on FormatException {
      return null;
    }
  } else if (doc is List<int>) {
    try {
      doc = jsonDecode(utf8.decode(doc));
    } on FormatException {
      return null;
    }
  }
  if (doc is! Map) return null;
  final print_ = doc['print'];
  if (print_ is! Map) return null;
  return parsePrintSection(print_, previous: previous);
}

/// Parse just the `print` section (exposed for tests and the hub relay,
/// which may receive pre-split sections).
BambuState parsePrintSection(Map<dynamic, dynamic> print_,
    {BambuState? previous}) {
  final now = DateTime.now();

  bool has(String key) => print_.containsKey(key);

  // ---- gcode state ---------------------------------------------------------
  final rawState =
      has('gcode_state') ? _str(print_['gcode_state']) : previous?.rawGcodeState ?? '';
  final gcodeState = GcodeState.fromRaw(rawState);

  // ---- extruder: dual-nozzle temps + the snow feed pointer ------------------
  final nozzles = <NozzleTemp>[];
  var snowAmsId = -1;
  var snowTrayIdx = -1;
  var nozzleTemp =
      has('nozzle_temper') ? _double(print_['nozzle_temper']) : previous?.nozzleTemp ?? 0;
  var nozzleTarget = has('nozzle_target_temper')
      ? _double(print_['nozzle_target_temper'])
      : previous?.nozzleTarget ?? 0;

  final extruder = print_['extruder'];
  if (extruder is Map) {
    final info = extruder['info'];
    if (info is List && info.isNotEmpty) {
      final dualNozzle = info.length >= 2;
      // extruder.state bits 4..7 select the active nozzle on dual-extruder.
      var activeNozzle = 0;
      final st = extruder['state'];
      if (dualNozzle && st is int) {
        activeNozzle = (st >> 4) & 0x0F;
        if (activeNozzle > 1) activeNozzle = 0;
      }
      for (final entry in info) {
        if (entry is! Map) continue;
        final id = entry['id'];
        if (id is! int || id > 1) continue;
        // temp is packed as (target << 16) | current.
        final packed = _intOrNull(entry['temp']);
        if (dualNozzle && packed != null) {
          nozzles.add(NozzleTemp(
            id: id,
            tempC: (packed & 0xFFFF).toDouble(),
            targetC: (packed >> 16).toDouble(),
          ));
        }
        final isNozzle = dualNozzle ? id == activeNozzle : true;
        if (isNozzle) {
          if (dualNozzle && packed != null) {
            // Per-nozzle temps replace the shared nozzle_temper fields.
            nozzleTemp = (packed & 0xFFFF).toDouble();
            nozzleTarget = (packed >> 16).toDouble();
          }
          final snow = entry['snow'];
          if (snow is int) {
            snowAmsId = snow >> 8;
            snowTrayIdx = snow & 0x03;
          }
        }
      }
    }
  } else if (previous != null) {
    // Frame carried no extruder section: keep the last known nozzle temps
    // and the snow feed pointer (it drives the AMS active-tray pick below).
    nozzles.addAll(previous.nozzles);
    final prevAms = previous.ams;
    if (prevAms != null &&
        prevAms.activeSource == ActiveTraySource.snow &&
        prevAms.activeTrayId != null &&
        prevAms.activeTrayId! >= 0 &&
        prevAms.activeTrayId! < 16) {
      snowAmsId = prevAms.activeTrayId!;
      snowTrayIdx = prevAms.activeTrayIndex ?? -1;
    }
  }

  // ---- temperatures ---------------------------------------------------------
  final bedTemp =
      has('bed_temper') ? _double(print_['bed_temper']) : previous?.bedTemp ?? 0;
  final bedTarget = has('bed_target_temper')
      ? _double(print_['bed_target_temper'])
      : previous?.bedTarget ?? 0;
  // Chamber temp: direct field first, then the legacy ctc path, then the
  // H2C/H2D device.ctc path (order mirrors BambuHelper).
  double chamberOf() {
    final direct = _doubleOrNull(print_['chamber_temper']);
    if (direct != null) return direct;
    final legacy = _ctcTempOrNull(print_['ctc']);
    if (legacy != null) return legacy;
    final device = _ctcTempOrNull(print_['device']?['ctc']);
    if (device != null) return device;
    return previous?.chamberTemp ?? 0;
  }

  final chamberTemp = chamberOf();

  // ---- fans -----------------------------------------------------------------
  // fan_gear (when reported) packs PWM bytes: b0 part cooling, b1 aux,
  // b2 chamber. Legacy fallbacks are 0-15 step values as strings or ints.
  // Conversion follows BambuHelper pwmToPct/legacyToPct (plain variants).
  final gear = has('fan_gear') ? _intOrNull(print_['fan_gear']) : null;
  int pctFromPwm(int b) => (b * 100 + 127) ~/ 255;
  int pctFromLegacy(int v) => (v.clamp(0, 15) * 100) ~/ 15;

  int fanPct(dynamic legacyValue, {required int prevPct, int gearByte = -1}) {
    if (gear != null && gearByte >= 0) {
      return pctFromPwm((gear >> (gearByte * 8)) & 0xFF);
    }
    final v = legacyValue == null ? null : _intOrNull(legacyValue);
    // Key absent from this frame: keep the previous reading, not zero.
    return v != null ? pctFromLegacy(v) : prevPct;
  }

  final prevFans = previous?.fans;
  final fans = FanSpeeds(
    cooling: fanPct(print_['cooling_fan_speed'],
        prevPct: prevFans?.cooling ?? 0, gearByte: 0),
    aux: fanPct(print_['big_fan1_speed'],
        prevPct: prevFans?.aux ?? 0, gearByte: 1),
    chamber: fanPct(print_['big_fan2_speed'],
        prevPct: prevFans?.chamber ?? 0, gearByte: 2),
    heatbreak: fanPct(print_['heatbreak_fan_speed'],
        prevPct: prevFans?.heatbreak ?? 0),
  );

  // ---- job identity ---------------------------------------------------------
  final subtaskName = has('subtask_name')
      ? _str(print_['subtask_name'])
      : previous?.subtaskName ?? '';
  final mappings = <PrintMapping>[];
  final rawMapping = print_['mapping'];
  if (rawMapping is List) {
    for (final m in rawMapping) {
      if (m is Map) {
        final ams = _intOrNull(m['ams_id']);
        final tray = _intOrNull(m['tray_id']);
        if (ams != null && tray != null && ams >= 0 && tray >= 0) {
          mappings.add(PrintMapping(amsUnitId: ams, trayId: tray));
        }
      } else if (m is int) {
        // Packed (amsUnitId << 8) | trayId form.
        mappings.add(PrintMapping(amsUnitId: m >> 8, trayId: m & 0xFF));
      }
    }
  } else if (previous != null) {
    mappings.addAll(previous.mappings);
  }

  // ---- door sensor ----------------------------------------------------------
  // H2/P2S: `stat` hex string, bit 0x00800000. X1: `home_flag` int, bit 23.
  bool? doorOpen;
  final stat = print_['stat'];
  if (stat != null) {
    final v = int.tryParse(stat.toString(), radix: stat is int ? 10 : 16);
    if (v != null) doorOpen = (v & 0x00800000) != 0;
  }
  if (doorOpen == null) {
    final homeFlag = _intOrNull(print_['home_flag']);
    if (homeFlag != null) doorOpen = (homeFlag & (1 << 23)) != 0;
  }
  doorOpen ??= previous?.doorOpen;

  // ---- chamber light --------------------------------------------------------
  var lightState = previous?.lightState ?? -1;
  final lights = print_['lights_report'];
  if (lights is List && lights.isNotEmpty && lights.first is Map) {
    final mode = _str((lights.first as Map)['mode']).toLowerCase();
    if (mode == 'on') {
      lightState = 1;
    } else if (mode == 'off') {
      lightState = 0;
    }
  }

  // ---- HMS ------------------------------------------------------------------
  // A frame without print_error/hms keys says nothing about alarms - errors
  // persist until the printer explicitly reports them gone.
  final printError = has('print_error')
      ? _intOr(print_['print_error'], 0)
      : previous?.printError ?? 0;
  final hms = <HmsEntry>[];
  final rawHms = print_['hms'];
  if (rawHms is List) {
    for (final h in rawHms) {
      if (h is Map) hms.add(HmsEntry.fromDynamic(h));
    }
    int rank(HmsEntry e) => switch (e.severity) {
          HmsSeverity.fatal => 0,
          HmsSeverity.serious => 1,
          HmsSeverity.common => 2,
          HmsSeverity.unknown => 3,
        };
    // Worst-first, deterministic key order as tie-break (a reordered array
    // cannot manufacture a change) - mirrors BambuHelper hmsInsertSorted.
    hms.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.hexKey.compareTo(b.hexKey);
    });
  } else if (previous != null) {
    hms.addAll(previous.hms);
  }

  // ---- AMS ------------------------------------------------------------------
  // Frame-level keep: a frame without an ams section reuses the last parsed
  // AMS state whole. Partial frames (only vt_tray, or ams without the unit
  // list) merge per-section inside _parseAms — 空小节不再是「没有 AMS」。
  final ams = has('ams') || has('vt_tray')
      ? _parseAms(print_, snowAmsId, snowTrayIdx, previous?.ams)
      : previous?.ams;

  // ---- calibration job flags -------------------------------------------------
  final printType =
      has('print_type') ? _str(print_['print_type']) : '';
  final gcodeFile =
      has('gcode_file') ? _str(print_['gcode_file']) : '';
  final isCalibration = printType == 'system' ||
      subtaskName.endsWith('_calib_mode') ||
      gcodeFile.contains('auto_cali_for_user') ||
      gcodeFile.contains('extrusion_cali');

  return BambuState(
    updatedAt: now,
    rawGcodeState: rawState,
    gcodeState: gcodeState,
    progress: has('mc_percent')
        ? _intOr(print_['mc_percent'], 0).clamp(0, 100)
        : previous?.progress ?? 0,
    remainingMinutes: has('mc_remaining_time')
        ? _intOr(print_['mc_remaining_time'], 0)
        : previous?.remainingMinutes ?? 0,
    stgCur:
        has('stg_cur') ? _intOr(print_['stg_cur'], -1) : previous?.stgCur ?? -1,
    nozzleTemp: nozzleTemp,
    nozzleTarget: nozzleTarget,
    nozzles: nozzles,
    bedTemp: bedTemp,
    bedTarget: bedTarget,
    chamberTemp: chamberTemp,
    fans: fans,
    subtaskName: subtaskName,
    taskId: has('task_id') ? _str(print_['task_id']) : previous?.taskId ?? '',
    plateIdx: has('plate_idx')
        ? _intOrNull(print_['plate_idx']) ?? 0
        : previous?.plateIdx ?? 0,
    layerNum: has('layer_num')
        ? _intOr(print_['layer_num'], 0)
        : previous?.layerNum ?? 0,
    totalLayers: has('total_layer_num')
        ? _intOr(print_['total_layer_num'], 0)
        : previous?.totalLayers ?? 0,
    mappings: mappings,
    wifiSignal: has('wifi_signal')
        ? _intPrefix(print_['wifi_signal'])
        : previous?.wifiSignal,
    localIp: has('net') ? _netIp(print_) : previous?.localIp ?? '',
    speedLevel: has('spd_lvl')
        ? _intOr(print_['spd_lvl'], 0)
        : previous?.speedLevel ?? 0,
    doorOpen: doorOpen,
    lightState: lightState,
    printError: printError,
    hms: hms,
    ams: ams,
    isCalibrationJob: isCalibration,
    fun: has('fun') ? _intOrNull(print_['fun']) : previous?.fun,
  );
}

/// 解析 AMS 小节。固件的 `ams` 小节是**增量**的：外部料卷余量变化只推
/// `vt_tray`、进料换槽只推 `ams.tray_now`，两 种帧都不带 unit 列表 —— 直接
/// 解析会得到空 units，页面整块闪成「未检测到 AMS」(2026-10-27 稳定性整改)。
/// 所以凡是这一帧没报的部分，都沿用 [previous]：
///   - 没有 unit 列表 → 整体沿用 previous.units；
///   - unit 在但 `tray` 数组缺失/为空 → 料盘沿用 previous 同 id unit；
///   - 没有 `vt_tray` 且也不带 unit 列表（部分帧）→ 沿用 previous.vtTray；
///     带 unit 列表（全量帧）时没有就是真没有（外部料卷被取下）。
AmsState? _parseAms(
    Map<dynamic, dynamic> print_, int snowAmsId, int snowTrayIdx,
    [AmsState? previous]) {
  final raw = print_['ams'];
  final prevUnits = previous?.units ?? const <AmsUnit>[];
  final units = <AmsUnit>[];
  var haveUnitList = false;
  if (raw is Map) {
    final rawUnits = raw['ams'] ?? raw['unit'];
    if (rawUnits is List) {
      haveUnitList = true;
      for (final u in rawUnits) {
        if (u is! Map) continue;
        final id = _intOr(u['id'], units.length);
        var trays = <AmsTray>[];
        final rawTrays = u['tray'];
        if (rawTrays is List) {
          for (final t in rawTrays) {
            trays.add(_parseTray(t));
          }
        }
        // 这帧没报料盘就别把上次的数据抹掉（拔掉整个 AMS 时 unit 会从
        // 列表里消失，不会只清空 tray 数组）。
        if (trays.isEmpty) {
          final prev = prevUnits.where((x) => x.id == id).toList();
          if (prev.isNotEmpty && prev.first.trays.isNotEmpty) {
            trays = prev.first.trays;
          }
        }
        units.add(AmsUnit(
          id: id,
          humidity: _intOr(u['humidity'], 0),
          humidityRaw: _intOr(u['humidity_raw'], 0),
          tempC: _double(u['temp']),
          dryRemainMin: _intOr(u['dry_time'], 0),
          trays: trays,
        ));
      }
    }
  }
  if (!haveUnitList) units.addAll(prevUnits);

  // External spool (virtual tray) sits at the PRINT level (`print.vt_tray`),
  // NOT inside `print.ams` (后者没有这个键, 2026-10-23 实测)。
  AmsTray? vtTray;
  final rawVt = print_['vt_tray'];
  if (rawVt is Map) {
    final t = _parseTray(rawVt);
    if (t.present) vtTray = t;
  } else if (!haveUnitList) {
    vtTray = previous?.vtTray; // 部分帧：没报就是没变
  }

  // Active tray: snow (what the nozzle is actually feeding) wins,
  // then tray_now (logically loaded). 254 = external spool, 255 = none.
  int? activeId;
  int? activeIdx;
  var source = ActiveTraySource.none;
  if (snowAmsId >= 0) {
    activeId = snowAmsId;
    activeIdx = snowTrayIdx;
    source = ActiveTraySource.snow;
  } else if (raw is Map) {
    final trayNow = raw['tray_now'];
    if (trayNow != null) {
      final v = int.tryParse(trayNow.toString());
      if (v == 254) {
        return AmsState(
          units: units,
          activeTrayId: 254,
          activeSource: ActiveTraySource.trayNow,
          vtTray: vtTray,
        );
      }
      if (v != null && v >= 0 && v < 16) {
        // tray_now is a flat index into trays[unit*4 + trayId] over the
        // first four tray units (BambuHelper activeTray semantics).
        final unitPos = v ~/ 4;
        final trayPos = v % 4;
        if (unitPos < units.length) {
          activeId = units[unitPos].id;
          activeIdx = trayPos;
          source = ActiveTraySource.trayNow;
        }
      }
    }
  }

  return AmsState(
    units: units,
    activeTrayId: activeId,
    activeTrayIndex: activeIdx,
    activeSource: source,
    vtTray: vtTray,
  );
}

AmsTray _parseTray(dynamic raw) {
  if (raw is! Map) return const AmsTray(present: false);
  final type = _str(raw['tray_type']);
  // tray_color is "RRGGBBAA"; some firmwares put the color in cols[0].
  var colorStr = _str(raw['tray_color']);
  if (colorStr.length < 6) {
    final cols = raw['cols'];
    if (cols is List && cols.isNotEmpty) {
      final c0 = cols.first;
      if (c0 is List && c0.isNotEmpty) {
        colorStr = c0.first.toString();
      } else {
        colorStr = c0.toString();
      }
    }
  }
  int? color;
  if (colorStr.length >= 6) {
    color = int.tryParse(colorStr.substring(0, 6), radix: 16);
  }
  final remain = _intOr(raw['remain'], -1);
  final present = type.isNotEmpty || color != null || remain > 0;
  return AmsTray(present: present, colorRrggbb: color, type: type, remain: remain);
}

double? _ctcTempOrNull(dynamic ctc) {
  if (ctc is! Map) return null;
  final info = ctc['info'];
  if (info is Map) return _doubleOrNull(info['temp']);
  return null;
}

/// `print.net.info[].ip` carries the LAN IP as a little-endian uint32 string;
/// the first octet is the least-significant byte.
String _netIp(Map<dynamic, dynamic> print_) {
  final net = print_['net'];
  if (net is! Map) return '';
  final info = net['info'];
  if (info is List && info.isNotEmpty && info.first is Map) {
    final v = (info.first as Map)['ip'];
    if (v is String && v.contains('.')) return v; // already dotted
    final n = int.tryParse(v?.toString() ?? '');
    if (n != null) {
      return [
        n & 0xFF,
        (n >> 8) & 0xFF,
        (n >> 16) & 0xFF,
        (n >> 24) & 0xFF,
      ].join('.');
    }
  }
  return '';
}

String _str(dynamic v) => v?.toString() ?? '';

int _intOr(dynamic v, int fallback) {
  final n = _intOrNull(v);
  return n ?? fallback;
}

int? _intOrNull(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

double _double(dynamic v) => _doubleOr(v, 0);

double? _doubleOrNull(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

double _doubleOr(dynamic v, double fallback) {
  if (v is num) return v.toDouble();
  if (v is String) {
    final parsed = double.tryParse(v);
    if (parsed != null) return parsed;
  }
  return fallback;
}

/// Integer prefix parse, e.g. "-52dBm" -> -52 (wifi_signal arrives both ways).
int? _intPrefix(dynamic v) {
  final s = v?.toString() ?? '';
  final m = RegExp(r'^-?\d+').firstMatch(s);
  return m == null ? null : int.parse(m.group(0)!);
}
