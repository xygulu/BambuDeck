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
- **服务端 + 客户端模式**:常驻 Hub 聚合多打印机/多摄像头,转推低延迟视频流,支持多客户端与远程访问(见下「独立网页服务」)
- **组合监控画面**:打印机状态卡片与摄像头画面自由拼排,适配大屏(桌面/平板/电视)与手机
- **多端覆盖**:macOS / Android / Windows 已打通构建,iOS / Linux 目录就绪待验证

## 当前研发状态

| 里程碑 | 状态 |
|---|---|
| M0 协议层(`packages/bambu_protocol`) | ✅ 完成 — 纯 Dart,MQTT/TLS 双模式(LAN `bblp`+访问码 / 云端 `u_{uid}`+Token)、report 全字段解析(AMS/HMS/双喷嘴/风扇/舱门/校准任务识别)、断线指数退避重连、30s 静默 pushall / 90s 强制重连。20/20 测试通过 |
| M1 独立客户端 MVP(`apps/deck`) | ✅ 功能完成 — 打印机网格首页、单机仪表盘(进度环/温度/风扇/AMS/HMS/舱门)、暂停/恢复/停止/速度/腔灯控制、**一键换盘(内置换盘模型)+ 云端打印/控制 Connect 自动化**(详见下节)、LAN + 云端添加打印机(支持**账号登录**:手机号/邮箱+密码或邮箱/短信验证码,Token 自动填入)、HMS/print_error 错误码句表(拓竹官方错误库,2014+490 条)、安全存储凭据(flutter_secure_storage)。32/32 协议测试 + 6/6 widget 测试通过;**macOS 实机验证 ✅**(2026-10-19,三台 A1 局域网直连,任务/进度/温度实时稳定) |
| M2 摄像头 + 组合布局 | 🔨 核心可用 — media_kit(libmpv)RTSP 实时画面:外部 RTSP/ONVIF 摄像头 + **打印机自带摄像头(全机型)**:A1/A1 mini/P1/P1P 走内置 MJPEG over TLS:6000(纯 Dart 实现,已对 A1 实机验证),X1/P1S/P2S/H2 走 RTSPS:322,按机型自动路由;**单屏监控,双视角自由切换**:打印机视角(左卡片列表内联 暂停/恢复 + 机内画面开关,右侧 = 顶部并排信息行(状态/AMS/设备/报错)+ **相机墙**(按画面数量自动最佳网格铺满一屏,点击单画面放大/缩小))+ 摄像头视角(左摄像头列表含未绑定,右画面+绑定打印机状态卡),窄窗口回退网格+详情页;卡片开关/打开机内摄像头/绑定对话框读写同一份持久化三态,不会不同步;摄像头与打印机**多对多绑定**(机内 1:1);机内摄像头默认加载策略(全局开关 + 单机 跟随全局/开启/关闭 + 会话内手动打开);RTSP 主/子码流一键切换(萤石/海康/大华/TP-Link/Reolink 路径风格);ONVIF 云台(长按 ContinuousMove,需摄像头开启 ONVIF);**萤石 HCNetSDK 私有云台兜底**(PTZ 走 HCNetSDK 8000 端口协议,ONVIF 不可用时自动降级);断流显示错误并支持手动重连;视口外自动停拉(NFR-3);**RTSP 网段自动扫描**(TCP 554/8554/10554 扫段 + DESCRIBE 常见路径探测,海康/大华/萤石等厂商识别,401 也算命中,开放端口诊断);RTSP 强制软解(media_kit_video 0.0.4 在 macOS 丢 VideoToolbox 硬解帧 → 黑屏有声)。注:A1 固件忽略所有摄像头参数 MQTT 写入(实测),码流/云台控制仅面向第三方摄像头。M2 剩余:ONVIF 深度发现、小米云 API |
| M3 Hub 服务端 | 🔨 核心可用 — 独立网页服务(纯 Dart `bin/hub.dart`,AOT 二进制 `deck_hub`,launchd 开机自启),接管 8787 端口:web 控制台(`assets/web/hub_page.html`,手机/平板自适应)、状态快照 `/api/state` + 实时推送 `/ws`、**全部画面帧走单条 `/ws-cam` WebSocket**(与摄像头数无关,手机不再被同源连接名额拖死)、打印控制 `/api/control`、换盘 `/api/plate-swap`、摄像头/云台 `/api/camera` `/api/ptz`、**网页云账号登录(打印机清单从拓竹云动态拉取,不是写死的 json)**、token 鉴权(口令可配);配置读 `~/.bambudeck/hub.json`(App 导出,改了就热重载);远程访问走 Cloudflare 隧道(公网域名 → 8787)。详见下节 |
| M4 全平台 | 🔨 部分 — macOS(本机 `flutter build macos`)、Android(本机 `flutter build apk`,中国网络需镜像 env)、Windows(CI `build.yml` windows-latest)三端构建已打通;iOS / Linux 目录就绪但未进构建/验证环 |
| M5 打磨 | 未开始 |
| 已完成跨里程碑项 | 设置中心通知开关/运行日志/配置剪贴板导出导入(FR-10 切片)、打印完成/失败/报错本地通知(FR-7 切片,错误通知带句表句子)、Kiosk 轮播:循环/优先打印中(FR-6 切片)、云端账号登录支持**手机号短信验证码**(sendsmscode)与邮箱验证码双通道 |

