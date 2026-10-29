# Connect helper 看护 (2026-10-29)
# 计划任务 BambuDeckHelper: 登录时 + 每 5 分钟触发本脚本 (无执行时限)。
# 职责 (只拉起, 不杀进程, 幂等可重复跑):
#   1. helper (127.0.0.1:8799) 没监听 -> 拉起守护 bat (bat 自带端口守卫,
#      多实例安全)
#   2. 用户会话被 RDP 断开 (Disc) -> tscon 挂到 rdp-tcp 监听保活: 断开的
#      会话没有虚拟桌面, UIA 点击/截屏会失效; 保活后照常可用, 重启后
#      自动登录的 console 会话 + 任何 RDP 接管/断开都不影响 helper
#   3. Bambu Connect 没跑 -> 预热拉起 (首个控制命令免冷启动)
# 路径全部相对本文件, 不写死安装目录。
$ErrorActionPreference = 'Continue'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path $dir 'watch.log'

function Log($m) {
  try {
    Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format 'MM-dd HH:mm:ss'), $m) -Encoding UTF8
  } catch {}
}

# ---- 1) helper 端口
$listen = $false
try {
  $listen = $null -ne (netstat -ano | Select-String '127.0.0.1:8799\s+.+LISTENING')
} catch {}
if (-not $listen) {
  Log 'port 8799 dead -> start helper_service.bat'
  try {
    Start-Process -FilePath (Join-Path $dir 'helper_service.bat') -WorkingDirectory $dir -WindowStyle Hidden
  } catch { Log ('start bat fail: ' + $_.Exception.Message) }
}

# ---- 2) 会话保活 (RDP 断开后把会话挂回 rdp-tcp 监听)
try {
  $q = qwinsta 2>$null
  foreach ($line in ($q | Where-Object { $_ })) {
    $t = @(($line -split '\s+') | Where-Object { $_ })
    $i = [Array]::IndexOf($t, $env:USERNAME)
    if ($i -lt 0 -or $t.Count -lt ($i + 2)) { continue }
    $id = $null
    for ($j = $i + 1; $j -lt $t.Count; $j++) {
      if ($t[$j] -match '^\d+$') { $id = $t[$j]; break }
    }
    $isDisc = ($t -contains 'Disc')
    if ($isDisc -and $id) {
      Log ("session " + $env:USERNAME + " Disc id=" + $id + " -> tscon keepalive")
      $out = tscon $id /dest:rdp-tcp 2>&1
      Log ('tscon -> ' + ($out -join ' '))
    }
  }
} catch { Log ('session check error: ' + $_.Exception.Message) }

# ---- 3) Connect 预热
try {
  $p = Get-Process -Name 'Bambu Connect' -ErrorAction SilentlyContinue
  if (-not $p) {
    $exe = Join-Path $env:LOCALAPPDATA 'Programs\bambu-connect\Bambu Connect.exe'
    if (Test-Path $exe) {
      Log 'connect not running -> launch'
      Start-Process -FilePath $exe
    } else { Log 'connect exe missing: ' + $exe }
  }
} catch { Log ('connect check error: ' + $_.Exception.Message) }
