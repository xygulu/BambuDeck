import 'package:deck/data/ptz_client.dart';
import 'package:deck/ui/ptz_calibrate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePtz implements PtzClient {
  final moves = <(double, double)>[];
  int stops = 0;

  @override
  bool get available => true;

  @override
  Future<bool> probe() async => true;

  @override
  Future<void> move({double pan = 0, double tilt = 0, double zoom = 0}) async {
    moves.add((pan, tilt));
  }

  @override
  Future<void> stop() async => stops++;

  @override
  void dispose() {}
}

void main() {
  Future<String?> open(WidgetTester tester, _FakePtz client,
      {String current = ''}) async {
    String? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await showPtzCalibrateDialog(ctx,
                    client: client, current: current);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('records the four observations in UDLR order', (tester) async {
    final client = _FakePtz();
    String? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await showPtzCalibrateDialog(ctx,
                    client: client, current: '');
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Row order U,D,L,R; each row offers U,D,L,R chips.
    // 上键 -> 画面往左, 下键 -> 画面往右, 左键 -> 画面往上, 右键 -> 画面往下.
    await tester.tap(find.text('← 左').at(0));
    await tester.tap(find.text('→ 右').at(1));
    await tester.tap(find.text('↑ 上').at(2));
    await tester.tap(find.text('↓ 下').at(3));
    await tester.pump();

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(result, 'LRUD');
  });

  testWidgets('refuses a map that points two keys the same way',
      (tester) async {
    final client = _FakePtz();
    await open(tester, client);

    await tester.tap(find.text('← 左').at(0));
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    // Still open: 上键 and 下键 cannot both be 左.
    expect(find.textContaining('同一个方向'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('hold test sends the raw command while held', (tester) async {
    final client = _FakePtz();
    await open(tester, client);

    final hold = find.text('按住测试').at(0);
    final gesture = await tester.startGesture(tester.getCenter(hold));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(client.moves, isNotEmpty);
    // 上键 first: pure tilt up at the pad's speed.
    expect(client.moves.first.$1, 0);
    expect(client.moves.first.$2, greaterThan(0));
    expect(client.stops, greaterThan(0));
  });

  testWidgets('cancel leaves the profile untouched', (tester) async {
    final client = _FakePtz();
    String? result = 'sentinel';
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await showPtzCalibrateDialog(ctx,
                    client: client, current: 'RLUD');
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}
