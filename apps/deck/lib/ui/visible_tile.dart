import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../core/theme.dart';

/// Mounts [child] (a live stream tile) only while it is actually on
/// screen (NFR-3): scrolled-out lists and IndexedStack siblings hidden
/// behind a perspective switch both report invisible, so their players
/// get disposed and stop pulling. A placeholder says why the picture went
/// away.
class VisibleOnlyTile extends StatefulWidget {
  const VisibleOnlyTile({
    super.key,
    required this.streamId,
    required this.child,
  });

  /// Stable per-stream id for the visibility key and player lifecycle.
  final String streamId;
  final Widget child;

  @override
  State<VisibleOnlyTile> createState() => _VisibleOnlyTileState();
}

class _VisibleOnlyTileState extends State<VisibleOnlyTile> {
  bool _visible = true;

  @override
  Widget build(BuildContext context) {
    return VisibilityDetector(
      key: Key('vis-${widget.streamId}'),
      onVisibilityChanged: (info) {
        final visible = info.visibleFraction > 0.05;
        if (mounted && visible != _visible) {
          setState(() => _visible = visible);
        }
      },
      child: _visible
          ? widget.child
          : ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Container(
                color: Colors.black,
                height: 120,
                alignment: Alignment.center,
                child: const Text('画面已在后台暂停',
                    style: TextStyle(
                        fontSize: 13, color: DeckColors.textSecondary)),
              ),
            ),
    );
  }
}
