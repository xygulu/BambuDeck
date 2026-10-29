# 把 connect_helper 移植到 Windows

macOS 版的 helper 驱动 **Bambu Connect 官方客户端**的界面做云端派单与控制。Windows
版还没做 —— 这份文档写清楚要做什么、怎么做、卡在哪。

## 为什么要它

Windows 那台机器上只有 `deck_hub`(纯 Dart 网页服务)，没有 Bambu Connect 自动化，
所以这两件事做不了：

- **云模式 / 开发者模式关** 的打印机的暂停/恢复/停止（固件拦 LAN 直发，84033543）
- **云模式** 的打印派单与一键换盘（云端打印机没有可达的 FTP 端点）

局域网 + **固件明确报告开发者模式开** 的打印机不受影响：控制走 LAN MQTT，
一键换盘可走纯协议捷径（FTPS 上传 + MQTT 派发，`hub_service._plateSwap` 的
`lan-ftps` 分支）。状态读不出来（A1 固件不报 `print.fun`）**不赌，默认走
Connect** —— 签名问题 MQTT 绕不过去。

## 前置条件（缺一不可，机器到位才能开工）

1. **远程通道**：目标 Windows 机器上装 OpenSSH Server 并开放管理员登录
   （Windows 的 OpenSSH 用 `administrators_authorized_keys` 而不是用户目录下的
   `authorized_keys`，且要修好继承权限，否则服务读不到公钥）。
2. **Bambu Connect Windows**：装好并人工登录一次（helper 复用它的登录态）。
3. **交互式桌面会话**：helper 要操控界面，服务必须跑在有桌面会话的账户下
   （Windows 服务跑在 Session 0，看不到界面 —— 所以 helper 不能注册成 Windows
   Service，只能挂「登录后启动」的计划任务/启动项）。

## 技术映射

| macOS 版 | Windows 版 | 说明 |
|---|---|---|
| `bconnect_ax.py`（JXA + AX 树） | 新增 `bconnect_uia.py`（pywinauto，backend="uia"） | 遍历/点击控件树的底层 |
| `bconnect_axfast.py`（ctypes 快路径） | pywinauto 的 `descendants()` + 缓存 | Windows 上没有 AX 树快照可截，改用 UIA 属性遍历 |
| `bconnect_drive.py`（控制/调速） | 复用上层逻辑，换底层定位器 | 打印机匹配（正则打注册表+云端 device_list）是纯 Python，跨平台 |
| `bconnect_print.py`（导入/发送） | 需重做 deep link 与「导入」交互 | deep link 的 scheme 与 Windows 客户端是否一致**待验证** |
| `bconnect_cloud.py` | **原样复用** | 云登录态、设备注册表、云 MQTT 状态、任务匹配，全是纯 Python |
| `bconnect_service.py`（HTTP 服务） | **原样复用** | 127.0.0.1:8799 的路由层与平台无关 |
| `bconnect_vision.py` | **原样复用** | 云端视觉兜底 |
| `ocr_text.swift`（macOS Vision OCR） | 换成 Windows OCR / 纯截图 + 云视觉 | macOS 版用它读发送页下拉里的机名 |
| `launchd` 自启 | 计划任务（登录时触发，交互式账户） | 不能用 SYSTEM 服务，见前置条件 3 |

依赖：`requirements-win.txt` = `paho-mqtt` + `pywinauto` + `comtypes`。

## 选择器：最大的坑

macOS 版靠**中文标签**定位控件（「跳过」是锚、控制图标是空 label + 28~32×30~34
尺寸 + 与「跳过」同一 y）。Windows 上 Bambu Connect 的界面语言未知，标签不能假设。

移植时的原则（照 macOS 快路径那套的思路）：

1. **优先 desc / AutomationId**：Electron 在 Windows 上暴露 UIA，控件的 `desc`
   通常是英文语义标识（如 `confirm`/`cancel`），与界面语言无关 —— macOS 版 stop
   的二次确认框就是靠 desc=`confirm` 识别的，这套能直接搬。
