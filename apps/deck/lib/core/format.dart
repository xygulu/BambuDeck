/// Display formatting helpers (zh-CN oriented).
library;

/// 55 -> "55分钟", 90 -> "1小时30分".
String fmtRemaining(int minutes) {
  if (minutes <= 0) return '0分钟';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '$m分钟';
  if (m == 0) return '$h小时';
  return '$h小时$m分';
}

/// Finish clock time = now + remaining, e.g. "14:35 完成约" style input.
/// Returns "明天 14:35" when the ETA crosses midnight.
String fmtFinishTime(DateTime now, int remainingMinutes) {
  final eta = now.add(Duration(minutes: remainingMinutes));
  final hh = eta.hour.toString().padLeft(2, '0');
  final mm = eta.minute.toString().padLeft(2, '0');
  final time = '$hh:$mm';
  final crossesMidnight = eta.day != now.day;
  return crossesMidnight ? '明天 $time' : time;
}

String fmtTemp(double value, [double? target]) {
  final v = value.round().toString();
  if (target == null || target <= 0) return '$v°';
  return '$v° / ${target.round()}°';
}

String fmtPercent(int p) => '$p%';
