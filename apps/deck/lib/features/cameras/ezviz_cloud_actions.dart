import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/camera_profile.dart';
import '../../data/camera_providers.dart';
import '../../data/ezviz_cloud.dart';
import '../../data/ezviz_ptz.dart';
import '../../data/log_buffer.dart';
import '../../ui/camera_tile.dart';
import '../../ui/ptz_pad.dart';

/// 萤石开放平台云端管理 (2026-11-03 用户选定四项能力):
/// 云端改名 / 云端直播地址 / 云端云台 / 设备详情与抓图。
///
/// All four need a device serial (recorded by the EZVIZ import sheet) and the
/// AppKey/AppSecret saved in settings; [EzvizSession] caches the token.

/// 云端改名: renames the device on the EZVIZ account, then mirrors the new
/// name onto the local camera profile so the wall label stays in sync.
Future<void> showEzvizRenameDialog(
    BuildContext context, WidgetRef ref, CameraProfile camera) async {
  final messenger = ScaffoldMessenger.of(context);
  final name = await showDialog<String>(
    context: context,
    builder: (_) => _RenameDialog(initial: camera.name),
  );
  if (name == null || !context.mounted) return;
  final session = ref.read(ezvizSessionProvider);
  try {
    await session
        .run((t) => session.client.renameDevice(t, camera.ezvizSerial, name));
    await ref
        .read(camerasProvider.notifier)
        .replace(camera.copyWith(name: name));
    messenger.showSnackBar(SnackBar(content: Text('已改名为「$name」')));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('云端改名失败: $e')));
  }
}

/// 关联萤石设备: cameras added before the serial field existed have no cloud
/// identity. Lists the account's devices and binds the one the user picks, so
/// the four cloud actions become available without re-importing.
Future<void> showEzvizLinkDialog(
    BuildContext context, WidgetRef ref, CameraProfile camera) async {
  final messenger = ScaffoldMessenger.of(context);
  final session = ref.read(ezvizSessionProvider);
  List<EzvizDevice> devices;
  try {
    devices = await session.run((t) => session.client.fetchDevices(t));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('读取萤石设备失败: $e')));
    return;
  }
  if (!context.mounted) return;
  if (devices.isEmpty) {
    messenger.showSnackBar(const SnackBar(content: Text('该萤石账号下没有设备')));
    return;
  }
  final serial = await showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      backgroundColor: DeckColors.surface,
      title: const Text('关联萤石云端设备'),
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text('选择这台摄像头对应的萤石设备, 关联后即可使用云端直播/云台/改名/抓图',
              style:
                  TextStyle(fontSize: 12, color: DeckColors.textSecondary)),
        ),
        for (final d in devices)
          ListTile(
            leading: Icon(Icons.videocam_outlined,
                size: 20,
                color: d.online ? DeckColors.running : DeckColors.textSecondary),
            title: Text(d.name.isEmpty ? d.serial : d.name),
            subtitle: Text(
              '${d.serial} · ${d.online ? '在线' : '离线'}',
              style: const TextStyle(fontSize: 11),
            ),
            onTap: () => Navigator.pop(ctx, d.serial),
          ),
      ],
    ),
  );
  if (serial == null || !context.mounted) return;
  await ref
      .read(camerasProvider.notifier)
      .replace(camera.copyWith(ezvizSerial: serial));
  messenger.showSnackBar(
      const SnackBar(content: Text('已关联萤石设备, 云端功能已启用')));
}

/// 设备详情 + 云端抓图, in one dialog.
Future<void> showEzvizInfoDialog(
    BuildContext context, WidgetRef ref, CameraProfile camera) {
  return showDialog<void>(
    context: context,
    builder: (_) => _InfoDialog(camera: camera),
  );
}

/// 云端直播: fetches an H.264 live address (FLV first, HLS fallback) and
/// plays it in a dialog - works away from the camera's LAN.
Future<void> showEzvizLiveDialog(
    BuildContext context, WidgetRef ref, CameraProfile camera) {
  return showDialog<void>(
    context: context,
    builder: (_) => _LiveDialog(camera: camera),
  );
}

/// 云端云台: drives the platform PTZ start/stop API through the common
/// [PtzPad], so it behaves exactly like the LAN pad.
Future<void> showEzvizPtzDialog(
    BuildContext context, WidgetRef ref, CameraProfile camera) async {
  final client = EzvizCloudPtz(
    session: ref.read(ezvizSessionProvider),
    serial: camera.ezvizSerial,
    log: LogBuffer.instance.add,
  );
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: DeckColors.surface,
      title: const Text('云端云台'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('按住方向键移动, 松开即停',
            style: TextStyle(fontSize: 12, color: DeckColors.textSecondary)),
        const SizedBox(height: 12),
        PtzPad(
          client: client,
          invertPan: camera.ptzInvertPan,
          invertTilt: camera.ptzInvertTilt,
          unavailableHint: '云台不可用 - 请确认摄像头在线且支持云台',
        ),
      ]),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
  await client.stop();
  client.dispose();
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});

  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _ctrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '名称不能为空');
      return;
    }
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: DeckColors.surface,
        title: const Text('云端改名'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: _ctrl,
              autofocus: true,
              maxLength: 50,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: '设备名称',
                errorText: _error,
                helperText: '同步修改萤石云端设备名, 本机名称一并更新',
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(onPressed: _submit, child: const Text('保存')),
        ],
      );
}