2. **几何兜底**：空 label 的图标按钮按尺寸 + 同行 + x 排序识别（同 macOS 快路径）。
3. **不要依赖标题**：AX 树在 macOS 上懒加载会掏空，Windows UIA 同样不可靠；
   标题只能当辅助信息。
4. **视觉兜底**：实在找不到就走 `bconnect_vision.py`（云端视觉），慢但通用。

## 分阶段

- **阶段 0（已做）**：hub 侧把换盘路由定死为「默认 Connect，确认开发者模式开
  才直发」—— Windows 上 helper 是必需品，不再是可选项。
- **阶段 1（已做，2026-10-28）**：`bconnect_uia.py` 落地。真机摸清的结构：
  - **会话隔离是硬约束**：SSH/服务进程（session 0）看不到桌面窗口，UIA 必须
    跑在交互会话里 → 用「登录时触发 + /it」的计划任务挂 helper（不能用服务）。
  - 主窗口 `Chrome_WidgetWin_1`，标题 `Bambu Connect (Beta)`；主页即设备列表，
    列表标记 = Text `设备名称`；卡片 = Hyperlink `<名> 热床: ..`。
  - 详情页标记 = Text `打印进度` + 面包屑；**打印中**才渲染控制行：
    Button `跳过` 锚点 + 同行（y±6, 高 24..40）两个**无名图标按钮**，x 序 =
    [暂停(绿⏸), 停止(红■)]，截图放大可肉眼复核。
  - 停止二次确认框结构**未验证**（需要一次真实打印中的停止）；
    `press_desc('confirm')` 会兜底找 确定/确认/OK 并打日志列候选。
- **阶段 2（已真机验证，2026-10-28）**：`bconnect_uia.py` 顶替
  `bconnect_ax` 接口（drive/service/print 上层零改动）；service 在目标机
  `127.0.0.1:8799` 跑通（守护循环 + 登录自启任务，`/health` 全绿：
  app_running/uid_resolved）。**真实打印中暂停已打通**：hub 同款
  `POST /command {serial, command: pause}` 全链路 4.56s 点击成功，
  云端交叉确认 `gcode_state=PAUSE`。Windows 适配点：`app_running` 走
  tasklist、`ensure_app` 走 exe 直启、`/health` 对缺失子系统安全降级、
  helper.json 与 printers.json 由引导脚本（`tool/hub-windows/bootstrap_helper.ps1`）
  从包内 hub.json 派生。真机暴露并已修复的坑：
  1. **PowerShell 导出带 BOM**：`Set-Content -Encoding UTF8` 写的 helper.json
     带 BOM，`json.load` 直接炸 → service 重新生成 token → 与 hub.json 里的
     对不上，控制命令全 401。bootstrap 用 .NET `WriteAllText` 无 BOM 落盘，
     service 读配置用 `utf-8-sig`。
  2. **401 前 body 不排空**：POST 校验失败直接 close，TCP 发 RST 把错误响应
     从客户端缓冲冲掉，Dart 端看到「Connection closed while receiving data」
     而不是 401 原文。do_POST 在 401 路径先 `rfile.read(n)` 排空。
  3. **Connect 窗口最小化**：UIA IsOffscreen=True、几何 -32000、Chromium 降级
     a11y 树（全树遍历 20s+，控制流程耗尽看门狗）。find_window 遇最小化
     主窗口先 `ShowWindow(SW_RESTORE)` 再用；还原后全树遍历 <0.5s。
  4. **标记/卡片名匹配**：列表头实为「设备名称 ↑」（probe 需子串匹配）；
     卡片文本是「<名> 状态」拼接（点击名需 startswith 兜底）。
  5. **视觉兜底截图**：`screencapture` 是 macOS 命令，Windows 走 PIL ImageGrab。
  另：pywinauto `UIAWrapper` 没有 `is_iconic/restore`，直接 ctypes user32。
