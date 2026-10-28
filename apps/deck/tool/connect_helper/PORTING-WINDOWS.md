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
- **阶段 1**：`bconnect_uia.py` 落地（UIA 遍历 + 打印控件树 dump），在真机上把
  Bambu Connect 的控件树结构摸清楚，确定选择器。
- **阶段 2**：控制（暂停/恢复/停止）跑通 —— 这是最有价值的一环，label 无关的
  desc/几何定位在这里定型。
- **阶段 3**：打印派单（导入 → 打印 → 发送）。deep link 与「导入」交互要重做，
  风险最高，放最后。
- **阶段 4**：调速档位菜单（AX 版靠「LED灯 同行百分比」锚定，Windows 上要找等价锚）。
- **阶段 5**：自启 + 打包成 Windows 部署包的一部分（跟 `deck_hub` 同一个目录）。

## 怎么验

每阶段都在目标 Windows 机器上真机验证：hub 的 `settings.helperUrl` 指向那台机器的
`8799` 端口，网页上点暂停/换盘，看 hub 日志与 helper 的日志。Mac 上现有的 helper
保持可用（两边各服务各的，互不影响）。
