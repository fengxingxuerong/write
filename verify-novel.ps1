﻿# ============================================================
# verify-novel.ps1 — 墨匠本地一键验证（CI 化）
# 用法:
#   powershell -ExecutionPolicy Bypass -File verify-novel.ps1            # 三步全跑
#   powershell -ExecutionPolicy Bypass -File verify-novel.ps1 -SkipBuild # 跳过 Release 构建
#   powershell -ExecutionPolicy Bypass -File verify-novel.ps1 -SkipTest  # 跳过测试
# 说明:
#   - dart analyze 在普通权限直接跑
#   - flutter test / build 需 sudo 提权（flutter.bat 引擎 stamp 更新需要写权限）
#   - 所有日志写入 <项目>/verify-logs/
# ============================================================
param(
    [switch]$SkipBuild,
    [switch]$SkipTest,
    [switch]$SkipAnalyze
)

$ErrorActionPreference = 'Continue'
# 项目根：脚本所在目录（不再硬编码机器特定路径）。
$proj = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# Flutter SDK 自动探测：PATH → 常见安装位置；找不到则直接退出。
function Resolve-FlutterBin {
    $cmd = Get-Command 'flutter.bat' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($cand in @(
        'D:\flutter-sdk\bin\flutter.bat',
        'C:\flutter\bin\flutter.bat',
        "$env:LOCALAPPDATA\flutter\bin\flutter.bat"
    )) {
        if (Test-Path $cand) { return $cand }
    }
    Write-Host '  [FAIL] 未找到 Flutter SDK（flutter.bat）——请安装或将 flutter 加入 PATH' -ForegroundColor Red
    exit 1
}
$flutterBin = Resolve-FlutterBin
# dart.exe 优先用 SDK 内置的；找不到则回退 flutter.bat（flutter analyze 等价可用）。
$flutterRoot = Split-Path -Parent (Split-Path -Parent $flutterBin)
$dartBin = Join-Path $flutterRoot 'cache\dart-sdk\bin\dart.exe'
if (-not (Test-Path $dartBin)) { $dartBin = $flutterBin }
# 提权仅在上一个环境需要；本机若无 sudo 则直接执行。
$hasSudo = [bool](Get-Command sudo -ErrorAction SilentlyContinue)
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logDir = Join-Path $proj 'verify-logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function Write-Step($msg) {
    Write-Host ''
    Write-Host ('=' * 64) -ForegroundColor Cyan
    Write-Host ('  ' + $msg) -ForegroundColor Cyan
    Write-Host ('=' * 64) -ForegroundColor Cyan
}

function Write-Result($name, $ok) {
    if ($ok) {
        Write-Host ('  [PASS] ' + $name) -ForegroundColor Green
    } else {
        Write-Host ('  [FAIL] ' + $name) -ForegroundColor Red
    }
}

$global:allOk = $true

# ---------- 1. dart analyze ----------
if (-not $SkipAnalyze) {
    Write-Step 'STEP 1/3: dart analyze'
    Push-Location $proj
    $analyzeOut = & $dartBin analyze 2>&1
    $analyzeOk = ($LASTEXITCODE -eq 0)
    $analyzeOut | ForEach-Object { Write-Output $_ }
    Pop-Location
    if (-not $analyzeOk) { $global:allOk = $false }
    Write-Result 'dart analyze' $analyzeOk
} else {
    Write-Host '  (跳过 analyze)' -ForegroundColor DarkGray
}

