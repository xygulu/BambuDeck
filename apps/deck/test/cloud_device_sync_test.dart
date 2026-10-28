import 'dart:convert';

import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deck/data/cloud_device_sync.dart';
import 'package:deck/data/hub_config.dart';
import 'package:deck/data/printer_profile.dart';

CloudDevice dev(String serial,
        {String name = '',
        String model = '',
        String product = '',
        bool online = true,
        String accessCode = ''}) =>
    CloudDevice(
      devId: serial,
      devName: name,
      modelName: model,
      productName: product,
      online: online,
      accessCode: accessCode,
    );

const account = CloudAccount(
  id: 'a1',
  region: CloudRegion.cn,
  account: 'user@example.com',
  accessToken: 'tok',
  userId: 'u_42',
  createdAt: 1000,
);

void main() {
  test('云端新设备入列：有访问码走 LAN，没有走云模式', () {
    final (printers, changed) = mergeCloudDevices(
      printers: const [],
      account: account,
      devices: [
        dev('SER1', name: '车间 A1', product: 'A1', accessCode: '12345678'),
        dev('SER2', name: '云端 P1S', product: 'P1S'),
      ],
    );
    expect(changed, isTrue);
    expect(printers, hasLength(2));
    final lan = printers.firstWhere((p) => p.serial == 'SER1');
    expect(lan.mode, PrinterMode.lan);
    expect(lan.accessCode, '12345678');
    expect(lan.accountId, 'a1');
    expect(lan.name, '车间 A1');
    final cloud = printers.firstWhere((p) => p.serial == 'SER2');
    expect(cloud.mode, PrinterMode.cloud);
    expect(cloud.token, 'tok');
    expect(cloud.userId, 'u_42');
    expect(cloud.accessCode, isEmpty);
  });

  test('两边都有：云端权威字段更新，本地偏好保留', () {
    final existing = PrinterProfile(
      id: 'manual-1',
      name: '旧名字',
      mode: PrinterMode.lan,
      serial: 'SER1',
      ip: '192.168.1.5',
      accessCode: 'old',
      model: 'A1 mini',
      builtinCam: BuiltinCamSetting.off,
      autoPlateSwap: true,
      accountId: 'a1',
      createdAt: 42,
    );
    final (printers, changed) = mergeCloudDevices(
      printers: [existing],
      account: account,
      devices: [dev('SER1', name: '新名字', product: 'A1', accessCode: 'new')],
    );
    expect(changed, isTrue);
    final p = printers.single;
    expect(p.name, '新名字');
    expect(p.accessCode, 'new');
    expect(p.model, 'A1');
    expect(p.ip, '192.168.1.5'); // 本地偏好不动
    expect(p.builtinCam, BuiltinCamSetting.off);
    expect(p.autoPlateSwap, isTrue);
    expect(p.id, 'manual-1'); // 不换 id，原有连接状态不失效
    expect(p.createdAt, 42);
  });

  test('解绑下架：只删本账号的，他账号与手工条目保留', () {
    final mine = PrinterProfile(
      id: 'x1',
      name: '我的',
      mode: PrinterMode.lan,
      serial: 'MINE',
      accountId: 'a1',
    );
    final other = PrinterProfile(
      id: 'x2',
      name: '别人账号的',
      mode: PrinterMode.lan,
      serial: 'OTHER',
      accountId: 'a2',
    );
    final manual = PrinterProfile(
      id: 'x3',
      name: '手工',
      mode: PrinterMode.lan,
      serial: 'MANUAL',
    );
    final (printers, changed) = mergeCloudDevices(
      printers: [mine, other, manual],
      account: account,
      devices: const [],
    );
    expect(changed, isTrue);
    expect(printers.map((p) => p.serial), unorderedEquals(['OTHER', 'MANUAL']));
  });

  test('手工条目 serial 撞上云端 → 升级归属，字段照常更新', () {
    final manual = PrinterProfile(
      id: 'm1',
      name: '手填的',
      mode: PrinterMode.lan,
      serial: 'SER1',
      ip: '10.0.0.2',
      accessCode: 'old',
    );
    final (printers, changed) = mergeCloudDevices(
      printers: [manual],
      account: account,
      devices: [dev('SER1', name: '云名字', product: 'A1', accessCode: 'new')],
    );
    expect(changed, isTrue);
    final p = printers.single;
    expect(p.accountId, 'a1');
    expect(p.id, 'm1');
    expect(p.name, '云名字');
    expect(p.accessCode, 'new');
    expect(p.ip, '10.0.0.2');
  });

  test('云端与本地完全一致 → 无变化', () {
    final existing = PrinterProfile(
      id: 'ca1-SER1',
      name: '车间 A1',
      mode: PrinterMode.lan,
      serial: 'SER1',
      accessCode: '12345678',
      model: 'A1',
      accountId: 'a1',
      createdAt: 5,
    );
    final (printers, changed) = mergeCloudDevices(
      printers: [existing],
      account: account,
      devices: [
        dev('SER1', name: '车间 A1', product: 'A1', accessCode: '12345678')
      ],
    );
    expect(changed, isFalse);
    expect(printers.single.toJson(), existing.toJson());
  });

  test('他账号的同 serial 打印机不被本账号 bind 碰', () {
    final otherAccountPrinter = PrinterProfile(
      id: 'x2',
      name: '别人的同名机',
      mode: PrinterMode.lan,
      serial: 'SER1',
      accountId: 'a2',
    );
    final (printers, changed) = mergeCloudDevices(
      printers: [otherAccountPrinter],
      account: account,
      devices: [dev('SER1', name: '新名', product: 'A1', accessCode: 'c')],
    );
    expect(changed, isFalse);
    expect(printers.single.name, '别人的同名机');
    expect(printers.single.accountId, 'a2');
  });

  test('HubConfig 序列化往返保留 accounts 段；旧文件无该段不炸', () {
    final restored = HubConfig.fromJson(<String, dynamic>{});
    expect(restored.accounts, isEmpty);

    final config = const HubConfig(accounts: [account]);
    final back = HubConfig.fromJson(
        jsonDecode(jsonEncode(config.toJson())) as Map<String, dynamic>);
    expect(back.accounts, hasLength(1));
    final a = back.accounts.single;
    expect(a.id, 'a1');
    expect(a.region, CloudRegion.cn);
    expect(a.account, 'user@example.com');
    expect(a.accessToken, 'tok');
    expect(a.userId, 'u_42');
    expect(a.suspended, isFalse);
    expect(a.createdAt, 1000);
  });
}
