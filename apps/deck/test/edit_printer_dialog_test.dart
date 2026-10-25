import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:deck/data/printer_profile.dart';
import 'package:deck/data/providers.dart';
import 'package:deck/features/printers/edit_printer_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Store implements PrinterStore {
  _Store(this.printers);
  List<PrinterProfile> printers;

  @override
  Future<List<PrinterProfile>> load() async => printers;

  @override
  Future<void> save(List<PrinterProfile> printers) async {
    this.printers = printers;
  }
}

PrinterProfile _profile() => PrinterProfile(
      id: 'p1',
      name: '123',
      mode: PrinterMode.lan,
      serial: '03919D4A0803769',
      ip: '192.168.100.110',
      accessCode: '12345678',
    );

void main() {
  testWidgets('编辑打印机对话框渲染出名称/IP/访问码/序列号', (tester) async {
    final profile = _profile();
    final store = _Store([profile]);
    await tester.pumpWidget(ProviderScope(
      overrides: [storeProvider.overrideWithValue(store)],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => showEditPrinterDialog(context, ref, profile),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('编辑打印机 · 123'), findsOneWidget);
    for (final label in ['名称', 'IP / 主机', '访问码', '序列号']) {
      expect(find.text(label), findsOneWidget, reason: '缺少字段 $label');
    }
    // 值预填: IP 字段带着当前配置 (hintText 也是同一个串, 所以按 controller 找)。
    final ipField = tester
        .widgetList<TextField>(find.byType(TextField))
        .firstWhere((f) => f.controller?.text == '192.168.100.110');
    expect(ipField.decoration?.labelText, 'IP / 主机');
    expect(find.text('保存'), findsOneWidget);
    expect(find.text('删除打印机'), findsOneWidget);
    // 删除在左, 取消/保存在右 (旧实现用 Spacer 撑开, 直接把对话框搞崩)。
    final dialog = tester.getRect(find.byType(AlertDialog));
    expect(tester.getCenter(find.text('删除打印机')).dx,
        lessThan(dialog.center.dx));
    expect(tester.getCenter(find.text('保存')).dx, greaterThan(dialog.center.dx));
  });
}