- **阶段 3（真机已验证，2026-10-28）**：打印派单（导入 → 打印 → 发送）打通。
  弹窗正文不进 UIA 树 → 截图 + MiniMax 视觉核对，fail-closed；二按「打印」
  Invoke 哑火 → 改鼠标点中心；弹窗链 = 导入确认 → 回选项页 → 重按 →
  发送弹窗（发送 = confirm）。真机 32s。
- **阶段 4（真机已验证，2026-10-28/29）**：调速档位菜单打通。菜单是 antd
  Dropdown，Esc 关不掉（点「打印进度」标题才收）。**UI 百分比滞后 9-20s**，
  所以确认走局域网状态帧的 `spd_lvl`（权威），界面 % 只作参考。
- **阶段 5（已完成）**：目标机挂了 `BambuDeckHelper`（登录自启 + 守护循环），
  helper 源码与看护脚本都进了 deck-hub-windows 部署包（嵌入式 Python 在
  `runtime\python\`，依赖 paho-mqtt/pywinauto/comtypes/requests/pillow）。

### 控制链的 OCR 化（2026-10-29）

Connect 的 Chromium 窗口在 Windows 上**会掏空 AX 树**（文本层懒加载，
读出来是空的），树一空 AX 版代码就一路降级到视觉模型 → MiniMax 429
「tokenplan 用量不足」直接报给用户。所以控制链改成**截图即真相**：

| 操作 | 锚点 |
|---|---|
| 详情页判断 | 「打印进度」标题 |
| 机器名 | 卡片文本 `_name_score >= 0.8` |
| 状态 | 状态行「打印中 / 已暂停」 |
| 进度 % | 进度 % 锚点（`%` + (122,-47) = 暂停，+ (162,-47) = 停止） |
| 调速触发器 | 「LED灯」行左边的速度百分比 |
| 调速菜单 | 触发器下方区域 zoom 2.5x 重读（2 字档位名全屏 OCR 有漏读） |

zh-Hans OCR 的两个坑：绿色进度 `%` **有时整个符号丢掉**（只出「44」），
**有时出全角「％」** → 统一用 `re.fullmatch(r"\d{1,3}\s*[%％]?", text)` 收。
小 CJK 会退化成偏旁部首，所以关键文本要 zoom 2.5x 重读。

配套的离线自测（不需要 Windows/Connect/真机）：
`test_ocr_speed.py`（调速锚点与坐标换算）、`test_name_match.py`（机名匹配）、
`../hub-windows/helper/test_bootstrap_local_conf.py`（本地配置派生）。

### Windows 上的中文编码坑（2026-10-29）

PowerShell 5.1 的 `Get-Content` 不带 `-Encoding` 时按**系统 ANSI 码页**解码
（中文机器 = GBK）→ 把 UTF-8 文件里的中文读成乱码，再以 UTF-8 写回就是
**二次编码**。盒子上 `config\hub.json` 的摄像头名（宇树/萤石/嘉兴）就是这么
坏的，网页上显示成乱码；`bootstrap_helper.ps1` 派生的 `printers.json` 里
打印机名更糟，成了 U+E076 私有区字符。

规矩：
- PowerShell 读文件一律显式 UTF-8（`[System.IO.File]::ReadAllText($p, (New-Object System.Text.UTF8Encoding($false)))`）；
- Python 的 `open()` 一律带 `encoding=`（Windows 默认也是 ANSI）；
- 派生逻辑尽量写在 Python 里（可离线自测），PowerShell 只负责调它。

## 怎么验

每阶段都在目标 Windows 机器上真机验证：hub 的 `settings.helperUrl` 指向那台机器的
`8799` 端口，网页上点暂停/换盘，看 hub 日志与 helper 的日志。Mac 上现有的 helper
保持可用（两边各服务各的，互不影响）。
