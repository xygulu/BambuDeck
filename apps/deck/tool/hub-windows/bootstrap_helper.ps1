# helper.json + printers.json 引导 (2026-10-28)
# 从包内 hub.json 派生 service 需要的本地配置; 敏感值只落盘不回显。
#
# 关键: 必须写「无 BOM 的 UTF-8」。PowerShell 5.1 的 Set-Content -Encoding UTF8
# 会带 BOM, Python json.load 遇 BOM 直接炸 → service 启动时读不到 token 就自己
# 生成新的, 与 hub.json 里的对不上, 控制命令全 401 (2026-10-28 实测)。
# 用 .NET WriteAllText + UTF8Encoding($false) 落盘。
#
# 关键 2: 读也要显式 UTF-8。PowerShell 5.1 的 Get-Content 不带 -Encoding 时
# 按系统 ANSI 码页解码, 中文机器上就是 GBK → 把 hub.json 里的 UTF-8 中文
# (打印机名/摄像头名) 解成乱码, 写进 printers.json 后 helper 的
# 「名字↔序列号」映射全乱, 控制链的名字匹配直接失效 (2026-10-29 实测:
# 盒子上 printers.json 的名字已经变成 U+E076 私有区字符)。
# 用 .NET ReadAllText + UTF8Encoding($false) 读, 绕开 ANSI 解码。
$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$h = [System.IO.File]::ReadAllText('C:\deck-hub-windows\config\hub.json', $utf8NoBom) | ConvertFrom-Json
$t = [string]$h.settings.helperToken
New-Item -ItemType Directory -Force -Path (Join-Path $env:USERPROFILE '.bambudeck') | Out-Null
$helper = @{ url = 'http://127.0.0.1:8799'; token = $t }
[System.IO.File]::WriteAllText((Join-Path $env:USERPROFILE '.bambudeck\helper.json'), ($helper | ConvertTo-Json), $utf8NoBom)
$p = @{}
foreach ($x in @($h.printers)) { $p[[string]$x.serial] = @{ name = [string]$x.name } }
[System.IO.File]::WriteAllText((Join-Path $env:USERPROFILE '.bambudeck\printers.json'), ($p | ConvertTo-Json), $utf8NoBom)
Write-Output ("helperToken_set=" + [bool]$t + " printers=" + $p.Count)