## 独立网页服务(Hub 服务端)

网页端可脱离 GUI App 独立跑——App 关了,手机/平板仍能通过隧道远程看监控、控打印机:

- **入口**:`apps/deck/bin/hub.dart`,纯 Dart(只依赖 `dart:io`/`dart:async`),不依赖 Flutter/riverpod。用 `dart build cli` 编成 AOT 自包含二进制 `~/.bambudeck/bin/deck_hub`(不能用 `dart compile exe`,`objective_c` 包带 build hook)。
- **自启**:`~/Library/LaunchAgents/com.bambudeck.hub.plist`(launchd,RunAtLoad + KeepAlive)。bind 失败即 `exit(1)` 让 KeepAlive 重试;配置变更由进程内 3s 轮询 `hub.json` mtime 触发 `exit(0)` 热重载。
- **配置**:`~/.bambudeck/hub.json`(`settings`/`printers`/`cameras`/`accounts`),由 App 每次配置变更时导出;**口令在 `settings.hubToken`**。独立服务接管 8787,App 内置「网页访问」开关须关闭,否则抢端口。
- **远程访问**:Cloudflare 隧道 `bambu.miller.ink → 8787`,公网可开 web 控制台。
- **画面**:全部摄像头帧走一条 `/ws-cam` WebSocket(全量订阅 + 一帧一 ack),解决 WebKit fetch 读不出长连接 body 导致的整页黑屏。

### 云账号与打印机清单(产品化,2026-10-28)

打印机清单不再是写死的 json,而是**从拓竹云账号动态获取**——新用户第一次起服务,网页上
点「账号」登录,打印机列表自动同步进来:

- **网页登录向导**(`hub_page.html`):区域(中国/国际/欧洲)+ 账号 + 密码(两步验证
  账号改用邮箱/短信验证码,先点「发送验证码」)→ 登录 → 拉取该账号名下设备 →
  落盘。首次启动若既无账号也无打印机,自动弹这个向导。
- **账号管理**:网页右上「账号」面板列出所有账号(打印机数、上次同步时间/失败原因),
  可**暂定**(暂停该账号的同步)、**恢复**、**退出**(移除该账号及其打印机,云端绑定不受影响)。
- **端点**:`POST /api/cloud/login`、`POST /api/cloud/send-code`、`GET /api/accounts`、
  `POST /api/account` `{id, action: suspend|resume|logout}`。
- **定期复查**:活跃账号每 5 分钟拉一次 bind 清单并合并(云端权威:改名/新增/解绑
  跟随云端;本机的 IP、腔灯等偏好保留)。落盘变更触发 3 秒 mtime 重启,新清单生效。
- **归属**:`printerProfile.accountId` 区分「账号带来的打印机」与「手工添加的打印机」
  (空串 = 手工,云同步永不触碰);App 导出 hub.json 时与磁盘合并,两边条目互不覆盖。
- **LAN IP 自动补齐**:云端只给序列号,缺 IP 的打印机启动时由 `_resolveLanIps()` 补:
  先 SSDP 组播(同网段),不通则扫 8883 端口 + 用访问码做 LAN MQTT 认证
  (CONNACK rc=0 即配对成功)——跨网段组播到不了,只有 MQTT 必通。
- **Windows 部署**:CI 产出的 `deck-hub-windows.zip` 自带 `ffmpeg\ffmpeg.exe`
  (第三方 RTSP 摄像头拉流必需,2026-10-28 起不再需要另装);`install-service.bat`
  允许无配置安装(自动生成随机口令的空 config,装完在网页上登录即可)。

