import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/bambu_mjpeg.dart';
import '../data/log_buffer.dart';

/// Live view for the A1/P1-family built-in camera: MJPEG frames pushed
/// over TLS :6000. Decodes are capped to ~15 fps - the printer pushes
/// faster than a monitoring tile needs to redraw.
class MjpegTile extends StatefulWidget {
  const MjpegTile({
    super.key,
    required this.host,
    this.port = 6000,
    required this.username,
    required this.password,
    this.label,
  });

  final String host;
  final int port;
  final String username;
  final String password;
  final String? label;

  @override
  State<MjpegTile> createState() => _MjpegTileState();
}

class _MjpegTileState extends State<MjpegTile> {
  BambuMjpegStream? _stream;
  Uint8List? _jpeg;
  String? _error;
  DateTime _lastPaint = DateTime.fromMillisecondsSinceEpoch(0);
  bool _reconnecting = false;

  static const _minFrameInterval = Duration(milliseconds: 66);

  void _open() {
    _stream?.dispose();
    final stream = BambuMjpegStream(
      host: widget.host,
      port: widget.port,
      username: widget.username,
      password: widget.password,
      onFrame: _onFrame,
      onError: (msg) {
        // The stream retries on its own; surface the failure only while
        // nothing has ever rendered.
        LogBuffer.instance.add('[${widget.label ?? "摄像头"}] MJPEG: $msg');
        if (!mounted) return;
        setState(() {
          if (_jpeg == null) {
            _error = msg;
          } else {
            _reconnecting = true;
          }
        });
      },
    );
    setState(() {
      _stream = stream;
      _reconnecting = false;
      _error = null;
    });
    stream.start();
  }

  void _onFrame(Uint8List jpeg) {
    final now = DateTime.now();
    if (now.difference(_lastPaint) < _minFrameInterval) return;
    _lastPaint = now;
    if (!mounted) return;
    setState(() {
      _jpeg = jpeg;
      _reconnecting = false;
    });
  }

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void didUpdateWidget(MjpegTile old) {
    super.didUpdateWidget(old);
    if (old.host != widget.host ||
        old.port != widget.port ||
        old.username != widget.username ||
        old.password != widget.password) {
      _open();
    }
  }

  @override
  void dispose() {
    _stream?.dispose();
    _stream = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final jpeg = _jpeg;
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: Colors.black),
        if (jpeg != null)
          Image.memory(
            jpeg,
            gaplessPlayback: true,
            fit: BoxFit.contain,
          )
        else if (_error != null)
          _overlay(_error!, retry: true)
        else
          const Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              CircularProgressIndicator(),
              SizedBox(height: 8),
              Text('连接打印机摄像头…',
                  style: TextStyle(
                      fontSize: 12, color: DeckColors.textSecondary)),
            ]),
          ),
        if (jpeg != null && _reconnecting)
          const Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: EdgeInsets.all(6),
              child: _Chip(text: '重连中…'),
            ),
          ),
        if (widget.label != null && widget.label!.isNotEmpty)
          Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: _Chip(text: widget.label!),
            ),
          ),
      ],
    );
  }

  Widget _overlay(String message, {bool retry = false}) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 12, color: DeckColors.textSecondary)),
          if (retry) ...[
            const SizedBox(height: 8),
            IconButton(
              onPressed: _open,
              icon: const Icon(Icons.refresh),
              tooltip: '重连',
            ),
          ],
        ]),
      );
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(text,
            style: const TextStyle(fontSize: 11, color: Colors.white)),
      );
}
