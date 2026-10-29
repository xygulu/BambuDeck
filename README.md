# BambuDeck

拓竹(Bambu Lab)打印机 + 摄像头的多平台监控与控制套件。一块屏幕看所有打印机和摄像头,
手机/平板通过网页远程查看和控制;支持一键换盘、云端打印派单、AI 视觉值守。

- **客户端模式**:App 直连打印机与摄像头,无需服务端
- **Hub 服务端模式**:常驻服务聚合多打印机/多摄像头,手机/平板开网页即用,支持公网远程访问
- **多端覆盖**:macOS / Windows / Android 客户端;iOS 等其它设备走网页端

> 本项目由 [BambuHelper](../BambuHelper)(ESP32 小屏固件)改造而来,是全新的独立项目。

## 功能一览

**打印机监控与控制**
- 多机同屏:打印机网格首页,单机仪表盘(进度环/温度/风扇/AMS 耗材/HMS 报错/舱门)
- 打印控制:暂停 / 恢复 / 停止 / 打印速度 / 腔灯
- 一键换盘:内置换盘模型(打印完成前自动把成品震落并送新盘),打印中也能换
- 云端打印派单:向云账号名下的打印机发送打印任务
- 错误可读:HMS/print_error 错误码对照拓竹官方错误库(2500+ 条),报错说人话
- 打印完成/失败/报错本地通知(macOS);Kiosk 轮播模式(大屏自动轮播,优先显示打印中)

**摄像头监控**
- 支持打印机自带摄像头(A1/A1 mini/P1/P1P MJPEG;X1/P1S 等走 RTSPS)+ 任意 RTSP 摄像头
  (海康/大华/萤石/TP-Link/Reolink 等路径风格自适应,主/子码流一键切换)
- 打印机与摄像头多对多绑定;相机墙按画面数量自动最佳网格;单画面放大
- ONVIF 云台;萤石设备 ONVIF 不可用时自动降级 HCNetSDK 私有协议
- RTSP 网段自动扫描(填 IP 就能发现摄像头)

**AI 视觉值守(可选)**
- 接任意 OpenAI/Anthropic 兼容的视觉大模型,定时判读打印画面:发现异常可推送通知,
  甚至自动暂停打印(需打印机可控)

**网页端(Hub 模式)**
- 手机/平板浏览器直接开网页:看状态、看画面、暂停/换盘,自适应竖屏
- 云账号网页登录:输账号密码(或验证码),打印机清单自动从拓竹云同步
- 公网远程:配合 Cloudflare 隧道,出门也能看

**版本更新**
- 全自动检查(hub 每 6 小时、App 启动后及每 12 小时),发现新版:网页顶部出提示条、
  App 弹提醒;**装不装由你确认**——Android 一键下载安装,Windows 部署包一键换装,
  其它平台给下载页

## 下载

