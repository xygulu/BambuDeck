import 'package:bambu_protocol/bambu_protocol.dart';

import 'log_buffer.dart';
import 'printer_profile.dart';

/// One live printer connection, abstracted so the hub relay / a test fake
/// can substitute for the MQTT transport later (PRD FR-9).
///
/// Pure Dart (no Riverpod/Flutter): the app's [ConnectionNotifier] and the
/// standalone web service (bin/hub.dart) both drive this same seam.
abstract class PrinterLink {
  Stream<BambuState> get states;
  Stream<BambuConnStatus> get status;
  Future<void> connect();
  void dispose();

  Future<bool> pause();
  Future<bool> resume();
  Future<bool> stop();
  Future<bool> setSpeed(int level);

  /// 调速 + 固件回执（accepted: true/false，null = 没回执）。
  Future<({bool sent, bool? accepted, String? reason})> setSpeedChecked(
      int level);
  Future<bool> setLight(bool on);
  Future<bool> refresh();

  /// Prints a 3mf already on the printer (一键换盘 uploads it first).
  /// [ams] routes the print through a live AMS slot (换盘 PLA 匹配).
  Future<bool> printProjectFile({
    required String url,
    String param,
    String md5,
    String name,
    ({int amsId, int slot})? ams,
  });
}

class MqttPrinterLink implements PrinterLink {
  MqttPrinterLink(this.profile, {String? signingKeyPem}) {
    _client = BambuMqttClient(
        config: profile.toMqttConfig(),
        log: LogBuffer.instance.add,
        signingKeyPem: signingKeyPem);
  }

  final PrinterProfile profile;
  late final BambuMqttClient _client;

  @override
  Stream<BambuState> get states => _client.states;

  @override
  Stream<BambuConnStatus> get status => _client.status;

  @override
  Future<void> connect() => _client.connect();

  @override
  void dispose() => _client.dispose();

  @override
  Future<bool> pause() => _client.pausePrint();

  @override
  Future<bool> resume() => _client.resumePrint();

  @override
  Future<bool> stop() => _client.stopPrint();

  @override
  Future<bool> setSpeed(int level) => _client.setSpeedLevel(level);

  @override
  Future<({bool sent, bool? accepted, String? reason})> setSpeedChecked(
          int level) =>
      _client.setSpeedChecked(level);

  @override
  Future<bool> setLight(bool on) => _client.setChamberLight(on);

  @override
  Future<bool> refresh() => _client.requestPushall(reason: 'manual');

  @override
  Future<bool> printProjectFile({
    required String url,
    String param = 'Metadata/plate_1.gcode',
    String md5 = '',
    String name = 'BambuDeck',
    ({int amsId, int slot})? ams,
  }) =>
      _client.printProjectFile(
          url: url,
          param: param,
          md5: md5,
          name: name,
          amsSlot: ams?.slot,
          amsId: ams?.amsId ?? 0);
}

/// 调速 + 等打印机确认（App 的 ConnectionNotifier 与独立网页服务共用）。
///
/// A1/P1 的 `print_speed` 常常只在**打印中**才真正生效，而且固件不一定
/// 主动回报 `spd_lvl`：publish 成功 ≠ 档位变了。旧写法据此返回 true，网页/App
/// 就表现成「点了运动还显示标准」(2026-10-25)。这里在 publish 之后看一眼
/// 状态，没变就发一次 pushall 逼打印机交出完整状态，再没变就如实报告
/// 没确认，让调用方提示用户，而不是假装成功。
///
/// [state] 返回当前状态（ConnectionNotifier 读自己的 _current，独立服务读
/// 自己的连接表）。
Future<({bool sent, bool confirmed, String? note})> confirmSpeedLevel(
  PrinterLink link,
  int level, {
  required BambuState? Function() state,
}) async {
  final r = await link.setSpeedChecked(level);
  if (!r.sent) return (sent: false, confirmed: false, note: null);
  // 固件明确拒收(84033543 开发者模式没开 / FAILED): 不用再等状态。
  if (r.accepted == false) {
    LogBuffer.instance.add('[速度] 打印机拒收 $level 档: ${r.reason ?? ''}');
    return (
      sent: true,
      confirmed: false,
      note: '打印机拒收了调速${r.reason == null ? '' : '：${r.reason}'}',
    );
  }
  // 回执 success 也只说明命令被执行了, 状态里有没有新档位要自己看:
  // 没变化就发一次 pushall 逼打印机交完整状态, 再没有就如实说没确认。
  if (await awaitSpeedLevel(level, state,
      within: const Duration(milliseconds: 1200))) {
    return (sent: true, confirmed: true, note: null);
  }
  await link.refresh();
  final confirmed =
      await awaitSpeedLevel(level, state, within: const Duration(seconds: 2));
  if (!confirmed) {
    LogBuffer.instance.add('[速度] 打印机没有回报 $level 档'
        '(当前 ${state()?.speedLevel ?? 0} 档) —— '
        'Bambu 固件通常只在打印中接受调速');
  }
  return (
    sent: true,
    confirmed: confirmed,
    note: confirmed ? null : '速度已发给打印机，但打印机没有确认切档（不在打印中时通常不生效）',
  );
}

/// 等打印机状态帧里的 spd_lvl 变成 [level]。
///
/// 走 Bambu Connect 调速时用它做权威确认: Connect 界面上那个百分比是
/// 云端绕一圈回来的(实测 2~20 秒)，局域网状态帧是打印机直报的(秒级)。
Future<bool> awaitSpeedLevel(
  int level,
  BambuState? Function() state, {
  Duration within = const Duration(seconds: 10),
}) async {
  final end = DateTime.now().add(within);
  while (DateTime.now().isBefore(end)) {
    if (state()?.speedLevel == level) return true;
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }
  return state()?.speedLevel == level;
}
