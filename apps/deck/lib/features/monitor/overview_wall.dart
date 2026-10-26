import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/app_settings.dart';
import '../../data/camera_profile.dart';
import '../../data/camera_providers.dart';
import '../../data/printer_profile.dart';
import '../../data/providers.dart';
import '../../data/settings_providers.dart';
import '../../ui/camera_tile.dart';
import '../../ui/visible_tile.dart';
import '../../ui/widgets.dart';
import 'monitor_page.dart' show MonitorPrinterCard;

/// 最佳网格列数: 让每个格子的宽高比最接近 16:9, n 个格子无论多少都铺满
/// 一屏 (缩小时自动排布)。总览墙 / 摄像头页墙共用这一份算法。
int bestFitColumns(int n, double w, double h) {
  var bestCols = 1;
  var bestErr = double.infinity;
  for (var cols = 1; cols <= n; cols++) {
    final rows = (n / cols).ceil();
    final err = ((w / cols) / (h / rows) / (16 / 9) - 1).abs();
    if (err < bestErr) {
      bestErr = err;
      bestCols = cols;
    }
  }
  return bestCols;
}

/// 总览墙的一个画面源: 打印机机内画面或配置的摄像头。
class _Feed {
  const _Feed({
    required this.key,
    required this.label,
    required this.url,
    this.camera,
    this.printer,
  });

  /// 流去重键 (直接用 URL: 同一路流只进一张格)。
  final String key;
  final String label;
  final String url;

  /// 摄像头配置非空时, 码流切换 / 翻转旋转 / 云台校准跟随配置。
  final CameraProfile? camera;

  /// 绑定打印机 (机内 1:1 / RTSP 取第一个), 用于画面上的状态角标。
  final PrinterProfile? printer;
}

/// 总览墙 (2026-10-26 缩小总览需求): 所有打印机机内画面 + 所有启用的
/// 摄像头 + 没有画面的打印机状态卡, 最佳网格铺满一屏; 点画面放大,
/// 缩小 (按钮 / 捏合 / 滚轮缩到阈值以下) 自动回到总览排布。监控页两个
/// 视角共用, 摄像头页的墙复用 [bestFitColumns] 与 [FeedStatusChip]。
class OverviewWall extends ConsumerStatefulWidget {
  const OverviewWall({
    super.key,
    required this.frameSlot,
    this.onSelectPrinter,
    this.onZoomChanged,
  });

  /// CameraTile 的 frameSlot 前缀 (宿主各用一个, 放大态自动加 -zoom)。
  final String frameSlot;

  /// 点无画面打印机的状态卡时回调 (宿主负责跳转打印机视角)。
  final ValueChanged<String>? onSelectPrinter;

  /// 进入/离开放大态时回调, 宿主借此隐藏头部行让画面占满。
  final ValueChanged<bool>? onZoomChanged;

  @override
  ConsumerState<OverviewWall> createState() => _OverviewWallState();
}

class _OverviewWallState extends ConsumerState<OverviewWall> {
  String? _zoomedKey;
  final _transform = TransformationController();

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _exitZoom() {
    _transform.value = Matrix4.identity();
    setState(() => _zoomedKey = null);
    widget.onZoomChanged?.call(false);
  }

  @override
  Widget build(BuildContext context) {
    final settings =
        ref.watch(appSettingsProvider).valueOrNull ?? const AppSettings();
    final printers =
        ref.watch(printersProvider).valueOrNull ?? const <PrinterProfile>[];
    final cameras =
        ref.watch(camerasProvider).valueOrNull ?? const <CameraProfile>[];

    // 配置的摄像头优先 (标签/码流回调齐全), 机内合成画面补位; 按 URL 去重,
    // 同一路流 (既加了摄像头配置又开着机内策略) 只进一张格。
    final feeds = <_Feed>[];
    final seen = <String>{};
    final covered = <String>{}; // 已有画面格的打印机 id
    void addFeed(String label, String url, CameraProfile? cam,
        PrinterProfile? printer) {
      if (url.isEmpty || !seen.add(url)) return;
      feeds.add(_Feed(
          key: url, label: label, url: url, camera: cam, printer: printer));
      for (final id in cam?.printerIds ?? const <String>[]) {
        covered.add(id);
      }
      if (printer != null) covered.add(printer.id);
    }

    for (final c in cameras) {
      if (!c.enabled) continue;
      PrinterProfile? linked;
      for (final p in printers) {
        if (c.printerIds.contains(p.id)) linked = p;
      }
      if (c.sourceType == CameraSourceType.bambu && linked == null) continue;
      final url = c.sourceType == CameraSourceType.bambu
          ? (c.resolveUrl(linked) ?? '')
          : c.url;
      addFeed(c.name, url, c, linked);
    }
    for (final p in printers) {
      if (p.mode != PrinterMode.lan ||
          !p.builtinCamDefaultOn(settings.builtinCamDefault)) {
        continue;
      }
      // 与 printer_camera_section.builtinCameraUrl 同构, 搬来一份避免循环导入。
      final url = CameraProfile(
        id: 'builtin',
        name: '机内摄像头',
        sourceType: CameraSourceType.bambu,
        printerIds: [p.id],
      ).resolveUrl(p);
      addFeed('机内 · ${p.name}', url ?? '', null, p);
    }
    // 没有任何画面格的打印机以状态卡入墙, 信息不缺席。
    final feedless = [
      for (final p in printers)
        if (!covered.contains(p.id)) p,
    ];

    // 放大目标没了 (解绑/停用/地址失效) → 回总览。
    if (_zoomedKey != null && !feeds.any((f) => f.key == _zoomedKey)) {
      _zoomedKey = null;
      widget.onZoomChanged?.call(false);
    }

    final cells = <Widget>[
      for (final f in feeds) _feedCell(f),
      for (final p in feedless)
        Padding(
          padding: const EdgeInsets.all(4),
          child: MonitorPrinterCard(
            profile: p,
            selected: false,
            onTap: () => widget.onSelectPrinter?.call(p.id),
          ),
        ),
    ];
    if (cells.isEmpty) {
      return Center(
        child: Text(
          '暂无画面 - 添加打印机/摄像头后这里自动总览',
          style: TextStyle(
              fontSize: 12,
              color: DeckColors.textSecondary.withValues(alpha: 0.9)),
        ),
      );
    }

    return LayoutBuilder(builder: (context, box) {
      final zoomed =
          _zoomedKey == null ? null : feeds.firstWhere((f) => f.key == _zoomedKey);
      if (zoomed != null) return _zoomedView(zoomed);

      final n = cells.length;
      final w = box.maxWidth > 0 ? box.maxWidth : 1.0;
      final h = box.maxHeight > 0 ? box.maxHeight : 1.0;
      final cols = bestFitColumns(n, w, h);
      final rows = (n / cols).ceil();
      return Column(
        children: [
          for (var r = 0; r < rows; r++)
            Expanded(
              child: Row(
                children: [
                  for (var i = r * cols;
                      i < (r + 1) * cols && i < n;
                      i++)
                    Expanded(child: cells[i]),
                  // 补位空格, 保证末行不满时格子宽度与上方一致。
                  for (var i = n; i < (r + 1) * cols; i++)
                    const Expanded(child: SizedBox()),
                ],
              ),
            ),
        ],
      );
    });
  }

