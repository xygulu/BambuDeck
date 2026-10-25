# DeckShell —— iOS 端只是一个浏览器壳

这个目录里没有打印机逻辑，也不需要：它就是一个 SwiftUI + WKWebView 的
壳，启动后显示 Mac 上 BambuDeck 的网页控制台。暂停、恢复、停止、换盘、
摄像头画面全部发生在 Mac 上，手机只发 HTTP / WebSocket。

```
iPhone (DeckShell)  ──http/ws──►  Mac: BambuDeck app (HubServer :8787)
                                        ├─ LAN MQTT ──► 打印机
                                        └─ bconnect_service.py ──► Bambu Connect
```

这样做的原因：网页已经和 App 用同一套服务端，壳只是把那个页面全屏显示；
改一次网页，Mac、手机、平板同时生效，不用各自发版。

## 在 Mac 上（服务端）

1. 打开 BambuDeck，**设置 → 网页访问**，打开开关（默认端口 8787），
   复制页面上的访问令牌。
2. 确认 Mac 的局域网地址：`ipconfig getifaddr en0`（例如 `192.168.1.10`）。
3. 浏览器访问 `http://<Mac 的 IP>:8787/?token=<令牌>` 能出画面就说明通了。
   打不开时检查 macOS 防火墙是否放行了这个 app。
4. 打印/控制走 Connect 自动化时，还要让 `bconnect_service.py` 跑着
   （见 `apps/deck/tool/connect_helper/README.md`）。

## 在 iPhone 上（壳）

1. `open apps/ios_shell/DeckShell.xcodeproj`
2. Target → Signing & Capabilities → 选自己的 Team（免费 Apple ID 也行）。
3. 手机用数据线连 Mac，选中设备，Run。
4. 首次安装后 iPhone 设置 → 通用 → VPN与设备管理 → 信任开发者证书。
5. 打开 App，填两个地址和访问令牌，点「先测试一下」，通了再「连接」：
   - 局域网地址：和 Mac 同一 Wi-Fi 时用，例如 `192.168.1.10:8787`
   - 外网地址：出门在外时用，例如 `deck.example.com:8787` 或
     `https://xxx.trycloudflare.com`

   两个都填最省事，填一个就固定用它。第一次连接时系统会问「本地网络」权限，
   必须允许。
6. 之后想换服务器/改令牌：点顶部那条窄栏里的地址胶囊（例如 `🌐 外网 deck.example.com`），
   两个地址和令牌都能改，点「保存并重连」立即生效；连不上时中间也会出现「改地址」。
   入口放在页面之上的一条窄栏里、不浮在网页上，所以不会压住摄像头和监控画面。

### 局域网 / 外网自动切换

`ServerRouter.swift` 在启动、换网络（`NWPathMonitor`）、回前台、页面加载失败时
重新选路：两条地址并行发 `GET /api/state`，局域网优先；只要 HTTP 有响应就算通
（401 说明地址通、令牌错）。选中的线路变了，WebView 直接换 URL 重载，页面里的
WebSocket 和摄像头流都跟着换到新线路，不用手动切。

- 冷启动先用上次走通的线路（`deck.server.route`），探测完如果真的换了再重载，
  不会每次开门都白屏 2 秒。
- 蜂窝网络下不探测局域网地址，省掉一次必然超时。
- 两条都不通时停在当前线路，给出具体报错，而不是把用户踢回设置页。

命令行构建（不上真机、只验证能编译）：

```sh
xcodebuild -project apps/ios_shell/DeckShell.xcodeproj -scheme DeckShell \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

打包成可安装的 ipa（Xcode 里已登录 Apple ID 时可用；Team ID 见 Xcode →
Signing & Capabilities）：

```sh
xcodebuild -project apps/ios_shell/DeckShell.xcodeproj -scheme DeckShell \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -archivePath /tmp/DeckShell.xcarchive \
  DEVELOPMENT_TEAM=<TeamID> -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath /tmp/DeckShell.xcarchive \
  -exportPath /tmp/DeckShell-ipa -exportOptionsPlist ExportOptions.plist \
  -allowProvisioningUpdates
```

或者最简单：Xcode 选真机直接 Run。

## 签名与有效期

- 免费 Apple ID：证书 7 天过期，到期重连 Xcode Run 一次；同时最多 3 个自签名 App。
- 付费开发者（$99/年）：证书 1 年，可装到多个设备，也能走 TestFlight。

## 壳里做了什么

| 文件 | 职责 |
| --- | --- |
| `DeckShellApp.swift` | 入口 |
| `ContentView.swift` | 连上后全屏网页；连不上给重试/改地址；顶部窄栏显示当前线路与地址 |
| `WebView.swift` | WKWebView + 加载失败提示 + **JS confirm/alert/prompt 的宿主实现** |
| `ServerConfig.swift` | UserDefaults 里存局域网地址、外网地址和令牌（兼容只有 `base` 的旧配置） |
| `ServerRouter.swift` | 两条线路并行探测、局域网优先，换网络自动重选 |

`WebView.swift` 里的 `WKUIDelegate` 不是可选项：网页的「停止」「一键换盘」
用 `confirm()` 二次确认，不实现这些 delegate 时 `confirm()` 恒为 `false`，
按钮会像点了没反应。

`Info.plist` 里的键也是必需的：

- `NSAppTransportSecurity / NSAllowsLocalNetworking` —— 页面是明文 http。
- `NSAppTransportSecurity / NSAllowsArbitraryLoads` —— 外网地址如果是自建域名的
  明文 http（DDNS + 端口转发，反代没上证书），ATS 会直接拦掉。有 https 的隧道
  （Cloudflare Tunnel、Tailscale Serve）仍然照常用 https，优先选它。
- `NSLocalNetworkUsageDescription` —— iOS 14+ 访问局域网 IP 会弹权限框。
