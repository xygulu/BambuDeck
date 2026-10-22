# connect_helper —— Bambu Connect 云端打印/控制 helper

macOS 上的本机 Python 服务,驱动 **Bambu Connect**(拓竹官方客户端)的界面完成云端派单与
暂停/恢复/停止控制。App(`apps/deck`)在「云模式 / 开发者模式关」时,把打印、一键换盘和
控制命令转给这里的 `bconnect_service.py`(127.0.0.1:8799)。

为什么不直接调云端 API:直接建打印任务只能拿到 `status=1`(永不下发);让 Connect 以自己
的合法客户端身份派单才能拿到 `status>=3`(打印机真执行)。

## 文件

| 文件 | 作用 |
|---|---|
| `bconnect_service.py` | HTTP 服务入口(127.0.0.1:8799),命令路由 + LAN MQTT 兜底控制 |
| `bconnect_print.py` | 打印/换盘驱动:deep link → 导入 → 打印 → 发送 |
| `bconnect_drive.py` | 暂停/恢复/停止驱动:正则匹配打印机 + AX 定位控制按钮 |
| `bconnect_ax.py` | JXA 无障碍遍历(AX)底层:短路 `probe`、按文字/desc/坐标点击 |
| `bconnect_cloud.py` | 云端共享层:登录态、设备注册表、云 MQTT 状态、任务匹配 |
| `bconnect_vision.py` | 多供应商视觉/文本模型接入(Connect 控制按钮 AX 找不到时的兜底) |

## 安装

```bash
cd apps/deck/tool/connect_helper
python3 -m venv .venv
./.venv/bin/pip install -r requirements.txt    # 只装 paho-mqtt
```

> 服务脚本依赖 `paho.mqtt.client`,用 `.venv/bin/python` 跑,别用系统 `python3`
> (系统很可能没装 paho)。

## 前置条件

1. **Bambu Connect** 已安装且已登录(`/Applications/Bambu Connect.app`),首次需人工登录一次。
2. **辅助功能权限**:系统设置 → 隐私与安全性 → 辅助功能,允许运行 helper 的 python
   (即 `.venv/bin/python`)。
3. **云端登录态**:把浏览器登录拓竹后拿到的 token 写到
   `creds/cloud_session.json`(本目录下,已被 `.gitignore` 忽略),格式:
   ```json
   {"accessToken": "…"}
   ```
   也可用环境变量 `BAMBU_SESSION=/path/to/session.json` 覆盖路径。
4. **局域网控制**(可选,dev-ON 直发):`~/.bambudeck/printers.json` 里配
   `serial -> {ip, name}`;访问码从云端注册表运行时取,不写死。
5. **视觉兜底**(可选,控制按钮 AX 找不到时):`~/.bambudeck/models.json` 配
   `{"vision": {"provider": "minimax", "base_url": "…", "api_key": "…", "model": "MiniMax-M3"}}`
   (key 只写本地、0600、不落仓库)。

## 运行

```bash
cd apps/deck/tool/connect_helper
./.venv/bin/python bconnect_service.py       # 监听 127.0.0.1:8799
```

环境变量:

- `BAMBU_SESSION` — 云端登录态文件路径(默认本目录 `creds/cloud_session.json`)。
- 打印/换盘**默认静默**:deep link 用 `open -g` 后台打开、跳过 activate,并在**导入弹窗出现后 /
  点完发送后立刻**把焦点压回用户原来的 app(不是等到整个流程结束)。控制路径本就静默
  (AXPress 后台点按钮)。要回到旧前台行为(Connect 全程置前、结束才还原焦点)设 `BAMBU_SILENT=0`。

接口(请求头带 `X-Deck-Token`,token 持久化在 `~/.bambudeck/helper.json`):

- `GET  /health` → `{ok, busy, app_running, uid_resolved}`
- `POST /command` `{serial, command, params}`
  - `command=print`  `params={file, filament?, stop_before_send?}` — 导入 → 打印 → 发送
  - `command=pause|resume|stop` — Connect 自动化,失败退回 LAN MQTT
  - `command=status` — 云 MQTT 只读快照

打印成功判定 = **点下「发送」即算成功**(Connect 已派单),不等发送页离开/任务落库/打印执行
——换盘本身需要一段时间,等 RUNNING 是多余阻塞。派单后立即返回、释放服务端 busy 锁,
用户可马上再下停止/暂停等控制。

## 安全

- 只监听 127.0.0.1;请求用 `X-Deck-Token` 校验。
- 访问码 / token / uid / 模型 key 全部运行时从 `~/.bambudeck/*` 或云端取,仓库里不存任何凭证。