配套的 **Connect 控制服务**(`apps/deck/tool/connect_helper/bconnect_service.py`,127.0.0.1:8799)同样由 launchd(`com.bambudeck.helper.plist`)开机自启,驱动 Bambu Connect 客户端完成云端打印/换盘/控制(见下节)。

## 打印控制与一键换盘

控制命令与打印按打印机状态路由:

| 打印机状态 | 暂停/恢复/停止 | 打印 / 一键换盘 |
|---|---|---|
| 局域网 + 开发者模式开 | LAN MQTT 直发(未签名,秒回) | LAN MQTT 直发(未签名) |
| 云模式 / 开发者模式关 | Bambu Connect 自动化 | Bambu Connect 自动化 |

- **一键换盘**: 内置换盘模型(尾段 gcode 把成品震落并送盘)。局域网直连走 FTPS 上传(`FtpsClient`) + `print.project_file`;云端由 Bambu Connect 以拓竹合法客户端身份派单,成功判定 = 点下「发送」(派单成功),不等待打印执行。固件校验的是 3mf 内嵌 `Metadata/plate_1.gcode` 的 md5(常量 `kPlateSwapGcodeMd5`)。
- **开发者模式**: 2025-01 后固件对未签名 `print` 帧回 `84033543`。局域网直发打印/换盘需打印机开「开发者模式」(设置 → 网络 → 仅局域网模式 → 开发者模式 → 启用 → 重启);暂停/恢复/停止不受影响。App 走未签名直发、不加载签名私钥(签名信封在开发者模式关时仍需字段加密 + 装应用证书,是死路)。
- **Bambu Connect 自动化**: 云模式 / dev-OFF 的打印、换盘、暂停/恢复/停止由本机 helper [`apps/deck/tool/connect_helper/`](apps/deck/tool/connect_helper/)(`bconnect_service.py`,127.0.0.1:8799,launchd 自启)驱动 Connect 界面完成 导入 → 打印 → 发送,**默认静默**(不把 Connect 置前,结束后还原焦点);需在 macOS 系统设置 → 隐私与安全性 → 辅助功能 允许 helper 的 python。安装/运行见该目录 [README](apps/deck/tool/connect_helper/README.md)(venv + paho-mqtt + 云端登录态 `creds/cloud_session.json`)。

## 快速上手(开发)

环境:Flutter 3.35+(本机 3.47.7,`brew install --cask flutter`)。

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

# 4. 构建
flutter build macos --release            # macOS
flutter build apk --release              # Android(需 Android SDK;中国网络设 FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn + openjdk@17)
# Windows 走 CI(build.yml windows-latest),本地需 VS2022 C++ 工作负载
```

首次启动为空列表 → 右下角「添加打印机」:

- **局域网直连**:打印机 IP + 序列号 + 局域网访问码(打印机屏幕 设置 → 局域网 可查)
- **Bambu 云端**:账号登录(手机号/邮箱 + 密码,或邮箱/短信验证码,Token 自动填入);也可手动填区域 + 访问 Token

## 仓库结构

```
BambuDeck/
├── apps/deck/               # Flutter App(五端)
│   ├── bin/
│   │   └── hub.dart         # 独立网页服务入口(纯 Dart,AOT deck_hub)
│   ├── lib/
│   │   ├── core/            # 主题、格式化
│   │   ├── data/            # 打印机/摄像头配置(安全存储)、云 API、Riverpod providers、
│   │   │                    #   hub_server(网页服务)/ hub_service / hub_config、
│   │   │                    #   Connect 派单、RTSP 扫描、ONVIF/萤石云台、MJPEG、视觉方案
│   │   ├── features/        # home(打印机网格)/ dashboard(单机监控)/ cameras /
│   │   │                    #   monitor(单屏组合大屏)/ kiosk(轮播)/ printers / settings
│   │   └── ui/              # 进度环、状态徽章、AMS 条、HMS 卡片等通用组件
│   ├── assets/web/          # 网页控制台 hub_page.html(打包进 App / 独立服务共用)
│   ├── tool/
│   │   └── connect_helper/  # 云端打印/控制 helper(Bambu Connect 自动化,Python,launchd 自启)
│   └── test/
└── packages/bambu_protocol/ # 纯 Dart 协议包(不依赖 Flutter,可被 Hub 服务端复用)
    ├── lib/src/             # 模型、report 解析器、MQTT 客户端、云端 API
    └── test/                # 字段级解析测试(真实报文样例)
```
