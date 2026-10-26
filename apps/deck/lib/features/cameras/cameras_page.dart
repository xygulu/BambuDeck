import 'dart:io';

import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flutter/gestures.dart';

import '../../core/theme.dart';
import '../../data/camera_profile.dart';
import '../../data/camera_providers.dart';
import '../../data/printer_profile.dart';
import '../../data/providers.dart';
import '../../data/rtsp_scanner.dart';
import '../../ui/camera_tile.dart';
import '../monitor/overview_wall.dart';

/// Cameras tab body (PRD FR-3): a zoomable wall of live tiles (2026-10-26
/// 需求) - 默认单画面, 鼠标滚轮/捏合缩小逐档显示更多画面 (一排两个 →
/// 2x2 → 3x3 … 封顶全部), 放大反之; 网格按画面数自动取最佳 16:9 排布。
class CamerasPage extends ConsumerStatefulWidget {
  const CamerasPage({super.key, required this.onAdd});

  /// Opens the add-camera dialog; owned by the shell so the FAB can
  /// trigger it too.
  final VoidCallback onAdd;

  @override
  ConsumerState<CamerasPage> createState() => _CamerasPageState();
}

class _CamerasPageState extends ConsumerState<CamerasPage> {
  /// 缩放档位下标, 默认 0 = 单画面; 档位对应的画面数 1→2→4→9→16…。
  int _level = 0;

  /// 捏合进行中的实时缩放 (仅视觉反馈, 松手归位)。
  double _pinch = 1.0;

  /// 档位 → 画面数: [1, 2, 4, 9, 16 …], 封顶实际摄像头数。
  List<int> _levelsFor(int n) {
    const base = [1, 2, 4, 9, 16, 25, 36, 49, 64, 81, 100];
    int cap(int c) => c >= n ? n : c;
    final levels = <int>[for (final c in base) if (c == 1 || cap(c) < n) cap(c)];
    if (levels.last != n) levels.add(n);
    return levels;
  }

