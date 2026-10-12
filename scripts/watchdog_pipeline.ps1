# InkSmith pipeline watchdog: auto-restart novel_pipeline.py until book finished
#
# 路径不再硬编码 D:\novel-writer：本脚本 2026-10-13 起入库当交付脚本，
# 硬编码绝对路径换机器即静默失效（进程起不来、日志写不进去，最难排查）。
# 改为从脚本自身位置推导仓库根，参数缺省值也据此推导；
# 换机时只需保证 scripts/ 位于仓库根下，或用 -OutputFile 显式指定。
$ErrorActionPreference = 'SilentlyContinue'

param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [int]$TotalWords = 100000,
    [int]$MaxChapters = 40,
    [string]$OutDir
)

# 密钥必须由当前用户环境或安全凭据存储注入，禁止写入脚本。
# 运行前请在当前 PowerShell 会话设置：NOVEL_KEY_AMD、NOVEL_KEY_SENSE_K1/K2/K3。
# 缺少任一变量时，novel_pipeline.py 会在启动阶段报告并停止。

if (-not $OutDir) { $OutDir = Join-Path $Root "data\generated" }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$scriptPath = Join-Path $Root "scripts\novel_pipeline.py"
$argsList = @("-u", $scriptPath, "--total-words", "$TotalWords", "--max-chapters", "$MaxChapters",
              "--output", (Join-Path $OutDir "novel_10w_pipeline.jsonl"))
$log = Join-Path $OutDir "pipeline_full.log"
$errLog = Join-Path $OutDir "pipeline_full.err.log"
$restarts = 0
$maxRestarts = 40
$wdLog = Join-Path $OutDir "watchdog.log"

function IsDone {
    if (Test-Path $log) {
        if (Select-String -Path $log -Pattern '\[OK\] 文本输出' -Quiet) { return $true }
        if (Select-String -Path $log -Pattern '\[DONE\]' -Quiet) { return $true }
    }
    return $false
}

while ($true) {
    if (IsDone) {
        Add-Content -Path $wdLog -Value "[WD] book finished, watchdog exit"
        break
    }
    if ($restarts -ge $maxRestarts) {
        Add-Content -Path $wdLog -Value "[WD] max restarts reached ($maxRestarts), exit"
        break
    }
    $running = Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
        Where-Object { $_.CommandLine -match 'novel_pipeline' }
    if (-not $running) {
        $restarts += 1
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -Path $wdLog -Value "[WD] $ts pipeline down, restart #$restarts"
        Start-Process -FilePath "python" -ArgumentList $argsList `
            -RedirectStandardOutput $log -RedirectStandardError $errLog -WindowStyle Hidden
        Start-Sleep -Seconds 8
    }
    Start-Sleep -Seconds 30
}