  Widget _tile(_Feed f, {required bool zoomed}) {
    final cam = f.camera;
    return VisibleOnlyTile(
      key: ValueKey('${f.key}-$zoomed'),
      streamId: f.key,
      child: CameraTile(
        streamUrl: f.url,
        label: f.label,
        expand: true,
        cameraId: f.key,
        frameSlot: zoomed
            ? '${widget.frameSlot}-zoom'
            : widget.frameSlot,
        onToggleQuality:
            cam != null && cam.sourceType == CameraSourceType.rtsp
                ? qualityToggler(ref, cam)
                : null,
        flipH: cam?.flipH ?? false,
        rotationDeg: cam?.rotationDeg ?? 0,
        ptzInvertPan: cam?.ptzInvertPan ?? false,
        ptzInvertTilt: cam?.ptzInvertTilt ?? false,
        onToggleFlip:
            cam != null && cam.sourceType == CameraSourceType.rtsp
                ? flipToggler(ref, cam)
                : null,
        onSetRotation:
            cam != null && cam.sourceType == CameraSourceType.rtsp
                ? rotationSetter(ref, cam)
                : null,
      ),
    );
  }

  Widget _feedCell(_Feed f) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          setState(() => _zoomedKey = f.key);
          widget.onZoomChanged?.call(true);
        },
        child: Stack(fit: StackFit.expand, children: [
          _tile(f, zoomed: false),
          if (f.printer != null)
            Positioned(left: 8, top: 8, child: FeedStatusChip(printer: f.printer!)),
          Positioned(
            // 左下: 右下是云台摇杆的位置。
            left: 8,
            bottom: 8,
            child: Icon(Icons.open_in_full,
                size: 13, color: Colors.white.withValues(alpha: 0.75)),
          ),
        ]),
      ),
    );
  }

  /// 放大态: InteractiveViewer 支持捏合/滚轮缩放拖移; 缩到 0.85 以下松手
  /// 即回总览 (「缩小自动排布」的手势入口), 或点左下缩小按钮。
  Widget _zoomedView(_Feed f) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Stack(fit: StackFit.expand, children: [
        InteractiveViewer(
          transformationController: _transform,
          minScale: 0.5,
          maxScale: 6.0,
          onInteractionEnd: (_) {
            if (_transform.value.getMaxScaleOnAxis() < 0.85) _exitZoom();
          },
          child: Container(color: Colors.black, child: _tile(f, zoomed: true)),
        ),
        Positioned(
          // 左下: 右下是云台摇杆。
          left: 10,
          bottom: 10,
          child: IconButton.filledTonal(
            icon: const Icon(Icons.close_fullscreen, size: 18),
            tooltip: '缩小',
            onPressed: _exitZoom,
          ),
        ),
      ]),
    );
  }
}

/// 画面格左上角的绑定打印机状态角标 (状态徽章 + 名称 + 进度), 总览墙与
/// 摄像头页墙共用。
class FeedStatusChip extends ConsumerWidget {
  const FeedStatusChip({super.key, required this.printer});

  final PrinterProfile printer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectionProvider(printer.id));
    final s = conn.state;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (s != null)
          StateBadge(state: s.gcodeState)
        else
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: switch (conn.status) {
                BambuConnStatus.connected => DeckColors.running,
                BambuConnStatus.connecting ||
                BambuConnStatus.reconnecting =>
                  DeckColors.warning,
                _ => DeckColors.textSecondary,
              },
            ),
          ),
        const SizedBox(width: 5),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 120),
          child: Text(printer.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Colors.white)),
        ),
        if (s != null && s.printing)
          Text(' ${s.progress}%',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: stateColor(s.gcodeState))),
      ]),
    );
  }
}
