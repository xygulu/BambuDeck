# 开机自动登录 (2026-10-29)
# helper 靠 UIA 驱动 Bambu Connect, 必须有带桌面的会话; Windows 服务
# (Session 0) 看不到窗口, 所以「重启后零人工」的唯一途径是开机自动登录。
# 密码从 stdin 读入 (不经命令行/不落任何脚本文件), 只回打印长度。
# ForceAutoLogon=1: 注销后也自动登回来 (RDP 里点了注销也不至于裸奔到下次重启)。
$pw = [Console]::In.ReadLine()
if (-not $pw) { Write-Output 'no_password'; exit 1 }
$k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $k -Name AutoAdminLogon   -Value '1'
Set-ItemProperty -Path $k -Name ForceAutoLogon   -Value '1'
Set-ItemProperty -Path $k -Name DefaultUserName  -Value $env:USERNAME
Set-ItemProperty -Path $k -Name DefaultDomainName -Value $env:COMPUTERNAME
Set-ItemProperty -Path $k -Name DefaultPassword  -Value $pw
Write-Output ('autologon_set user=' + $env:USERNAME + ' pwlen=' + $pw.Length)