  void _stepZoom(int delta) {
    final n =
        (ref.read(camerasProvider).valueOrNull ?? const <CameraProfile>[])
            .length;
    if (n == 0) return;
    setState(() {
      _level = (_level + delta).clamp(0, _levelsFor(n).length - 1);
      _pinch = 1.0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cameras = ref.watch(camerasProvider);
    final printers = ref.watch(printersProvider).valueOrNull ?? const [];

    return cameras.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
          child: Text('读取摄像头配置失败: $e',
              style: const TextStyle(color: DeckColors.error))),
      data: (list) {
        if (list.isEmpty) {
          return Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.videocam_off_outlined,
                  size: 56,
                  color: DeckColors.textSecondary.withValues(alpha: 0.6)),
              const SizedBox(height: 12),
              const Text('还没有摄像头',
                  style:
                      TextStyle(fontSize: 16, color: DeckColors.textSecondary)),
              const SizedBox(height: 6),
              const Text('RTSP/ONVIF 网络摄像头,或打印机自带摄像头(X1/P1 系)',
                  style:
                      TextStyle(fontSize: 13, color: DeckColors.textSecondary)),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: widget.onAdd,
                icon: const Icon(Icons.add),
                label: const Text('添加摄像头'),
              ),
            ]),
          );
        }

        // A stale level (摄像头被删) clamps itself in _wall.
        return _wall(list, printers);
      },
    );
  }

  /// 可缩放的墙: 默认单画面; 滚轮下滚/捏合缩小 → 逐档显示更多画面
  /// (一排两个 → 2x2 → 3x3…封顶全部), 上滚/捏合放大反之; 双击就近切换
  /// 一档; 右上角 ± 按钮兜底并显示当前画面数。
  Widget _wall(List<CameraProfile> list, List<PrinterProfile> printers) {
    final levels = _levelsFor(list.length);
    if (_level > levels.length - 1) _level = levels.length - 1;
    final shown = list.take(levels[_level]).toList();
    final canZoomIn = _level > 0;
    final canZoomOut = _level < levels.length - 1;

    return LayoutBuilder(builder: (context, box) {
      final n = shown.length;
      final w = box.maxWidth > 0 ? box.maxWidth : 1.0;
      final h = box.maxHeight > 0 ? box.maxHeight : 1.0;
      final bestCols = bestFitColumns(n, w, h);
      final rows = (n / bestCols).ceil();
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Stack(children: [
          Listener(
            onPointerSignal: (e) {
              if (e is PointerScrollEvent && e.scrollDelta.dy != 0) {
                // 下滚 = 缩小 = 画面变多; 上滚 = 放大。
                _stepZoom(e.scrollDelta.dy > 0 ? 1 : -1);
              }
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onScaleUpdate: (d) {
                if (d.scale != 1.0) setState(() => _pinch = d.scale);
              },
              onScaleEnd: (_) {
                final s = _pinch;
                if (s < 0.85) {
                  _stepZoom(1); // 捏合缩小 → 画面变多
                } else if (s > 1.15) {
                  _stepZoom(-1); // 捏合放大 → 画面变少
                } else {
                  setState(() => _pinch = 1.0);
                }
              },
              onDoubleTap: () => _stepZoom(canZoomIn ? -1 : (canZoomOut ? 1 : 0)),
              child: Transform.scale(
                scale: _pinch,
                child: Column(children: [
                  for (var r = 0; r < rows; r++)
                    Expanded(
                      child: Row(children: [
                        for (var i = r * bestCols;
                            i < (r + 1) * bestCols && i < n;
                            i++)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(5),
                              child: _wallCell(shown[i], printers),
                            ),
                          ),
                        // 补位空格, 末行不满时格子宽度与上方一致。
                        for (var i = n; i < (r + 1) * bestCols; i++)
                          const Expanded(child: SizedBox()),
                      ]),
                    ),
                ]),
              ),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text('${shown.length}/${list.length}',
                    style: const TextStyle(fontSize: 11, color: Colors.white)),
                const SizedBox(width: 2),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.zoom_in, size: 18, color: Colors.white),
                  tooltip: '放大 (画面更少更大)',
                  onPressed: canZoomIn ? () => _stepZoom(-1) : null,
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon:
                      const Icon(Icons.zoom_out, size: 18, color: Colors.white),
                  tooltip: '缩小 (画面更多)',
                  onPressed: canZoomOut ? () => _stepZoom(1) : null,
                ),
              ]),
            ),
          ),
        ]),
      );
    });
  }

  /// One wall cell: the feed fills the cell; 绑定打印机时左上角挂状态角标。
  Widget _wallCell(CameraProfile camera, List<PrinterProfile> printers) {
    final linked = _linkedPrinter(camera, printers);
    final url = camera.resolveUrl(linked);
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Stack(fit: StackFit.expand, children: [
        if (url != null && camera.enabled)
          CameraTile(
            streamUrl: url,
            label: camera.name,
            expand: true,
            onToggleQuality: qualityToggler(ref, camera),
            cameraId: camera.id,
            frameSlot: 'cameras-grid',
            flipH: camera.flipH,
            rotationDeg: camera.rotationDeg,
            ptzInvertPan: camera.ptzInvertPan,
            ptzInvertTilt: camera.ptzInvertTilt,
          )
        else
          Container(
            color: Colors.black,
            alignment: Alignment.center,
            child: Text(
              !camera.enabled ? '已停用' : '未配置视频源',
              style:
                  const TextStyle(fontSize: 13, color: DeckColors.textSecondary),
            ),
          ),
        if (linked != null)
          Positioned(left: 8, top: 8, child: FeedStatusChip(printer: linked)),
      ]),
    );
  }

  PrinterProfile? _linkedPrinter(
      CameraProfile camera, List<PrinterProfile> printers) {
    for (final p in printers) {
      if (camera.printerIds.contains(p.id)) return p;
    }
    return null;
  }
}

