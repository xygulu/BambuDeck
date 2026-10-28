# BambuDeck 网页服务 — Windows 部署包

整包拷到 Windows 机器(如 `C:\bambudeck`),放一个配置文件,管理员跑一次
`install-service.bat`,完事。之后开机自启、崩溃自动拉起、改配置自动生效,
全程不依赖 Mac 在线。

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
└─ ffmpeg\                        可选:把 ffmpeg.exe 放这里(串流截图用)
```

## 首次部署(三步)

1. **放配置**:从 Mac 把 `~/.bambudeck/hub.json` 拷到本包 `config\hub.json`。
   没有这一步 install 会拒绝执行。hub.json 含打印机访问码和摄像头地址(明文),
   只放本机,别外传。
2. **(可选)装 FFmpeg**:摄像头 JPG→MP4 转码需要。任选其一:
   - `winget install Gyan.FFmpeg`(装进系统 PATH);
   - 或把 `ffmpeg.exe` 直接放进本包 `ffmpeg\` 文件夹(服务脚本已把该目录
     加进 PATH,SYSTEM 账户也生效)。没有 FFmpeg 时网页仍能看实时抓拍,
     只是连续视频流不可用。
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
- **换了 Wi-Fi/网段**:打印机 IP 变了的话,直接改 `config\hub.json` 里对应
  打印机的 `lanIp`,保存即可生效。