# ---------- 2. flutter test（全量，sudo） ----------
if (-not $SkipTest) {
    Write-Step 'STEP 2/3: flutter test（全量，sudo）'
    $testLog = Join-Path $logDir ("test-$stamp.log")
    $inner = @'
param([string]$ProjDir, [string]$LogFile, [string]$FlutterBin)
$ErrorActionPreference = 'Continue'
Push-Location $ProjDir
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
$cmdLine = '"' + $FlutterBin + '" test'
$out = cmd /c $cmdLine 2>&1
$out | ForEach-Object { $_ | Out-File -FilePath $LogFile -Append -Encoding utf8 }
('TEST_EXIT_CODE: ' + $LASTEXITCODE) | Out-File -FilePath $LogFile -Append -Encoding utf8
Write-Host ('TEST_EXIT_CODE: ' + $LASTEXITCODE)
Pop-Location
'@
    $innerPath = Join-Path $env:TEMP 'verify-test-inner.ps1'
    Set-Content -Path $innerPath -Value $inner -Encoding UTF8
    if ($hasSudo) {
        sudo powershell -ExecutionPolicy Bypass -File $innerPath -ProjDir $proj -LogFile $testLog -FlutterBin $flutterBin
    } else {
        powershell -ExecutionPolicy Bypass -File $innerPath -ProjDir $proj -LogFile $testLog -FlutterBin $flutterBin
    }
    # 轮询等待测试完成（flutter test 全量约 1-3 分钟）
    $deadline = (Get-Date).AddMinutes(8)
    $testOk = $false
    $testExit = -1
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 10
        if (-not (Test-Path $testLog)) { continue }
        $exitLine = Get-Content $testLog -Tail 20 | Select-String -Pattern 'TEST_EXIT_CODE: (\d+)' | Select-Object -Last 1
        if ($exitLine -and $exitLine.Matches) {
            $testExit = [int]$exitLine.Matches[0].Groups[1].Value
            $testOk = ($testExit -eq 0)
            break
        }
    }
    if (-not $testOk) { $global:allOk = $false }
    Write-Result ("flutter test (exit=$testExit)") $testOk
} else {
    Write-Host '  (跳过测试)' -ForegroundColor DarkGray
}

# ---------- 3. Release 构建（sudo） ----------
if (-not $SkipBuild) {
    Write-Step 'STEP 3/3: flutter build windows --release（sudo）'
    $buildLog = Join-Path $logDir ("build-$stamp.log")
    $inner = @'
param([string]$ProjDir, [string]$LogFile, [string]$FlutterBin)
$ErrorActionPreference = 'Continue'
Push-Location $ProjDir
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
$cmdLine = '"' + $FlutterBin + '" build windows --release'
$out = cmd /c $cmdLine 2>&1
$out | ForEach-Object { $_ | Out-File -FilePath $LogFile -Append -Encoding utf8 }
('BUILD_EXIT_CODE: ' + $LASTEXITCODE) | Out-File -FilePath $LogFile -Append -Encoding utf8
Write-Host ('BUILD_EXIT_CODE: ' + $LASTEXITCODE)
Pop-Location
'@
    $innerPath = Join-Path $env:TEMP 'verify-build-inner.ps1'
    Set-Content -Path $innerPath -Value $inner -Encoding UTF8
    if ($hasSudo) {
        sudo powershell -ExecutionPolicy Bypass -File $innerPath -ProjDir $proj -LogFile $buildLog -FlutterBin $flutterBin
    } else {
        powershell -ExecutionPolicy Bypass -File $innerPath -ProjDir $proj -LogFile $buildLog -FlutterBin $flutterBin
    }
    # 轮询等待构建完成（Release 构建约 2-6 分钟）
    $deadline = (Get-Date).AddMinutes(15)
    $buildOk = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 10
        if (-not (Test-Path $buildLog)) { continue }
        $exitLine = Get-Content $buildLog -Tail 20 | Select-String -Pattern 'BUILD_EXIT_CODE: (\d+)' | Select-Object -Last 1
        if ($exitLine -and $exitLine.Matches) {
            $buildOk = ([int]$exitLine.Matches[0].Groups[1].Value -eq 0)
            break
        }
    }
    if (-not $buildOk) { $global:allOk = $false }
    Write-Result 'flutter build windows --release' $buildOk
} else {
    Write-Host '  (跳过构建)' -ForegroundColor DarkGray
}

# ---------- 汇总 ----------
Write-Step '验证汇总'
if ($global:allOk) {
    Write-Host '  ✅ 全部通过 — analyze 0 issues / 测试全过 / 构建成功' -ForegroundColor Green
    exit 0
} else {
    Write-Host '  ❌ 存在失败项 — 请查看上方 FAIL 标记与日志' -ForegroundColor Red
    Write-Host ("     日志目录: " + $logDir) -ForegroundColor DarkGray
    exit 1
}
