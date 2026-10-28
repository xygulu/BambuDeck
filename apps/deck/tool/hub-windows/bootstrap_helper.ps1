# helper.json + printers.json 引导 (2026-10-28)
# 从包内 hub.json 派生 service 需要的本地配置; 敏感值只落盘不回显。
#
# 关键: 必须写「无 BOM 的 UTF-8」。PowerShell 5.1 的 Set-Content -Encoding UTF8
# 会带 BOM, Python json.load 遇 BOM 直接炸 → service 启动时读不到 token 就自己
# 生成新的, 与 hub.json 里的对不上, 控制命令全 401 (2026-10-28 实测)。
# 用 .NET WriteAllText + UTF8Encoding($false) 落盘。
$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$h = Get-Content C:\deck-hub-windows\config\hub.json -Raw | ConvertFrom-Json
$t = [string]$h.settings.helperToken
New-Item -ItemType Directory -Force -Path (Join-Path $env:USERPROFILE '.bambudeck') | Out-Null
$helper = @{ url = 'http://127.0.0.1:8799'; token = $t }
[System.IO.File]::WriteAllText((Join-Path $env:USERPROFILE '.bambudeck\helper.json'), ($helper | ConvertTo-Json), $utf8NoBom)
$p = @{}
foreach ($x in @($h.printers)) { $p[[string]$x.serial] = @{ name = [string]$x.name } }
[System.IO.File]::WriteAllText((Join-Path $env:USERPROFILE '.bambudeck\printers.json'), ($p | ConvertTo-Json), $utf8NoBom)
Write-Output ("helperToken_set=" + [bool]$t + " printers=" + $p.Count)
