# helper.json + printers.json 引导 (2026-10-28; 2026-10-29 改用 Python)
# 从包内 hub.json 派生 service 需要的本地配置; 敏感值只落盘不回显。
#
# 为什么改成调 Python 而不是直接用 PowerShell 读写:
#   PowerShell 5.1 的 Get-Content 不带 -Encoding 时按系统 ANSI 码页解码,
#   中文机器上就是 GBK → 把 hub.json 里的 UTF-8 中文 (打印机名/摄像头名)
#   解成乱码, 写进 printers.json 后 helper 的「名字↔序列号」映射全乱,
#   控制链的名字匹配直接失效 (2026-10-29 实测: 盒子上 printers.json 的
#   名字已经变成 U+E076 私有区字符)。
#   派生逻辑挪到 helper\bootstrap_local_conf.py: 编码显式, 还能离线自测。
#
# 这个脚本现在只负责: 找到目标机上的 python runtime, 把脚本调起来。
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path $root 'helper\bootstrap_local_conf.py'
$hub = 'C:\deck-hub-windows\config\hub.json'

$py = Join-Path $root 'runtime\python\python.exe'
if (-not (Test-Path $py)) {
  Write-Output ('[bootstrap] python runtime not found: ' + $py)
  exit 1
}
if (-not (Test-Path $script)) {
  Write-Output ('[bootstrap] script not found: ' + $script)
  exit 1
}
& $py $script $hub
exit $LASTEXITCODE
