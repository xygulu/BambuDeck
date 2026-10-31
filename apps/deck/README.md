# deck

BambuDeck 的 Flutter 客户端(多端:macOS / Windows / Android),与 Hub 服务端
共享同一套打印机协议(`packages/bambu_protocol`)与网页前端。产品说明、部署与
发版流程见仓库根 [README](../../README.md) 与 [研发计划](../../docs/研发计划.md)。

## 本地开发

```bash
flutter pub get
flutter run -d macos      # 或 windows / 对应设备
```

版本号由 CI 发版时以 `--dart-define=DECK_VERSION=X.Y.Z` 注入(取自 `v*` tag);
本地构建不带该参数,按 `dev` 处理,永远认为有正式版可更新,仅供调试。
