// 真机验证：print_speed 到底有没有被固件接受、固件会不会回报 spd_lvl。
//
// 「点了运动还显示标准」有两种完全不同的原因，这个脚本一次分清：
//   1) 命令被静默丢弃(没有回执 / err_code 被吞) —— 打印机会话里会看到
//      publish OK 但 spd_lvl 一直不变；
//   2) 命令生效了，但固件不在状态帧里回报 spd_lvl —— 打印机会自己变快，
//      我们这边永远是旧值。
//
// 用法: dart run tool/speed_probe.dart <名称> <ip> <访问码> <序列号> [--force]
// 打印中默认拒绝发命令(会改当前这一件的速度)，确需测试时加 --force。
import 'dart:async';
import 'dart:io';

import 'package:bambu_protocol/bambu_protocol.dart';

/// stderr 不带 io 缓冲, 管道里也能边跑边看 (print -> stdout 在管道里会被
/// 攒到进程退出才吐出来, 卡住时一行都看不到)。
void say(String line) => stderr.writeln(line);

const _names = {1: '静音', 2: '标准', 3: '运动', 4: '疯狂'};
String _lvl(int v) => v == 0 ? '未知(0)' : '$v ${_names[v] ?? '?'}';

Future<void> probe(String name, String ip, String code, String sn,
    {bool force = false}) async {
  say('=== $name ($ip)');
  final client = BambuMqttClient(
    config: BambuMqttConfig.lan(ip: ip, serial: sn, accessCode: code),
    log: (l) => say('   $l'),
  );
  final connected = Completer<void>();
  final statusSub = client.status.listen((s) {
    if (s == BambuConnStatus.connected && !connected.isCompleted) {
      connected.complete();
    }
  });

  BambuState? last;
  final changes = <(DateTime, int)>[];
  final stateSub = client.states.listen((s) {
    final prev = last;
    last = s;
    if (prev == null || prev.speedLevel != s.speedLevel) {
      changes.add((DateTime.now(), s.speedLevel));
      say('   [状态] spd_lvl=${_lvl(s.speedLevel)} '
          'gcode=${s.rawGcodeState} 进度=${s.progress}%');
    }
  });

  await client.connect();
  try {
    await connected.future.timeout(const Duration(seconds: 25));
  } on TimeoutException {
    say('   !! 连接超时');
    await stateSub.cancel();
    await statusSub.cancel();
    client.dispose();
    return;
  }
  // 等第一帧完整状态 (spd_lvl 只在完整/差分帧里出现)。
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while ((last == null || last!.speedLevel == 0) && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  final before = last;
  if (before == null) {
    say('   !! 10s 内没收到任何状态帧');
    await stateSub.cancel();
    await statusSub.cancel();
    client.dispose();
    return;
  }

  say('   当前: 速度=${_lvl(before.speedLevel)} '
      '状态=${before.rawGcodeState} 打印中=${before.printing} '
      '任务=${before.subtaskName}');
  if (last!.printing && !force) {
    say('   !! 打印机正在打印，跳过发命令 (会改这一件的速度)。'
        '确需测试请加 --force');
    await stateSub.cancel();
    await statusSub.cancel();
    client.dispose();
    return;
  }

  final target = before.speedLevel == 3 ? 4 : 3;
  say('   >>> 发送 print_speed=${_lvl(target)}');
  final t0 = DateTime.now();
  final r = await client.setSpeedChecked(target);
  say('   >>> setSpeedChecked() => sent=${r.sent} accepted=${r.accepted}'
      '${r.reason == null ? '' : ' reason=${r.reason}'}');
  if (r.accepted == false) {
    say('   !! 固件明确拒收了这条命令，上面 [回执] 那行就是原因');
  }

  // 8 秒观察窗: 固件回执会打在上面 [回执] 那行, spd_lvl 变化打在 [状态]。
  final watch = DateTime.now().add(const Duration(seconds: 8));
  while (DateTime.now().isBefore(watch) &&
      !(last != null && last!.speedLevel == target)) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  final echoed = last?.speedLevel == target;
  say('   >>> ${DateTime.now().difference(t0).inMilliseconds} ms 后: '
      '${echoed ? '固件回报 spd_lvl=${_lvl(target)} —— 命令生效且会回报' : '固件没有回报 spd_lvl=${_lvl(target)} —— 看上面有没有 [回执] 行'}');

  // 还原原来的档位，别把打印机留在运动档。
  if (echoed && before.speedLevel > 0) {
    say('   <<< 还原 print_speed=${_lvl(before.speedLevel)}');
    await client.setSpeedLevel(before.speedLevel);
    await Future<void>.delayed(const Duration(seconds: 2));
  }

  say('   速度变化记录: ${changes.map((c) => _lvl(c.$2)).join(' -> ')}');
  await stateSub.cancel();
  await statusSub.cancel();
  client.dispose();
}

Future<void> main(List<String> args) async {
  // 公开仓库, 访问码/序列号不写死进代码 —— 和 live_ack_probe 一样从命令行给。
  final force = args.contains('--force');
  final rest = args.where((a) => a != '--force').toList();
  if (rest.length != 4) {
    say('用法: dart run tool/speed_probe.dart <名称> <ip> <访问码> <序列号> [--force]');
    return;
  }
  // 兜底: 连接/收流任何一步卡死都别让进程永远挂着。
  Timer(const Duration(seconds: 90), () {
    say('!! 90s 兜底超时, 强制退出');
    exit(3);
  });
  try {
    await probe(rest[0], rest[1], rest[2], rest[3], force: force);
  } finally {
    exit(0);
  }
}