/// Add-camera dialog: RTSP/ONVIF URL (with LAN auto-scan) or the
/// printer's own camera.
/// 添加 / 编辑摄像头 ([editing] 传入既有条目即为编辑模式, 反馈 2026-10-20:
/// 名称 / RTSP 连接信息可改)。编辑保持 id / enabled / 码流档位不变。
Future<void> showAddCameraDialog(BuildContext context, WidgetRef ref,
    {CameraProfile? editing}) async {
  final nameCtrl = TextEditingController(text: editing?.name ?? '');
  final subnetCtrl = TextEditingController(text: await _guessSubnet());
  if (!context.mounted) return;
  // The RTSP field starts as an editable template - the cursor sits right
  // after "admin:" so the password is the first thing typed. The hint
  // would vanish on first keystroke; this never does.
  final template = 'rtsp://admin:密码@${subnetCtrl.text}.10:554/stream1';
  final initialUrl = editing == null
      ? template
      : (editing.url.isEmpty ? template : editing.url);
  final urlCtrl = TextEditingController(text: initialUrl)
    ..value = TextEditingValue(
      text: initialUrl,
      selection: TextSelection.collapsed(offset: initialUrl.length),
    );
  var type = editing?.sourceType ?? CameraSourceType.rtsp;
  var flipH = editing?.flipH ?? false;
  var rotationDeg = editing?.rotationDeg ?? 0;
  var ptzInvertPan = editing?.ptzInvertPan ?? false;
  var ptzInvertTilt = editing?.ptzInvertTilt ?? false;
  PrinterProfile? linked;
  if (editing != null && editing.printerIds.isNotEmpty) {
    final printers = ref.read(printersProvider).valueOrNull ?? const [];
    for (final p in printers) {
      if (p.id == editing.printerIds.first) linked = p;
    }
  }

  // LAN scan state.
  var scanning = false;
  var done = 0;
  var total = 0;
  var scanError = '';
  var urlError = '';
  var hits = const <RtspHit>[];

  final printers = ref.read(printersProvider).valueOrNull ?? const [];
  final lanPrinters = printers.where((p) => p.mode == PrinterMode.lan).toList();

  /// Fill the URL field from a scan hit; auth-only hits get an `admin:`
  /// placeholder so the password is the only thing left to type.
  void fillFromHit(RtspHit h) {
    final text =
        h.needsAuth ? 'rtsp://admin:@${h.ip}:${h.port}${h.path}' : h.url;
    urlCtrl.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(
          offset: h.needsAuth ? 'rtsp://admin:'.length : text.length),
    );
  }

  Future<void> runScan(StateSetter setState) async {
    final prefix = subnetCtrl.text.trim();
    if (!RegExp(r'^\d{1,3}(\.\d{1,3}){2}$').hasMatch(prefix)) {
      setState(() => scanError = '网段前缀格式应为 192.168.100');
      return;
    }
    setState(() {
      scanning = true;
      scanError = '';
      hits = const [];
      done = 0;
      total = 762;
    });
    try {
      final report = await scanRtspCameras(
        subnetPrefix: prefix,
        onProgress: (d, t) {
          if (d % 32 == 0 || d == t) {
            setState(() => done = d);
          }
        },
      );
      setState(() {
        hits = report.hits;
        scanning = false;
        if (report.hits.isEmpty && report.openPorts == 0) {
          scanError = '该网段没有任何开放的视频端口——确认摄像头在这个网段、已上电联网,'
              '且路由器没开「终端/AP 隔离」';
        } else if (report.hits.isEmpty) {
          scanError = '发现 ${report.openPorts} 个开放端口,但没有端口用标准 RTSP 应答——'
              '摄像头可能需要在自家 App 里开启局域网访问(萤石:App 设备设置里的本地直播),'
              '或流路径不在常见列表里';
        }
      });
    } catch (e) {
      setState(() {
        scanning = false;
        scanError = '扫描失败: $e';
      });
    }
  }

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        backgroundColor: DeckColors.surface,
        title: Text(editing == null ? '添加摄像头' : '编辑摄像头'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                    labelText: '名称', hintText: '例如 打印房门口'),
              ),
              const SizedBox(height: 12),
              SegmentedButton<CameraSourceType>(
                segments: const [
                  ButtonSegment(
                      value: CameraSourceType.rtsp, label: Text('RTSP/ONVIF')),
                  ButtonSegment(
                      value: CameraSourceType.bambu, label: Text('打印机自带')),
                ],
                selected: {type},
                onSelectionChanged: (s) => setState(() => type = s.first),
              ),
              const SizedBox(height: 12),
              if (type == CameraSourceType.rtsp) ...[
                TextField(
                  controller: urlCtrl,
                  onChanged: (_) {
                    if (urlError.isNotEmpty) {
                      setState(() => urlError = '');
                    }
                  },
                  decoration: InputDecoration(
                    labelText: 'RTSP 地址(可直接编辑预填模板)',
                    errorText: urlError.isEmpty ? null : urlError,
                  ),
                ),
                const SizedBox(height: 14),
                const Text('画面方向',
                    style: TextStyle(
                        fontSize: 12, color: DeckColors.textSecondary)),
                const SizedBox(height: 6),
                Row(children: [
                  const Text('水平翻转', style: TextStyle(fontSize: 13)),
                  Switch(
                    value: flipH,
                    activeThumbColor: DeckColors.running,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: (v) => setState(() => flipH = v),
                  ),
                  const SizedBox(width: 16),
                  const Text('旋转', style: TextStyle(fontSize: 13)),
                  const SizedBox(width: 8),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 0, label: Text('0°')),
                      ButtonSegment(value: 90, label: Text('90°')),
                      ButtonSegment(value: 180, label: Text('180°')),
                      ButtonSegment(value: 270, label: Text('270°')),
                    ],
                    selected: {rotationDeg},
                    onSelectionChanged: (s) =>
                        setState(() => rotationDeg = s.first),
                    style:
                        const ButtonStyle(visualDensity: VisualDensity.compact),
                  ),
                ]),
                const SizedBox(height: 6),
                // 云台方向校准 (2026-10-21): 个别摄像头(吊装/固件)某个轴的
                // 物理转向与命令语义相反, 表现为固定一对箭头方向不对。
                Row(children: [
                  const Text('云台方向校准',
                      style: TextStyle(
                          fontSize: 12, color: DeckColors.textSecondary)),
                  const SizedBox(width: 16),
                  const Text('左右反转', style: TextStyle(fontSize: 13)),
                  Switch(
                    value: ptzInvertPan,
                    activeThumbColor: DeckColors.running,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: (v) => setState(() => ptzInvertPan = v),
                  ),
                  const SizedBox(width: 16),
                  const Text('上下反转', style: TextStyle(fontSize: 13)),
                  Switch(
                    value: ptzInvertTilt,
                    activeThumbColor: DeckColors.running,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: (v) => setState(() => ptzInvertTilt = v),
                  ),
                ]),
                // 编辑模式只改名称/连接信息, 网段扫描是添加时的入口。
                if (editing == null) ...[
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                      child: TextField(
                        controller: subnetCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                            labelText: '扫描网段前缀', hintText: '192.168.100'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: scanning ? null : () => runScan(setState),
                      child: Text(scanning ? '扫描中…' : '自动扫描'),
                    ),
                  ]),
                ],
                if (scanning) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                      value: total == 0 ? null : done / total),
                  const SizedBox(height: 4),
                  Text('已探测 $done/$total',
                      style: const TextStyle(
                          fontSize: 11, color: DeckColors.textSecondary)),
                ],
                if (scanError.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(scanError,
                      style: const TextStyle(
                          fontSize: 12, color: DeckColors.textSecondary)),
                ],
                if (hits.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 150),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: hits.length,
                      itemBuilder: (ctx, i) {
                        final h = hits[i];
                        final subtitle = [
                          if (h.vendor != null) h.vendor!,
                          if (h.needsAuth) '需要摄像头密码',
                        ].join(' · ');
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.videocam, size: 18),
                          title:
                              Text(h.url, style: const TextStyle(fontSize: 12)),
                          subtitle: subtitle.isEmpty
                              ? null
                              : Text(subtitle,
                                  style: const TextStyle(fontSize: 11)),
                          onTap: () {
                            fillFromHit(h);
                            if (nameCtrl.text.trim().isEmpty) {
                              final octet = h.ip.split('.').last;
                              nameCtrl.text = '${h.vendor ?? "摄像头"} $octet';
                            }
                          },
                        );
                      },
                    ),
                  ),
                  const Text('点击结果填入地址(需要密码的话在地址里加 user:pass@)',
                      style: TextStyle(
                          fontSize: 11, color: DeckColors.textSecondary)),
                ],
                const SizedBox(height: 10),
                DropdownButtonFormField<PrinterProfile>(
                  initialValue: linked,
                  decoration:
                      const InputDecoration(labelText: '关联打印机(可选,显示在其仪表盘)'),
                  items: [
                    for (final p in printers)
                      DropdownMenuItem(value: p, child: Text(p.name)),
                  ],
                  onChanged: (p) => setState(() => linked = p),
                ),
              ] else ...[
                DropdownButtonFormField<PrinterProfile>(
                  initialValue: linked,
                  decoration: const InputDecoration(labelText: '选择打印机(局域网直连)'),
                  items: [
                    for (final p in lanPrinters)
                      DropdownMenuItem(value: p, child: Text(p.name)),
                  ],
                  onChanged: (p) => setState(() => linked = p),
                ),
                const SizedBox(height: 10),
                Text(
                  '摄像头取流方式由打印机机型决定(添加打印机时选的「机型」):'
                  'A1 / A1 mini / P1 / P1P 走内置 MJPEG(6000 端口),'
                  'X1 / P1S / P2S / H2 系走 RTSPS(322 端口)。'
                  '凭据 bblp + 访问码自动填入,画面本地直连、不经过拓竹云。',
                  style: TextStyle(
                      fontSize: 12,
                      color: DeckColors.textSecondary.withValues(alpha: 0.9)),
                ),
              ],
            ]),
          ),
        ),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: [
          // 编辑模式才有删除 (2026-10-21 从卡片/面板头迁入), 二次确认后执行。
          if (editing != null)
            TextButton(
              style: TextButton.styleFrom(foregroundColor: DeckColors.error),
              onPressed: () async {
                final yes = await showDialog<bool>(
                  context: ctx,
                  builder: (dctx) => AlertDialog(
                    backgroundColor: DeckColors.surface,
                    title: const Text('删除摄像头'),
                    content: Text('确定删除「${editing.name}」吗?'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dctx, false),
                          child: const Text('取消')),
                      FilledButton(
                        style: FilledButton.styleFrom(
                            backgroundColor: DeckColors.error),
                        onPressed: () => Navigator.pop(dctx, true),
                        child: const Text('删除'),
                      ),
                    ],
                  ),
                );
                if (yes != true) return;
                await ref.read(camerasProvider.notifier).remove(editing.id);
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('删除摄像头'),
            ),
          Row(mainAxisSize: MainAxisSize.min, children: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            const SizedBox(width: 4),
            FilledButton(
              onPressed: () {
                if (type == CameraSourceType.rtsp) {
                  final u = urlCtrl.text.trim();
                  if (u == template ||
                      !u.startsWith('rtsp://') ||
                      RegExp(r'^rtsp://[^/]*$').hasMatch(u)) {
                    setState(() => urlError = '地址没改过或不对——直接在预填模板上改,'
                        '或「自动扫描」后点结果');
                    return;
                  }
                }
                Navigator.pop(ctx, true);
              },
              child: Text(editing == null ? '添加' : '保存')),
          ]),
        ],
      ),
    ),
  );
  if (ok != true) return;

  final name = nameCtrl.text.trim().isEmpty
      ? (type == CameraSourceType.bambu ? (linked?.name ?? '打印机摄像头') : '摄像头')
      : nameCtrl.text.trim();
  final printerIds = linked?.id == null ? const <String>[] : [linked!.id];

  if (editing != null) {
    // 编辑: 保留 id / enabled / 码流档位, 只改名称、连接信息与绑定。
    await ref.read(camerasProvider.notifier).replace(editing.copyWith(
          name: name,
          url: type == CameraSourceType.rtsp ? urlCtrl.text.trim() : '',
          printerIds: printerIds,
          flipH: flipH,
          rotationDeg: rotationDeg,
          ptzInvertPan: ptzInvertPan,
          ptzInvertTilt: ptzInvertTilt,
        ));
    return;
  }

  final camera = CameraProfile(
    id: 'c_${DateTime.now().millisecondsSinceEpoch}',
    name: name,
    sourceType: type,
    url: type == CameraSourceType.rtsp ? urlCtrl.text.trim() : '',
    printerIds: printerIds,
    flipH: flipH,
    rotationDeg: rotationDeg,
    ptzInvertPan: ptzInvertPan,
    ptzInvertTilt: ptzInvertTilt,
  );
  await ref.read(camerasProvider.notifier).add(camera);
}

/// First non-loopback IPv4's first three octets - the usual LAN.
Future<String> _guessSubnet() async {
  try {
    final interfaces = await NetworkInterface.list();
    for (final itf in interfaces) {
      for (final addr in itf.addresses) {
        if (addr.type != InternetAddressType.IPv4) continue;
        if (addr.address.startsWith('127.')) continue;
        final parts = addr.address.split('.');
        if (parts.length != 4) continue;
        return '${parts[0]}.${parts[1]}.${parts[2]}';
      }
    }
  } on SocketException {
    // fall through
  }
  return '192.168.1';
}
