# 重注册 BambuDeckHelper 计划任务 (2026-10-29)
# 旧任务的问题: schtasks /create 默认 72 小时执行时限 (跑满三天被强停);
# 只有「登录时」触发 (重启后无人登录就永远起不来)。新任务:
#   触发 = 登录时 + 每 5 分钟重复 (错过则 StartWhenAvailable 补跑)
#   时限 = 无 (Zero); 电池不限; 同名实例 IgnoreNew
#   动作 = helper_watch.ps1 (看护: 拉起 bat / tscon 保活 / Connect 预热)
$ErrorActionPreference = 'Stop'
# 路径与账号都取当前环境, 不写死某台机器
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$user = $env:COMPUTERNAME + '\' + $env:USERNAME
# 说明: 任务以 -File 跑 .ps1, 若本机执行策略禁止脚本, 请在「管理员 PowerShell」
# 里把当前用户执行策略设为 RemoteSigned 再跑本脚本 (Get-ExecutionPolicy -List 可查)。
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument ('-NoProfile -File ' + (Join-Path $dir 'helper_watch.ps1'))
$trigLogon = New-ScheduledTaskTrigger -AtLogOn -User $user
$trigEvery = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
  -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
$principal = New-ScheduledTaskPrincipal -UserId $user `
  -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
  -ExecutionTimeLimit ([TimeSpan]::Zero) `
  -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -StartWhenAvailable -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'BambuDeckHelper' `
  -Action $action -Trigger @($trigLogon, $trigEvery) `
  -Principal $principal -Settings $settings -Force | Out-Null
Write-Output 'task_registered'
$t = Get-ScheduledTask -TaskName 'BambuDeckHelper'
$s = $t.Triggers | ForEach-Object { $_.CimClass.CimClassName }
Write-Output ('state=' + $t.State + ' triggers=' + ($s -join ','))
$inf = Get-ScheduledTaskInfo -TaskName 'BambuDeckHelper'
Write-Output ('exe_limit=' + $t.Settings.ExecutionTimeLimit)
