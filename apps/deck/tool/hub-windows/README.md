# BambuDeck 网页服务 — Windows 部署包

整包拷到 Windows 机器(如 `C:\bambudeck`),管理员跑一次
`install-service.bat`,完事。之后开机自启、崩溃自动拉起、改配置自动生效,
全程不依赖 Mac 在线。没有配置也能装:首次安装会生成带随机令牌的空配置,
装完在网页上点「账号」登录拓竹云账号,打印机列表自动同步进来。

## 目录结构

```
deck-hub-windows\
├─ hub.exe                        服务本体(单文件,无依赖)
├─ assets\web\hub_page.html       网页
├─ assets\plate_swap\…            换盘模型
├─ config\hub.json                ★ 配置(含打印机/摄像头/令牌,明文,妥善保管)
├─ logs\hub.log                   运行日志(超 10MB 自动轮转为 hub.old.log)
├─ install-service.bat            ★ 管理员运行:注册服务 + 防火墙 + 立即启动
├─ uninstall-service.bat          管理员运行:停止并注销服务(文件保留)
├─ start.bat / stop.bat / restart.bat   日常启停
├─ run.bat                        前台调试(不经服务,看得到输出)
├─ run-hub.cmd                    守护循环(服务实际入口,一般不用手动跑)
└─ ffmpeg\ffmpeg.exe              已内置:第三方摄像头拉流必需,别删
```

## 首次部署

1. **配置(可选,二选一)**:
   - **新用户**:什么都不用放。install 会生成 `config\hub.json`(含随机访问
     令牌,控制台会打印 `[KEY] Access token: …`,记下来);
   - **老用户(从 Mac 迁移)**:把 `~/.bambudeck/hub.json` 拷到本包
     `config\hub.json`(含打印机访问码和摄像头地址,明文,只放本机,别外传)。
1.5 **(新用户)登录账号**:浏览器开 `http://<这台机器IP>:8787`,输入令牌进
   网页,点右上「账号」→「添加账号」登录拓竹云,打印机自动同步进来。
2. **不用装 FFmpeg**:第三方(海康/萤石等 RTSP)摄像头的画面拉流靠包内
   自带的 `ffmpeg\ffmpeg.exe`(2026-10-28 起随包分发,缺失只会让第三方
   摄像头无画面;拓竹机内摄像头不依赖它)。误删了想补回:
   `winget install Gyan.FFmpeg`,或重新下载一个静态构建放回 `ffmpeg\`。
3. **右键"以管理员身份运行" `install-service.bat`**。它会:
   - 按 `config\hub.json` 里的端口(settings.hubPort,默认 8787)开防火墙入站规则;
   - 注册计划任务 `BambuDeckHub`(SYSTEM 账户,开机 15 秒后自启,不开窗口);
   - 立即启动,然后浏览器开 `http://<这台机器的IP>:8787` 验证。

## 日常操作

| 想做什么 | 做法 |
|---|---|
| 启动 / 停止 / 重启 | 右键"以管理员身份运行" `start.bat` / `stop.bat` / `restart.bat`(任务属 SYSTEM 账户,普通账户无权启停) |
| 改了配置(加打印机、改令牌等) | 直接改 `config\hub.json` 保存,约 3 秒自动重载,无需重启 |
| 看运行日志 | `logs\hub.log`(记事本/VS Code 打开,UTF-8) |
| 升级 hub.exe / 网页 | 拷新文件覆盖后管理员运行 `restart.bat` |
| 彻底移除 | 管理员运行 `uninstall-service.bat`,然后删掉整个文件夹 |
| 排查问题 | 双击 `run.bat` 前台跑(无需管理员),输出直接可见,Ctrl+C 退出 |

## 服务机制

- `run-hub.cmd` 是守护循环:`hub.exe` 退出(崩溃、配置变更、端口短暂被占)
  3 秒后自动重新拉起,所以进程本身不需要"服务化"封装。
- 配置热重载:hub 进程自己盯 `config\hub.json` 的修改时间,变更即退出重启读新配置。
- 账户是 SYSTEM,因此配置必须放在包内(`config\hub.json`),不能放某个用户的
  个人目录——本包已按此设计,`hub.exe` 从不读 `~/.bambudeck`。

## 配置是快照,Mac 改完要重新拷

`config\hub.json` 是从 Mac 拷来的快照:在 Mac App 里加打印机/改令牌后,**不会**
自动同步到这台机器,需要重新拷一次。反过来,在网页上做的修改(摄像头静音等)
会写回本包的 `config\hub.json`,也不会回传 Mac。

## 功能边界(这台机器没有 Mac helper)

| 功能 | Windows 本包 |
|---|---|
| 监控页、打印机列表、AMS、云台、打印状态 | ✓ |
| 暂停 / 继续 / 停止(打印机 dev 开启 LAN 控制的) | ✓(LAN 直发) |
| 调速 | ✓(LAN 直发,结果标注"未确认") |
| dev 关闭 LAN 控制的打印机的控制 | ✗(需 Mac 上的 Bambu Connect 自动化) |
| 网页一键换盘 | ✗(同上) |

## 手机外网访问(可选)

和 Mac 上一样跑一个 cloudflared 隧道指向本机 8787 端口即可,页面/令牌机制不变。
注意隧道断开或窗口被吃满时,网页会显示离线,重启隧道即可。

## 常见问题

- **启动失败/网页打不开**:先看 `logs\hub.log`。端口被占 → 改 `config\hub.json`
  里 `settings.hubPort`,保存(自动重载),再以管理员重跑一次
  `install-service.bat` 让防火墙规则跟上新端口。
- **重新安装系统后任务没了**:重跑 `install-service.bat` 即可,配置还在。
- **网页上中文名字变乱码**(`宇树` 变成 `瀛?鏍?` 这类):配置被当成 GBK
  读进来又按 UTF-8 写回,中文被二次编码了。PowerShell 5.1 的
  `Get-Content` 不带 `-Encoding` 时按系统 ANSI(中文机器=GBK)解码 UTF-8
  文件,正是这个坑。改法:读配置一律显式 UTF-8
  (`[System.IO.File]::ReadAllText($path, (New-Object System.Text.UTF8Encoding($false)))`),
  仓库里的 `bootstrap_helper.ps1` / `install-service.bat` 已改好;如果
  `config\hub.json` 已经坏了,把它换回正常 UTF-8 即可(`printers.json`
  同理,重跑 `bootstrap_helper.ps1` 重新派生)。
- **换了 Wi-Fi/网段**:打印机 IP 变了的话,直接改 `config\hub.json` 里对应
  打印机的 `lanIp`,保存即可生效。
- **自更新下载失败**(日志里 `[更新] 下载失败`):国内网络对 GitHub Release
  的资产站是半通的 —— `api.github.com` 正常,但 302 到的
  `release-assets.githubusercontent.com` TLS 握手直接被掐(盒子实测:
  `curl` 报 `schannel: failed to receive handshake`)。hub 会自动换
  `ghfast.top` / `gh-proxy.com` 前缀镜像再试,内容仍按 `version.json` 里的
  sha256 校验,对不上就删掉放弃。镜像都挂了就先手工把 `deck-hub-windows.zip`
  拷到机器上解压覆盖(保留 `config\` `logs\` `update\`)。
