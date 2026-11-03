import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deck/data/cloud_add_plan.dart';
import 'package:deck/data/printer_profile.dart';

CloudDevice dev(String serial, {String accessCode = ''}) => CloudDevice(
      devId: serial,
      devName: 'Bambu $serial',
      modelName: 'A1',
      productName: 'A1',
      online: true,
      accessCode: accessCode,
    );

PrinterProfile local(String serial,
        {String accessCode = '', String id = ''}) =>
    PrinterProfile(
      id: id.isEmpty ? 'p_$serial' : id,
      name: '本机 $serial',
      mode: PrinterMode.lan,
      serial: serial,
      ip: '192.168.1.9',
      accessCode: accessCode,
    );

void main() {
  test('本地没有的设备全部进入新增', () {
    final plan = planCloudAdd(
      existing: const [],
      devices: [dev('A'), dev('B'), dev('C')],
      token: 'tok',
      userId: 'u1',
    );
    expect(plan.toAdd.map((d) => d.devId), ['A', 'B', 'C']);
    expect(plan.patches, isEmpty);
    expect(plan.skipped, 0);
  });

  test('已有且缺访问码 → 就地补码,不重复添加', () {
    final plan = planCloudAdd(
      existing: [local('A'), local('B'), local('C')],
      devices: [dev('A', accessCode: '1111'), dev('B', accessCode: '2222')],
      token: 'tok',
      userId: 'u1',
    );
    expect(plan.toAdd, isEmpty);
    expect(plan.patches.length, 2);
    final a = plan.patches['p_A']!;
    expect(a.accessCode, '1111');
    expect(a.token, 'tok');
    expect(a.userId, 'u1');
    // 补码不能丢掉原有身份信息(IP/名字/ID)。
    expect(a.ip, '192.168.1.9');
    expect(a.name, '本机 A');
    expect(a.id, 'p_A');
    expect(plan.patches['p_B']!.accessCode, '2222');
    expect(plan.skipped, 0);
  });

  test('已有且访问码一致 → 跳过;本地有码云端没码 → 不覆盖', () {
    final plan = planCloudAdd(
      existing: [local('A', accessCode: '1111'), local('B', accessCode: '9')],
      devices: [dev('A', accessCode: '1111'), dev('B')],
      token: 'tok',
      userId: 'u1',
    );
    expect(plan.toAdd, isEmpty);
    expect(plan.patches, isEmpty);
    expect(plan.skipped, 2);
    expect(plan.isNoop, isTrue);
  });

  test('访问码与云端不同 → 以云端为准补正(换机/重置后码变了)', () {
    final plan = planCloudAdd(
      existing: [local('A', accessCode: 'old')],
      devices: [dev('A', accessCode: 'new')],
      token: 'tok',
      userId: 'u1',
    );
    expect(plan.patches['p_A']!.accessCode, 'new');
    expect(plan.skipped, 0);
  });

  test('混合批次:新增+补码+跳过一次算清', () {
    final plan = planCloudAdd(
      existing: [local('A'), local('B', accessCode: '2222')],
      devices: [
        dev('A', accessCode: '1111'),
        dev('B', accessCode: '2222'),
        dev('C', accessCode: '3333'),
      ],
      token: 'tok',
      userId: 'u1',
    );
    expect(plan.toAdd.map((d) => d.devId), ['C']);
    expect(plan.patches.keys, ['p_A']);
    expect(plan.skipped, 1);
    expect(plan.isNoop, isFalse);
  });

  test('本地无序列号的条目按 id 匹配不上 → 不会误补码', () {
    final plan = planCloudAdd(
      existing: [
        PrinterProfile(
            id: 'p_A',
            name: '无名',
            mode: PrinterMode.lan,
            serial: '',
            ip: '1.2.3.4'),
      ],
      devices: [dev('A', accessCode: '1111')],
      token: 'tok',
      userId: 'u1',
    );
    expect(plan.patches, isEmpty);
    expect(plan.toAdd.map((d) => d.devId), ['A']);
  });
}
