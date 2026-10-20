import 'dart:io';

import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../core/theme.dart';
import '../../data/camera_profile.dart';
import '../../data/printer_profile.dart';
import '../../data/providers.dart';
import '../../data/rtsp_scanner.dart';
import '../../ui/camera_tile.dart';

/// Cameras tab body (PRD FR-3): live tile per camera, add via dialog.
class CamerasPage extends ConsumerWidget {
  const CamerasPage({super.key, required this.onAdd});

  /// Opens the add-camera dialog; owned by the shell so the FAB can
  /// trigger it too.
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                  style: TextStyle(
                      fontSize: 16, color: DeckColors.textSecondary)),
              const SizedBox(height: 6),
              const Text('RTSP/ONVIF 网络摄像头,或打印机自带摄像头(X1/P1 系)',
                  style: TextStyle(
                      fontSize: 13, color: DeckColors.textSecondary)),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add),
                label: const Text('添加摄像头'),
              ),
            ]),
          );
        }
        return LayoutBuilder(builder: (context, constraints) {
          final columns = (constraints.maxWidth ~/ 420).clamp(1, 3);
          return GridView.count(
            padding: const EdgeInsets.all(16),
            crossAxisCount: columns,
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            childAspectRatio: 16 / 12,
            children: [
              for (final c in list)
                _CameraCard(
                    camera: c,
                    printers: printers,
                    onDelete: () =>
                        ref.read(camerasProvider.notifier).remove(c.id)),
            ],
          );
        });
      },
    );
  }
}

class _CameraCard extends ConsumerStatefulWidget {
  const _CameraCard({
    required this.camera,
    required this.printers,
    required this.onDelete,
  });

  final CameraProfile camera;
  final List<PrinterProfile> printers;
  final VoidCallback onDelete;

  @override
  ConsumerState<_CameraCard> createState() => _CameraCardState();
}

class _CameraCardState extends ConsumerState<_CameraCard> {
  /// NFR-3: streams outside the viewport stop pulling. Mounting the tile
  /// only while visible disposes its player on scroll-out.
  bool _visible = true;

