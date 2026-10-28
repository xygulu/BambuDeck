import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:deck/data/hub_service.dart';
import 'package:deck/data/printer_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // `print.fun` 的 bit29: 清零 = 开发者模式开(可明文直发), 置位 = 关(需签名,
  // 固件会拦未签名的 print 帧 84033543)。
  BambuState stateWithDevMode({required bool off}) => BambuState(
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
        fun: off ? (1 << 29) : 0,
      );

  PrinterProfile lan({
    String ip = '192.168.100.110',
    PrinterMode mode = PrinterMode.lan,
  }) =>
      PrinterProfile(
        id: 'p1',
        name: 'A1',
        mode: mode,
        serial: '03919D4A0803769',
        ip: ip,
        accessCode: '12345678',
      );

  group('plateSwapRoute', () {
    test('LAN + 开发者模式开 → 纯协议(不需要 Connect)', () {
      expect(
        HubService.plateSwapRoute(lan(), stateWithDevMode(off: false),
            hasLink: true),
        PlateSwapRoute.lanFtps,
      );
    });

    test('开发者模式关 → Connect(固件会拦 LAN 直发)', () {
      expect(
        HubService.plateSwapRoute(lan(), stateWithDevMode(off: true),
            hasLink: true),
        PlateSwapRoute.connect,
      );
    });

    test('还没连上(状态未知) → Connect, 不冒险直发', () {
      expect(
        HubService.plateSwapRoute(lan(), null, hasLink: true),
        PlateSwapRoute.connect,
      );
    });

    test('固件不报 fun(A1 老固件) → 先试纯协议, 没接上再退 Connect', () {
      final state = BambuState(updatedAt: DateTime.fromMillisecondsSinceEpoch(0));
      expect(state.developerModeOff, isNull);
      expect(
        HubService.plateSwapRoute(lan(), state, hasLink: true),
        PlateSwapRoute.tryLanThenConnect,
      );
    });

    test('云模式 → Connect(没有可达的 FTP 端点)', () {
      expect(
        HubService.plateSwapRoute(lan(mode: PrinterMode.cloud),
            stateWithDevMode(off: false), hasLink: true),
        PlateSwapRoute.connect,
      );
    });

    test('LAN 但没有 IP → Connect', () {
      expect(
        HubService.plateSwapRoute(lan(ip: ''), stateWithDevMode(off: false),
            hasLink: true),
        PlateSwapRoute.connect,
      );
    });

    test('没有活连接 → Connect', () {
      expect(
        HubService.plateSwapRoute(lan(), stateWithDevMode(off: false),
            hasLink: false),
        PlateSwapRoute.connect,
      );
    });
  });
}