class _InfoDialog extends ConsumerStatefulWidget {
  const _InfoDialog({required this.camera});

  final CameraProfile camera;

  @override
  ConsumerState<_InfoDialog> createState() => _InfoDialogState();
}

class _InfoDialogState extends ConsumerState<_InfoDialog> {
  EzvizDeviceInfo? _info;
  String? _error;
  bool _loading = true;
  bool _capturing = false;
  String? _picUrl;
  String? _captureError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final session = ref.read(ezvizSessionProvider);
    try {
      final info = await session.run(
          (t) => session.client.fetchDeviceInfo(t, widget.camera.ezvizSerial));
      if (!mounted) return;
      setState(() {
        _info = info;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _capture() async {
    setState(() {
      _capturing = true;
      _captureError = null;
    });
    final session = ref.read(ezvizSessionProvider);
    try {
      final url = await session
          .run((t) => session.client.capture(t, widget.camera.ezvizSerial));
      if (!mounted) return;
      setState(() {
        _picUrl = url;
        _capturing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _captureError = '$e';
        _capturing = false;
      });
    }
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 72,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 12, color: DeckColors.textSecondary)),
          ),
          Expanded(
            child: Text(value.isEmpty ? '-' : value,
                style: const TextStyle(fontSize: 13)),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final info = _info;
    return AlertDialog(
      backgroundColor: DeckColors.surface,
      title: Row(children: [
        const Expanded(child: Text('设备详情')),
        IconButton(
          tooltip: '刷新',
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh, size: 18),
        ),
      ]),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_loading) ...[
                const LinearProgressIndicator(minHeight: 2),
                const SizedBox(height: 12),
                const Text('正在读取云端设备信息…',
                    style: TextStyle(
                        fontSize: 12, color: DeckColors.textSecondary)),
              ] else if (_error != null)
                Text('读取失败: $_error',
                    style:
                        const TextStyle(fontSize: 12, color: DeckColors.error))
              else if (info != null) ...[
                _row('名称', info.name),
                _row('序列号', info.serial),
                _row('型号', info.model),
                _row('固件', info.version),
                _row('状态', info.online ? '在线' : '离线'),
                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 12),
                Row(children: [
                  FilledButton.icon(
                    onPressed: _capturing ? null : _capture,
                    icon: _capturing
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.photo_camera_outlined, size: 16),
                    label: Text(_capturing ? '抓图中…' : '云端抓图'),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text('图片约 2 小时内有效',
                        style: TextStyle(
                            fontSize: 11, color: DeckColors.textSecondary)),
                  ),
                ]),
                if (_captureError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('抓图失败: $_captureError',
                        style: const TextStyle(
                            fontSize: 12, color: DeckColors.error)),
                  ),
                if (_picUrl != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        _picUrl!,
                        height: 220,
                        fit: BoxFit.contain,
                        loadingBuilder: (c, child, progress) => progress == null
                            ? child
                            : const SizedBox(
                                height: 220,
                                child: Center(
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2)),
                              ),
                        errorBuilder: (c, e, s) => const SizedBox(
                          height: 60,
                          child: Center(
                            child: Text('图片加载失败',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: DeckColors.textSecondary)),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _LiveDialog extends ConsumerStatefulWidget {
  const _LiveDialog({required this.camera});

  final CameraProfile camera;

  @override
  ConsumerState<_LiveDialog> createState() => _LiveDialogState();
}

class _LiveDialogState extends ConsumerState<_LiveDialog> {
  String? _url;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  /// HLS/FLV only carry H.264; try FLV main, then HLS main, then HLS sub.
  Future<void> _fetch() async {
    final session = ref.read(ezvizSessionProvider);
    const attempts = [(4, 1), (2, 1), (2, 2)];
    final errors = <String>[];
    for (final (protocol, quality) in attempts) {
      try {
        final url = await session.run((t) => session.client.liveAddress(
              t,
              widget.camera.ezvizSerial,
              protocol: protocol,
              quality: quality,
            ));
        if (!mounted) return;
        setState(() {
          _url = url;
          _loading = false;
        });
        return;
      } catch (e) {
        errors.add('$e');
      }
    }
    if (!mounted) return;
    setState(() {
      _error = errors.join('\n');
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final width = math.min(MediaQuery.sizeOf(context).width * 0.9, 960.0);
    final url = _url;
    return Dialog(
      backgroundColor: DeckColors.surface,
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: width,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(children: [
              const Icon(Icons.cloud_outlined,
                  size: 16, color: DeckColors.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${widget.camera.name} · 萤石云端直播',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, size: 18),
              ),
            ]),
          ),
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ColoredBox(
              color: Colors.black,
              child: _loading
                  ? const Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                      CircularProgressIndicator(strokeWidth: 2),
                      SizedBox(height: 12),
                      Text('正在获取云端直播地址…',
                          style: TextStyle(
                              fontSize: 12, color: DeckColors.textSecondary)),
                    ]))
                  : url != null
                      ? CameraTile(
                          streamUrl: url,
                          label: widget.camera.name,
                          expand: true,
                          cameraId: widget.camera.id,
                          frameSlot: 'ezviz-live',
                        )
                      : Center(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Text(
                              '取流失败:\n$_error',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontSize: 12, color: DeckColors.error),
                            ),
                          ),
                        ),
            ),
          ),
        ]),
      ),
    );
  }
}
