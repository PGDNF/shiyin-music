<#
.SYNOPSIS
  构建 Android ARM64 + Impeller APK。
.EXAMPLE
  .\build_apk.ps1
  .\build_apk.ps1 debug
  .\build_apk.ps1 -CheckOnly
#>
[CmdletBinding()]
param(
    [ValidateSet('release', 'debug')]
    [string]$BuildType = 'release',
    # 只解析并打印工具链环境，不执行构建（换机器 / 排查 PATH 问题时用，秒出结果）
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'

Write-Host '============================================'
Write-Host '  时音 - APK 构建工具 (ps1)'
Write-Host '============================================'

$Renderer = 'impeller'
$Abi = 'arm64'

# 以脚本所在目录为仓库根，不依赖写死盘符
Set-Location $PSScriptRoot

# 工具链定位统一交给 scripts/flutter-env.ps1：
# 环境变量（FLUTTER_ROOT / JAVA_HOME / ANDROID_HOME）→ PATH → 常见安装位置。
# 以前这里的兜底路径写死成 E:\...，换到没有 E: 盘的机器就两条都落空。
. (Join-Path $PSScriptRoot 'scripts\flutter-env.ps1')

$flutter = Resolve-FlutterPath
if (-not $flutter) {
    Write-Error ('找不到 flutter：请把 Flutter SDK 的 bin 加入 PATH，或设置 FLUTTER_ROOT 环境变量' +
        '（例：setx FLUTTER_ROOT C:\develop\flutter\flutter，然后重开终端）')
    exit 1
}
if (-not $env:JAVA_HOME) { $env:JAVA_HOME = Resolve-JdkHome }
if (-not $env:ANDROID_HOME) { $env:ANDROID_HOME = Resolve-AndroidSdk }
$env:JAVA_TOOL_OPTIONS = '-Dfile.encoding=UTF-8'

Write-Host "[flutter]      $flutter" -ForegroundColor DarkGray
Write-Host "[JAVA_HOME]    $(if ($env:JAVA_HOME) { $env:JAVA_HOME } else { '(未设置，交给 Gradle 从 PATH 找 java)' })" -ForegroundColor DarkGray
Write-Host "[ANDROID_HOME] $(if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { '(未设置)' })" -ForegroundColor DarkGray

if ($CheckOnly) {
    Write-Host ''
    Write-Host '[仅检查] 以上环境已解析，-CheckOnly 跳过构建。' -ForegroundColor Yellow
    exit 0
}

Write-Host "[渲染引擎] $Renderer"
Write-Host "[构建类型] $BuildType"
Write-Host "[目标 ABI] $Abi"

Write-Host ''
Write-Host '[0/4] 检查是否需要清理...'
$variant = "$Renderer-$Abi"
$stamp = Join-Path 'build' '.last_variant'
$last = ''
if (Test-Path $stamp) { $last = (Get-Content $stamp -Raw).Trim() }
if ($last -ne $variant) {
    if ($last) {
        Write-Host "变体切换（$last --> $variant），执行 flutter clean..."
    } else {
        Write-Host '上次构建记录不存在，执行 flutter clean 确保干净构建...'
    }
    & $flutter clean
    if ($LASTEXITCODE -ne 0) { exit 1 }
    if (-not (Test-Path 'build')) { New-Item -ItemType Directory 'build' | Out-Null }
    Set-Content -NoNewline -Encoding utf8NoBOM -Path $stamp -Value $variant
} else {
    Write-Host "同一变体（$variant），跳过 clean，走增量构建。"
}

Write-Host ''
Write-Host '[1/4] 安装依赖...'
& $flutter pub get
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host ''
Write-Host '[2/4] 代码分析...'
& $flutter analyze
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host ''
Write-Host '[3/4] 构建 APK...'
$flutterTarget = 'android-arm64'
& $flutter build apk --$BuildType --target-platform $flutterTarget --android-project-arg=customPackageName=com.apple.android.music
if ($LASTEXITCODE -ne 0) { exit 1 }

$apk = Join-Path 'build\app\outputs\flutter-apk' "app-$BuildType.apk"
Write-Host ''
Write-Host '============================================'
if (Test-Path $apk) {
    $mb = '{0:N1}' -f ((Get-Item $apk).Length / 1MB)
    Write-Host "  [成功] 构建成功！（$mb MB）" -ForegroundColor Green
    Write-Host "  APK：$apk"
} else {
    Write-Host '  [成功] 构建命令已完成，但未找到预期产物：' -ForegroundColor Yellow
    Write-Host "  $apk"
}
Write-Host '============================================'
Write-Host ''
Write-Host '用法: .\build_apk.ps1 [release|debug]，固定 ARM64 + Impeller'
