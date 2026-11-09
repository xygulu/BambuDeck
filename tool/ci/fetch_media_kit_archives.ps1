# 把 media_kit 在 CMake 阶段要用的两个归档先取好放到 build/windows/x64。
#
# 背景 (2026-11-09): GitHub 的 release 资源从 GitHub Actions 的 runner 上拉
# 会稳定 504 (Gradle 的 Kotlin jar、media_kit 的 Android libmpv jar、Windows
# 的 ANGLE.7z / libmpv 7z 全栽在这一处)。media_kit 的 download_and_verify
# 只在文件不存在时才下载, 下到的错误页会留在 build 目录里反复让构建失败。
#
# 所以提前把文件放到位: 两个归档都有官方 MD5, 校验照常成立, 不会引入
# 未经校验的二进制。
param(
  [string]$DestDir = 'build/windows/x64'
)

$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path $DestDir | Out-Null

function Get-VerifiedFile($name, $want, $urls) {
  $dst = Join-Path $DestDir $name
  if (Test-Path $dst) {
    if ((Get-FileHash $dst -Algorithm MD5).Hash.ToLower() -eq $want) {
      Write-Host "$name already present"
      return
    }
    Remove-Item $dst -Force
  }
  foreach ($u in $urls) {
    for ($i = 1; $i -le 3; $i++) {
      Write-Host "downloading $name (attempt $i)"
      try {
        Invoke-WebRequest -UseBasicParsing -MaximumRedirection 5 -Uri $u -OutFile $dst
        $got = (Get-FileHash $dst -Algorithm MD5).Hash.ToLower()
        if ($got -eq $want) {
          Write-Host "$name ok"
          return
        }
        Write-Host "::warning::$name md5 mismatch ($got)"
        Remove-Item $dst -Force -ErrorAction SilentlyContinue
      } catch {
        Write-Host "::warning::$name download failed"
        Remove-Item $dst -Force -ErrorAction SilentlyContinue
      }
      Start-Sleep -Seconds 5
    }
  }
  throw "$name could not be fetched intact"
}

$angle = 'https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/releases/download/v1.0.1/ANGLE.7z'
$mpv = 'https://github.com/media-kit/libmpv-win32-video-build/releases/download/2023-09-24/mpv-dev-x86_64-20230924-git-652a1dd.7z'

Get-VerifiedFile 'ANGLE.7z' 'e866f13e8d552348058afaafe869b1ed' @($angle, "https://ghfast.top/$angle")
Get-VerifiedFile 'mpv-dev-x86_64-20230924-git-652a1dd.7z' 'a832ef24b3a6ff97cd2560b5b9d04cd8' @($mpv, "https://ghfast.top/$mpv")

Write-Host 'media_kit archives ready'