  @override
  Widget build(BuildContext context) {
    final camera = widget.camera;
    PrinterProfile? linked;
    for (final p in widget.printers) {
      if (camera.printerIds.contains(p.id)) linked = p;
    }
    final url = camera.resolveUrl(linked);

    return VisibilityDetector(
      key: Key('cam-${camera.id}'),
      onVisibilityChanged: (info) {
        final visible = info.visibleFraction > 0.05;
        if (mounted && visible != _visible) {
          setState(() => _visible = visible);
        }
      },
      child: Card(
        clipBehavior: Clip.antiAlias,
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: url != null && camera.enabled && _visible
                ? CameraTile(streamUrl: url, label: camera.name,
                    onToggleQuality: qualityToggler(ref, camera))
                : Container(
                    color: Colors.black,
                    alignment: Alignment.center,
                    child: Text(
                      !camera.enabled
                          ? '已停用'
                          : url == null
                              ? '未配置视频源'
                              : '画面已在后台暂停',
                      style: const TextStyle(
                          fontSize: 13, color: DeckColors.textSecondary),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(children: [
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(camera.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                      Text(
                        '${camera.sourceType.label}'
                        '${linked == null ? '' : ' · ${linked.name}'}',
                        style: const TextStyle(
                            fontSize: 12,
                            color: DeckColors.textSecondary),
                      ),
                    ]),
              ),
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 19),
                tooltip: '编辑摄像头',
                onPressed: () => showAddCameraDialog(context, ref,
                    editing: camera),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                tooltip: '删除摄像头',
                onPressed: widget.onDelete,
              ),
            ]),
          ),
        ]),
      ),
    );
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
  final initialUrl =
      editing == null ? template : (editing.url.isEmpty ? template : editing.url);
  final urlCtrl = TextEditingController(text: initialUrl)
    ..value = TextEditingValue(
      text: initialUrl,
      selection: TextSelection.collapsed(offset: initialUrl.length),
    );
  var type = editing?.sourceType ?? CameraSourceType.rtsp;
  var flipH = editing?.flipH ?? false;
  var rotationDeg = editing?.rotationDeg ?? 0;
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
  final lanPrinters =
      printers.where((p) => p.mode == PrinterMode.lan).toList();

  /// Fill the URL field from a scan hit; auth-only hits get an `admin:`
  /// placeholder so the password is the only thing left to type.
  void fillFromHit(RtspHit h) {
    final text = h.needsAuth
        ? 'rtsp://admin:@${h.ip}:${h.port}${h.path}'
        : h.url;
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
          scanError =
              '该网段没有任何开放的视频端口——确认摄像头在这个网段、已上电联网,'
              '且路由器没开「终端/AP 隔离」';
        } else if (report.hits.isEmpty) {
          scanError =
              '发现 ${report.openPorts} 个开放端口,但没有端口用标准 RTSP 应答——'
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
                      value: CameraSourceType.rtsp,
                      label: Text('RTSP/ONVIF')),
                  ButtonSegment(
                      value: CameraSourceType.bambu,
                      label: Text('打印机自带')),
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
                Text('画面方向',
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
                    style: const ButtonStyle(
                        visualDensity: VisualDensity.compact),
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
                            labelText: '扫描网段前缀',
                            hintText: '192.168.100'),
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
                  LinearProgressIndicator(value: total == 0 ? null : done / total),
                  const SizedBox(height: 4),
                  Text('已探测 $done/$total',
                      style: const TextStyle(
                          fontSize: 11,
                          color: DeckColors.textSecondary)),
                ],
                if (scanError.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(scanError,
                      style: const TextStyle(
                          fontSize: 12,
                          color: DeckColors.textSecondary)),
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
                          title: Text(h.url,
                              style: const TextStyle(fontSize: 12)),
                          subtitle: subtitle.isEmpty
                              ? null
                              : Text(subtitle,
                                  style: const TextStyle(fontSize: 11)),
                          onTap: () {
                            fillFromHit(h);
                            if (nameCtrl.text.trim().isEmpty) {
                              final octet =
                                  h.ip.split('.').last;
                              nameCtrl.text =
                                  '${h.vendor ?? "摄像头"} $octet';
                            }
                          },
                        );
                      },
                    ),
                  ),
                  const Text('点击结果填入地址(需要密码的话在地址里加 user:pass@)',
                      style: TextStyle(
                          fontSize: 11,
                          color: DeckColors.textSecondary)),
                ],
                const SizedBox(height: 10),
                DropdownButtonFormField<PrinterProfile>(
                  initialValue: linked,
                  decoration: const InputDecoration(
                      labelText: '关联打印机(可选,显示在其仪表盘)'),
                  items: [
                    for (final p in printers)
                      DropdownMenuItem(value: p, child: Text(p.name)),
                  ],
                  onChanged: (p) => setState(() => linked = p),
                ),
              ] else ...[
                DropdownButtonFormField<PrinterProfile>(
                  initialValue: linked,
                  decoration: const InputDecoration(
                      labelText: '选择打印机(局域网直连)'),
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
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () {
                if (type == CameraSourceType.rtsp) {
                  final u = urlCtrl.text.trim();
                  if (u == template ||
                      !u.startsWith('rtsp://') ||
                      RegExp(r'^rtsp://[^/]*$').hasMatch(u)) {
                    setState(() => urlError =
                        '地址没改过或不对——直接在预填模板上改,'
                        '或「自动扫描」后点结果');
                    return;
                  }
                }
                Navigator.pop(ctx, true);
              },
              child: Text(editing == null ? '添加' : '保存')),
        ],
      ),
    ),
  );
  if (ok != true) return;

  final name = nameCtrl.text.trim().isEmpty
      ? (type == CameraSourceType.bambu
          ? (linked?.name ?? '打印机摄像头')
          : '摄像头')
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