到 [Releases](https://github.com/xygulu/BambuDeck/releases/latest) 下载:

| 文件 | 用途 |
|---|---|
| `deck-android.apk` | Android 客户端,直接安装 |
| `deck-macos.zip` | macOS 客户端,解压拖进「应用程序」 |
| `deck-hub-windows.zip` | Windows 部署包(Hub 服务端 + Connect 派单 helper + ffmpeg) |

## 部署

### 方式一:客户端直连(最简单)

1. 安装并打开 App(上表 apk / macos.zip)
2. 右下角「添加打印机」:
   - **局域网直连**:填打印机 IP + 序列号 + 局域网访问码(打印机屏幕:设置 → 局域网 可查)
   - **拓竹云端**:账号登录(手机号/邮箱 + 密码,或验证码),打印机自动同步进来
3. 完事。摄像头在「摄像头」页添加(RTSP 地址,或直接开打印机自带摄像头)

### 方式二:Hub 服务端(推荐给盒子/NAS 常驻)

App 关了监控也不停,手机随时开网页看:

1. 下载 `deck-hub-windows.zip` 解压到任意目录(如 `C:\deck-hub-windows`),双击
   `install-service.bat`:注册计划任务开机自启,自动生成随机访问口令
2. 浏览器开 `http://<本机IP>:8787`,输入口令(在包目录的 `config\hub.json` 里
   `settings.hubToken`)进入
3. 网页右上「账号」登录拓竹账号 → 打印机清单自动同步;再添加摄像头即可
4. **公网访问(可选)**:装 [cloudflared](https://developers.cloudflare.com/cloudflare/one-connections/tunnels/)
   把隧道指到 `http://localhost:8787`,绑定自己的域名,手机在外网直接开

macOS 用户:直接用 App 内置的「网页访问」开关(设置里)即可起同样的网页端;
进阶玩法(独立 AOT 服务 + launchd 自启)见下文「开发」与 [独立网页服务](#独立网页服务hub-服务端)一节。

## 使用前提(重要)

| 需求 | 说明 |
|---|---|
| 打印机联网 | 局域网模式需打印机与 App/Hub 在同一网络(跨网段也可以,自动扫 8883 发现) |
| 局域网访问码 | 打印机屏幕:设置 → 局域网 → 访问码 |
| **开发者模式**(仅局域网直发打印/换盘需要) | 打印机屏幕:设置 → 网络 → 仅局域网模式 → 开发者模式 → 启用后重启。2025 年后的固件对未签名打印指令一律拒绝,不开就只能走云 |
| **Bambu Connect**(云模式打印/换盘/控制) | 本机安装 [Bambu Connect](https://bambulab.com/en/support/download) 并登录**同一拓竹账号**。helper 会自动化它的界面完成派单:macOS 需在 系统设置 → 隐私与安全性 → 辅助功能 里放行;Windows 部署包已内置 helper,装完即用 |
| 第三方摄像头 RTSP | 摄像头开启 RTSP/ONVIF;云台需 ONVIF(或萤石 + 开放 8000 端口) |
| ffmpeg | 仅第三方 RTSP 摄像头拉流用;Windows 部署包已内置,其它平台 media_kit 自带 |
| 视觉大模型(可选) | 任一 OpenAI/Anthropic 兼容的视觉接口。App 设置 → 视觉监控:填 Base URL + API Key + 模型名。例:Base URL `https://api.minimaxi.com/anthropic`,模型 `MiniMax-M3` |

控制/打印按打印机状态自动路由:

| 打印机状态 | 暂停/恢复/停止 | 打印 / 一键换盘 |
|---|---|---|
| 局域网 + 开发者模式开 | LAN MQTT 直发(秒回) | LAN MQTT 直发 |
| 云模式 / 开发者模式关 | Bambu Connect 自动化 | Bambu Connect 自动化 |

## 日常使用

- **看**:首页打印机卡片(进度/温度/AMS 实时刷新)、「监控」单屏组合大屏(打印机状态 +
  相机墙,电视/平板友好)、「Kiosk」轮播
- **控**:卡片上直接 暂停/恢复/停止;详情页调速度、开关腔灯;网页端同样可操作
- **换盘**:打印中点「一键换盘」,自动上传换盘模型并派单,打完自动换色
- **云端打印**:选 3mf → 发送到云账号名下的任意打印机
- **AI 值守**:设置 → 视觉监控 开启,选摄像头、设间隔;发现喷打空/堵料等异常可推送,
  勾选「自动暂停」则直接暂停打印机

## 版本更新机制

- 检查全自动:Hub 后台每 6 小时查一次 GitHub Releases,App 启动后 8 秒和每 12 小时各查一次
- 发现新版:网页顶部出常驻提示条(点「查看更新」进服务状态面板),App 弹「发现新版本」对话框
- **安装需人工确认**:
  - Android:对话框里点「下载并安装」(系统安装器接管)
  - Windows Hub:服务状态面板点「立即更新」,自动下载→校验 sha256→换装重启(几秒)
  - macOS/其它:给下载页链接,手动替换
- 下载件一律 sha256 校验,不符即弃(fail-closed)

## 独立网页服务(Hub 服务端,进阶)

- **入口**:`apps/deck/bin/hub.dart`,纯 Dart。用 `dart build cli` 编成 AOT 自包含二进制
  (不能用 `dart compile exe`,`objective_c` 包带 build hook)。exe 旁放 `version.txt`
  写当前版本号,自更新检查才准。
- **自启(macOS)**:`~/Library/LaunchAgents/com.bambudeck.hub.plist`(RunAtLoad + KeepAlive)。
  配置变更由 `hub.json` mtime 轮询触发热重载。
- **配置**:`~/.bambudeck/hub.json`(`settings`/`printers`/`cameras`/`accounts`),
  由 App 配置变更时导出;**口令在 `settings.hubToken`**。独立服务接管 8787 时,
  App 内置「网页访问」开关须关闭,否则抢端口。
- **画面**:全部摄像头帧走单条 `/ws-cam` WebSocket(与摄像头数无关),
  iOS Safari 也不会被同源连接数限制拖死。
- **账号同步**:活跃账号每 5 分钟复查一次 bind 清单并合并(云端权威;本机 IP/偏好保留)。
  云端只给序列号,缺 IP 的打印机会自动扫 8883 端口 + 访问码做 MQTT 认证补齐。

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
flutter build macos --release --dart-define=DECK_VERSION=X.Y.Z
flutter build apk --release --dart-define=DECK_VERSION=X.Y.Z
#   中国网络:FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
#   PUB_HOSTED_URL=https://pub.flutter-io.cn;Android 需 openjdk@17
# Windows 走 CI(.github/workflows/build.yml,windows-latest)

# 5. 独立 hub 二进制
dart build cli -o <输出目录>   # 产物 bundle/bin/hub,旁置 version.txt
```

打 tag `vX.Y.Z` 推送即触发 CI:三平台构建 + 发布 Release + 生成 `version.json`
清单(含各资产 sha256,自更新链路的信任根)。

## 仓库结构

```
BambuDeck/
├── apps/deck/               # Flutter App(五端)
│   ├── bin/
│   │   └── hub.dart         # 独立网页服务入口(纯 Dart,AOT deck_hub)
│   ├── lib/
│   │   ├── core/            # 主题、版本、镜像下载
│   │   ├── data/            # 打印机/摄像头配置(安全存储)、云 API、Riverpod providers、
│   │   │                    #   hub_server(网页服务)/ hub_update(自更新)、
│   │   │                    #   Connect 派单、RTSP 扫描、ONVIF/萤石云台、MJPEG、视觉方案
│   │   ├── features/        # home(打印机网格)/ dashboard(单机监控)/ cameras /
│   │   │                    #   monitor(单屏组合大屏)/ kiosk(轮播)/ printers / settings
│   │   └── ui/              # 进度环、状态徽章、AMS 条、HMS 卡片等通用组件
│   ├── assets/web/          # 网页控制台 hub_page.html(打包进 App / 独立服务共用)
│   ├── tool/
│   │   └── connect_helper/  # 云端打印/控制 helper(Bambu Connect 自动化,Python)
│   └── test/
└── packages/bambu_protocol/ # 纯 Dart 协议包(不依赖 Flutter,可被 Hub 服务端复用)
    ├── lib/src/             # 模型、report 解析器、MQTT 客户端、云端 API
    └── test/                # 字段级解析测试(真实报文样例)
```

## 文档

| 文档 | 说明 |
|---|---|
| [需求文档(PRD)](docs/需求文档-PRD.md) | 产品定位、双模式架构、完整功能需求、平台矩阵、验收标准 |
| [研发计划](docs/研发计划.md) | 技术选型论证、里程碑 M0–M5、测试与 CI/CD、风险清单 |
| [Connect helper](apps/deck/tool/connect_helper/README.md) | 云端打印/控制的自动化服务安装与运行 |
