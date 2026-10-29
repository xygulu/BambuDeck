/// 全平台版本号 (2026-10-29 自动更新体系)。
///
/// CI 打 tag `vX.Y.Z` 时用 `--dart-define=DECK_VERSION=X.Y.Z` 注入
/// (Android APK / Windows GUI / macOS GUI / hub AOT 全部同源);
/// 本地无注入构建显示 `dev`, 语义比较里永远小于任何正式版。
const String deckVersion =
    String.fromEnvironment('DECK_VERSION', defaultValue: 'dev');

/// 版本语义比较: 逐段数字比大小 (`3.9.10` 大于 `3.9.2`), 段数不齐补 0;
/// 预发布后缀 (-dev/-beta/...) 比同一版本号的正式版小。
/// 返回 a 小于 b 是 -1, 相等是 0, a 大于 b 是 1; 解析不出数字段时 a 最小。
int compareVersions(String a, String b) {
  List<Object> parts(String v) {
    final s = v.trim().replaceFirst(RegExp(r'^[vV]'), '');
    final m = RegExp(r'^([\d.]+)(.*)$').firstMatch(s);
    if (m == null) return <Object>[-1]; // 无数字段: 排最后
    final nums = m.group(1)!
        .split('.')
        .map((p) => int.tryParse(p) ?? 0)
        .toList();
    final suffix = m.group(2)!.trim(); // '-dev' / '-beta.1' / ''
    return <Object>[nums, suffix];
  }

  final pa = parts(a), pb = parts(b);
  final na = pa[0] == -1 ? <int>[] : (pa[0] as List<int>);
  final nb = pb[0] == -1 ? <int>[] : (pb[0] as List<int>);
  final n = na.length > nb.length ? na.length : nb.length;
  for (var i = 0; i < n; i++) {
    final x = i < na.length ? na[i] : 0;
    final y = i < nb.length ? nb[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  final sa = (pa.length > 1 ? pa[1] as String : '').trim();
  final sb = (pb.length > 1 ? pb[1] as String : '').trim();
  if (sa == sb) return 0;
  if (sa.isEmpty) return 1; // 正式版 > 预发布
  if (sb.isEmpty) return -1;
  return sa.compareTo(sb);
}
