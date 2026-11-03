import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:deck/data/app_settings.dart';
import 'package:deck/data/camera_profile.dart';
import 'package:deck/data/hub_config.dart';
import 'package:deck/data/hub_rescue.dart';
import 'package:deck/data/printer_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  PrinterProfile p(String id,
          {String serial = '',
          String ip = '',
          String code = '',
          String token = '',
          String userId = '',
          PrinterMode mode = PrinterMode.cloud,
          String accountId = ''}) =>
      PrinterProfile(
        id: id,
        name: id,
        mode: mode,
        serial: serial,
        ip: ip,
        accessCode: code,
        token: token,
        userId: userId,
        accountId: accountId,
      );

  CameraProfile c(String id, {String url = ''}) => CameraProfile(
        id: id,
        name: id,
        sourceType: CameraSourceType.rtsp,
        url: url,
      );

  CameraProfile bambuCam(String id, {List<String> printerIds = const []}) =>
      CameraProfile(
        id: id,
        name: id,
        sourceType: CameraSourceType.bambu,
        printerIds: printerIds,
      );

  group('rescueSettings', () {
    test('local fully default + disk has values -> adopt disk wholesale', () {
      final disk = const AppSettings().copyWith(
          hubToken: 't1', visionApiKey: 'k1', visionEnabled: true);
      final out = rescueSettings(const AppSettings(), disk);
      expect(out, same(disk));
    });

    test('local default + disk default -> null', () {
      expect(rescueSettings(const AppSettings(), const AppSettings()), isNull);
    });

    test('local non-default keeps its fields, fills only empty secrets', () {
      final local = const AppSettings().copyWith(
          visionEnabled: true, visionApiKey: 'mine', cameraMuted: true);
      final disk = const AppSettings()
          .copyWith(hubToken: 't1', visionApiKey: 'disk', visionEnabled: true);
      final out = rescueSettings(local, disk)!;
      expect(out.visionApiKey, 'mine'); // 本地非空最大
      expect(out.visionEnabled, isTrue); // 本地字段不动
      expect(out.cameraMuted, isTrue);
      expect(out.hubToken, 't1'); // 本地空 → 采纳
    });

    test('local non-default + nothing to fill -> null', () {
      final local = const AppSettings().copyWith(hubToken: 'x');
      final disk = const AppSettings().copyWith(visionEnabled: true);
      expect(rescueSettings(local, disk), isNull);
    });
  });

  group('rescuePrinters', () {
    test('fills missing ip/accessCode and upgrades cloud to lan', () {
      final local = p('a', serial: 'SN-A', code: 'c');
      final disk = [p('a', serial: 'SN-A', ip: '192.168.1.5', code: 'c')];
      final out = rescuePrinters([local], disk)!;
      expect(out[0].ip, '192.168.1.5');
      expect(out[0].mode, PrinterMode.lan);
    });

    test('local non-empty fields win (disk must not downgrade)', () {
      final local = p('a', serial: 'SN-A', ip: '10.0.0.9', code: 'mine');
      final disk = [p('a', serial: 'SN-A', ip: '192.168.1.5', code: 'c')];
      final out = rescuePrinters([local], disk);
      expect(out, isNull); // 没有可补的 → 无变化
    });

    test('adopts empty token/userId/accountId from disk', () {
      final local = p('a', serial: 'SN-A', code: 'c');
      final disk = [
        p('a', serial: 'SN-A', token: 'tk', userId: 'u1', accountId: 'acc1')
      ];
      final out = rescuePrinters([local], disk)!;
      expect(out[0].token, 'tk');
      expect(out[0].userId, 'u1');
      expect(out[0].accountId, 'acc1');
    });

    test('appends disk-only printers', () {
      final local = [p('a', serial: 'SN-A', ip: '1.1.1.1', code: 'c')];
      final disk = [
        p('a', serial: 'SN-A', ip: '1.1.1.1', code: 'c'),
        p('b', serial: 'SN-B', ip: '2.2.2.2', code: 'c2'),
      ];
      final out = rescuePrinters(local, disk)!;
      expect(out, hasLength(2));
      expect(out[1].serial, 'SN-B');
    });

    test('no disk match and no extras -> null', () {
      expect(rescuePrinters([p('a', serial: 'SN-A')], <PrinterProfile>[]),
          isNull);
    });
  });

  group('rescueCameras', () {
    test('union by id, local wins, disk-only appended', () {
      final local = [c('c1', url: 'rtsp://mine')];
      final disk = [c('c1', url: 'rtsp://disk'), c('c2', url: 'rtsp://x')];
      final out = rescueCameras(local, disk)!;
      expect(out, hasLength(2));
      expect(out[0].url, 'rtsp://mine');
      expect(out[1].id, 'c2');
    });

    test('no extras -> null', () {
      expect(rescueCameras([c('c1')], [c('c1')]), isNull);
    });
  });

  group('mergeExportPrinters', () {
    test('App 清单为空时不清空盘上的手工打印机', () {
      final disk = [
        p('a', serial: 'SN-A', ip: '1.1.1.1', code: 'c', mode: PrinterMode.lan),
        p('b', serial: 'SN-B', ip: '2.2.2.2', code: 'c2', mode: PrinterMode.lan),
      ];
      final out = mergeExportPrinters(app: const [], disk: disk);
      expect(out, hasLength(2));
      expect(out.map((e) => e.serial), unorderedEquals(['SN-A', 'SN-B']));
    });

    test('App 少一台但没墓碑 → 盘上那台保留', () {
      final disk = [
        p('a', serial: 'SN-A', ip: '1.1.1.1', code: 'c', mode: PrinterMode.lan),
        p('b', serial: 'SN-B', ip: '2.2.2.2', code: 'c2', mode: PrinterMode.lan),
      ];
      final out = mergeExportPrinters(app: [disk.first], disk: disk);
      expect(out, hasLength(2));
    });

    test('用户显式删过 → 允许消失', () {
      final disk = [
        p('a', serial: 'SN-A', ip: '1.1.1.1', code: 'c', mode: PrinterMode.lan),
        p('b', serial: 'SN-B', ip: '2.2.2.2', code: 'c2', mode: PrinterMode.lan),
      ];
      final out = mergeExportPrinters(
          app: [disk.first], disk: disk, tombstoned: {'s:SN-B'});
      expect(out, hasLength(1));
      expect(out.single.serial, 'SN-A');
    });

    test('App 的编辑优先(改名/填访问码要生效)', () {
      final disk = [
        p('a', serial: 'SN-A', ip: '1.1.1.1', code: 'c', mode: PrinterMode.lan),
      ];
      final edited = p('a', serial: 'SN-A', ip: '1.1.1.1', code: 'new',
          mode: PrinterMode.lan);
      final out = mergeExportPrinters(app: [edited], disk: disk);
      expect(out, hasLength(1));
      expect(out.single.accessCode, 'new');
    });

    test('云账号归属从盘上带回 App 条目', () {
      final disk = [
        p('a', serial: 'SN-A', ip: '1.1.1.1', code: 'c', mode: PrinterMode.lan)
            .copyWith(accountId: 'acc1'),
      ];
      final app = [p('a', serial: 'SN-A', ip: '1.1.1.1', code: 'c',
          mode: PrinterMode.lan)];
      final out = mergeExportPrinters(app: app, disk: disk);
      expect(out.single.accountId, 'acc1');
    });

    test('无 serial 的条目按 id 匹配', () {
      final disk = [p('x1', ip: '1.1.1.1', code: 'c', mode: PrinterMode.lan)];
      final out = mergeExportPrinters(app: const [], disk: disk);
      expect(out, hasLength(1));
      final out2 = mergeExportPrinters(
          app: const [], disk: disk, tombstoned: {'i:x1'});
      expect(out2, isEmpty);
    });
  });

  group('ensureBuiltinCameras', () {
    test('creates a bound built-in camera for an eligible printer', () {
      final printers = [
        p('a', serial: 'SN-A', ip: '1.1.1.1', code: 'c',
            mode: PrinterMode.lan),
      ];
      final out = ensureBuiltinCameras(printers, const [])!;
      expect(out, hasLength(1));
      expect(out.first.sourceType, CameraSourceType.bambu);
      expect(out.first.printerIds, ['a']);
      expect(out.first.id, 'bambu_SN-A');
    });

    test('skips printers without LAN credentials', () {
      final printers = [
        p('a', serial: 'SN-A'), // cloud,无码无 ip
        p('b', serial: 'SN-B', ip: '1.1.1.1'), // 有 ip 无码
        p('c', serial: 'SN-C', code: 'c'), // cloud 模式且无 ip(码还不能用)
      ];
      expect(ensureBuiltinCameras(printers, const []), isNull);
    });

    test('accepts LAN printer whose ip has not been discovered yet', () {
      final printers = [p('a', serial: 'SN-A', code: 'c')];
      final out = ensureBuiltinCameras(
          printers.map((e) => e.copyWith(mode: PrinterMode.lan)).toList(),
          const [])!;
      expect(out, hasLength(1));
      expect(out.first.id, 'bambu_SN-A');
    });

    test('skips printers already bound to a built-in camera', () {
      final printers = [
        p('a', serial: 'SN-A', ip: '1.1.1.1', code: 'c',
            mode: PrinterMode.lan),
      ];
      final cameras = [bambuCam('x1', printerIds: ['a'])];
      expect(ensureBuiltinCameras(printers, cameras), isNull);
    });

    test('dedupe by deterministic id (binding moved elsewhere)', () {
      final printers = [
        p('a', serial: 'SN-A', ip: '1.1.1.1', code: 'c',
            mode: PrinterMode.lan),
      ];
      final cameras = [bambuCam('bambu_SN-A')];
      expect(ensureBuiltinCameras(printers, cameras), isNull);
    });

    test('fills only the unbound eligible ones', () {
      final printers = [
        p('a', serial: 'SN-A', ip: '1.1.1.1', code: 'c', mode: PrinterMode.lan),
        p('b', serial: 'SN-B', ip: '2.2.2.2', code: 'c', mode: PrinterMode.lan),
      ];
      final cameras = [bambuCam('x1', printerIds: ['a'])];
      final out = ensureBuiltinCameras(printers, cameras)!;
      expect(out, hasLength(2));
      expect(out.last.printerIds, ['b']);
    });
  });

  group('rescueHubData', () {
    test('combined rescue fills all three segments', () {
      final r = rescueHubData(
        settings: const AppSettings(),
        printers: [p('a', serial: 'SN-A', code: 'c')],
        cameras: const [],
        disk: HubConfig(
          settings: const AppSettings().copyWith(hubToken: 't'),
          printers: [p('a', serial: 'SN-A', code: 'c', ip: '3.3.3.3')],
          cameras: [c('c1')],
        ),
      );
      expect(r.settings!.hubToken, 't');
      expect(r.printers![0].ip, '3.3.3.3');
      expect(r.cameras, hasLength(1));
    });

    test('healthy local + default disk -> nothing to do', () {
      final r = rescueHubData(
        settings: const AppSettings().copyWith(hubToken: 't'),
        printers: [p('a', serial: 'SN-A', ip: '1.1.1.1', code: 'c')],
        cameras: [c('c1')],
        disk: const HubConfig(),
      );
      expect(r.settings, isNull);
      expect(r.printers, isNull);
      expect(r.cameras, isNull);
    });
  });
}
