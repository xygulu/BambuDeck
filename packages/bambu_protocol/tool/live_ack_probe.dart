// 真机验证：控制命令的回执是否被正确捕获。
//
// 这个脚本存在的意义就是复现「按钮点了没反应」并在补丁后给出确切原因：
// 云模式打印机会回 84033543（无 result 字段），旧实现在这里静默返回 true。
import 'dart:async';

import 'package:bambu_protocol/bambu_protocol.dart';

Future<void> probe(String name, String ip, String code, String sn) async {
  print('=== $name ($ip)');
  final client = BambuMqttClient(
    config: BambuMqttConfig.lan(ip: ip, serial: sn, accessCode: code),
    log: (l) => print('   $l'),
  );
  final connected = Completer<void>();
  final sub = client.status.listen((s) {
    if (s == BambuConnStatus.connected && !connected.isCompleted) {
      connected.complete();
    }
  });
  await client.connect();
  try {
    await connected.future.timeout(const Duration(seconds: 25));
  } on TimeoutException {
    print('   !! 连接超时');
    client.dispose();
    await sub.cancel();
    return;
  }
  await Future<void>.delayed(const Duration(seconds: 2));

  final ok = await client.pausePrint();
  print('   >>> pausePrint() 返回 $ok  '
      '(${ok ? '打印机接受了' : '打印机拒收/未连接'})');

  client.dispose();
  await sub.cancel();
  print('');
}

Future<void> main(List<String> args) async {
  // 用法: dart run tool/live_ack_probe.dart <名称> <ip> <访问码> <序列号>
  // 访问码/序列号来自打印机或云端注册表 —— 公开仓库,不能写死进代码。
  if (args.length != 4) {
    print('用法: dart run tool/live_ack_probe.dart <名称> <ip> <访问码> <序列号>');
    return;
  }
  await probe(args[0], args[1], args[2], args[3]);
}
