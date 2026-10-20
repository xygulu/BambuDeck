# BambuDeck

多平台拓竹(Bambu Lab)打印机 + 摄像头监控套件,由 [BambuHelper](../BambuHelper)(ESP32 固件)改造而来。

> 本目录是**全新项目**,与原项目并行存在,不改动 `BambuHelper` 任何代码。

## 文档

| 文档 | 说明 |
|---|---|
| [需求文档(PRD)](docs/需求文档-PRD.md) | 产品定位、双模式架构、完整功能需求(打印机监控 + 摄像头监控 + 组合大屏)、平台矩阵、非功能需求、验收标准 |
| [研发计划](docs/研发计划.md) | 技术选型论证(Flutter 全家桶)、代码复用策略、仓库结构、里程碑 M0–M5、测试与 CI/CD、风险清单 |

## 一句话概述

原项目把打印机状态画在 ESP32 小屏上;新项目把**同样的监控能力 + 多路摄像头画面(RTSP/ONVIF/萤石/小米/打印机自带相机)**搬到一个 App 里,支持:

- **独立客户端模式**:App 直连打印机与摄像头,无需服务端
- **服务端 + 客户端模式**:常驻 Hub 聚合多打印机/多摄像头,转推低延迟视频流,支持多客户端与远程访问
- **组合监控画面**:打印机状态卡片与摄像头画面自由拼排,适配大屏(桌面/平板/电视)与手机
- **五端覆盖**:Windows / macOS / Linux / Android / iOS

## 当前研发状态(MVP)

| 里程碑 | 状态 |
|---|---|
| M0 协议层(`packages/bambu_protocol`) | ✅ 完成 — 纯 Dart,MQTT/TLS 双模式(LAN `bblp`+访问码 / 云端 `u_{uid}`+Token)、report 全字段解析(AMS/HMS/双喷嘴/风扇/舱门/校准任务识别)、断线指数退避重连、30s 静默 pushall / 90s 强制重连。20/20 测试通过 |
| M1 独立客户端 MVP(`apps/deck`) | ✅ 功能完成 — 打印机网格首页、单机仪表盘(进度环/温度/风扇/AMS/HMS/舱门)、暂停/恢复/停止/速度/腔灯控制、LAN + 云端添加打印机(支持**账号登录**:手机号/邮箱+密码或邮箱验证码,Token 自动填入)、HMS/print_error 错误码句表(拓竹官方错误库,2014+490 条)、安全存储凭据(flutter_secure_storage)。32/32 协议测试 + 6/6 widget 测试通过;**macOS 实机验证 ✅**(2026-10-19,三台 A1 局域网直连,任务/进度/温度实时稳定) |
| M2 摄像头 + 组合布局 | 🔨 核心可用 — media_kit(libmpv)RTSP 实时画面:外部 RTSP/ONVIF 摄像头 + **打印机自带摄像头(全机型)**:A1/A1 mini/P1/P1P 走内置 MJPEG over TLS:6000(纯 Dart 实现,已对 A1 实机验证),X1/P1S/P2S/H2 走 RTSPS:322,按机型自动路由;**单屏监控,双视角自由切换**:打印机视角(左卡片列表内联 暂停/恢复 + 机内画面开关,右侧 = 顶部并排信息行(状态/AMS/设备/报错)+ **相机墙**(按画面数量自动最佳网格铺满一屏,点击单画面放大/缩小))+ 摄像头视角(左摄像头列表含未绑定,右画面+绑定打印机状态卡),窄窗口回退网格+详情页;卡片开关/打开机内摄像头/绑定对话框读写同一份持久化三态,不会不同步;摄像头与打印机**多对多绑定**(机内 1:1);机内摄像头默认加载策略(全局开关 + 单机 跟随全局/开启/关闭 + 会话内手动打开);RTSP 主/子码流一键切换(萤石/海康/大华/TP-Link/Reolink 路径风格);ONVIF 云台(长按 ContinuousMove,需摄像头开启 ONVIF);断流显示错误并支持手动重连;视口外自动停拉(NFR-3);**RTSP 网段自动扫描**(TCP 554/8554/10554 扫段 + DESCRIBE 常见路径探测,海康/大华/萤石等厂商识别,401 也算命中,开放端口诊断);RTSP 强制软解(media_kit_video 0.0.4 在 macOS 丢 VideoToolbox 硬解帧 → 黑屏有声)。注:A1 固件忽略所有摄像头参数 MQTT 写入(实测),码流/云台控制仅面向第三方摄像头。M2 剩余:ONVIF 深度发现、萤石/小米云 API |
| M1 剩余 | Windows/Android 构建验证(Android SDK 未装;Windows 需 VS2022 C++ 工作负载) |
| 已完成跨里程碑项 | 设置中心通知开关/运行日志/配置剪贴板导出导入(FR-10 切片)、打印完成/失败/报错本地通知(FR-7 切片,错误通知带句表句子)、Kiosk 轮播:循环/优先打印中(FR-6 切片)、云端账号登录支持**手机号短信验证码**(sendsmscode)与邮箱验证码双通道 |
| M3 Hub 服务端 | 未开始 |
| M4 全平台 | 未开始 |
| M5 打磨 | 未开始 |

## 快速上手(开发)

环境:Flutter 3.35+(开发机为 3.47.7,`brew install --cask flutter`)。

```bash
# 1. 协议包
cd packages/bambu_protocol
flutter pub get && flutter test

# 2. App
cd ../../apps/deck
flutter pub get
flutter analyze && flutter test

# 3. 运行(桌面)
flutter run -d macos   # 或 windows / linux

# 4. 运行(Android / iOS)
flutter run            # 需 Android SDK / Xcode
```

首次启动为空列表 → 右下角「添加打印机」:

- **局域网直连**:打印机 IP + 序列号 + 局域网访问码(打印机屏幕 设置 → 局域网 可查)
- **Bambu 云端**:区域 + 访问 Token(浏览器登录拓竹后从 cookie/请求头获取;密码登录在 M1 剩余项中)

## 仓库结构

```
BambuDeck/
├── apps/deck/               # Flutter 独立客户端(五端)
│   ├── lib/
│   │   ├── core/            # 主题、格式化
│   │   ├── data/            # 打印机配置(安全存储)、云 API、Riverpod providers
│   │   ├── features/        # home(打印机网格)/ dashboard(单机监控)
│   │   └── ui/              # 进度环、状态徽章、AMS 条、HMS 卡片等通用组件
│   └── test/
└── packages/bambu_protocol/ # 纯 Dart 协议包(不依赖 Flutter,可被 Hub 服务端复用)
    ├── lib/src/             # 模型、report 解析器、MQTT 客户端、云端 API
    └── test/                # 字段级解析测试(真实报文样例)
```
