# apply-update.ps1 - 应用已暂存的 hub 自更新 (2026-10-29)
# 由 run-hub.cmd 在 hub.exe 以 42 退出后调用。覆盖式换装:
#   update/pending/* 覆盖包根; config\ logs\ update\ 永不触碰
#   (zip 里本来就没有它们, 覆盖复制不会删额外文件 —— 旧文件残留无害)。
# 换装前把被覆盖的 hub.exe 留一份 update/hub.exe.bak, 出问题可手工回退。
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$pending = Join-Path $root 'update\pending'
if (-not (Test-Path (Join-Path $pending 'hub.exe'))) {
  Write-Output '[update] no staged package, skip'
  exit 0
}
try {
  Copy-Item (Join-Path $root 'hub.exe') (Join-Path $root 'update\hub.exe.bak') -Force
} catch {}
Copy-Item (Join-Path $pending '*') $root -Recurse -Force
Remove-Item $pending -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $root 'update\pending.zip') -Force -ErrorAction SilentlyContinue
$v = ''
try { $v = ((Get-Content (Join-Path $root 'update\stage.json') -Raw | ConvertFrom-Json).version) } catch {}
Write-Output ("[update] applied v" + $v)

# 换装后重新派生 helper.json / printers.json。包里的 bootstrap_helper.ps1
# 可能刚被修好 (2026-10-29: 读 hub.json 之前按 ANSI 解码, 中文名全乱),
# 不重跑一次, 盒子上已有的坏 printers.json 就一直坏下去。
# 失败不阻断更新 —— hub 本身不依赖这两个文件, 只有 helper 依赖。
$bs = Join-Path $root 'bootstrap_helper.ps1'
if (Test-Path $bs) {
  try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $bs | Write-Output
  } catch {
    Write-Output ('[update] bootstrap failed: ' + $_.Exception.Message)
  }
}
