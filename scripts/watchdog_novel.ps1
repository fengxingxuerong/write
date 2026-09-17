# watchdog_novel.ps1 — 墨匠长跑守护（Windows 原生，防休眠/崩溃杀进程后书烂尾）
#
# 用法（Git Bash / PowerShell 均可启动，建议独立窗口跑守护本身）：
#   powershell -ExecutionPolicy Bypass -File scripts\watchdog_novel.ps1 `
#     -OutputFile "D:\novel-writer\data\generated\<书名>.jsonl" `
#     -TotalWords 15000 -MaxChapters 5 -Genre 玄幻
#
# 行为：
#   每 60s 检查一次——按「命令行包含 output 文件名」精确匹配流水线进程（不会误杀
#   其他项目的 python）；进程不存在且书未完成 → 自动断点续跑（同命令重跑即续传）；
#   书已完成（章节数达标且终审卡存在）→ 守护自动退出。
#   锁文件防双守护：同 output 只允许一个守护实例。

param(
    [Parameter(Mandatory = $true)][string]$OutputFile,
    [int]$TotalWords = 15000,
    [int]$MaxChapters = 5,
    [string]$Genre = "玄幻",
    [int]$IntervalSeconds = 60
)

$ErrorActionPreference = "Stop"
$OutputFile = [System.IO.Path]::GetFullPath($OutputFile)
$outName = [System.IO.Path]::GetFileName($OutputFile)
$root = "D:\novel-writer"
$script = Join-Path $root "scripts\novel_pipeline.py"
$logFile = $OutputFile -replace "\.jsonl$", ".watchdog.log"
$lockFile = $OutputFile -replace "\.jsonl$", ".watchdog.lock"

# 防双守护
if (Test-Path $lockFile) {
    $oldPid = Get-Content $lockFile -ErrorAction SilentlyContinue
    $oldProc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
    if ($oldProc) { Write-Output "[watchdog] 已有守护实例在跑（PID $oldPid），退出"; exit 0 }
    Remove-Item $lockFile -ErrorAction SilentlyContinue
}
$PID | Set-Content $lockFile

function Test-BookDone {
    # 完成判定：jsonl 章节数 ≥ MaxChapters 且 终审卡存在
    if (-not (Test-Path $OutputFile)) { return $false }
    $count = 0
    Get-Content $OutputFile -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_ -match '"type": "chapter"') { $count++ }
    }
    $chief = $OutputFile -replace "\.jsonl$", ".终审卡.txt"
    return ($count -ge $MaxChapters -and (Test-Path $chief))
}

function Start-Pipeline {
    $envFile = Join-Path $root ".env.local"
    $py = "python"
    $argList = @(
        "-u", $script,
        "--total-words", $TotalWords,
        "--max-chapters", $MaxChapters,
        "--genre", $Genre,
        "--output", $OutputFile
    )
    Write-Output "[$(Get-Date -Format 'HH:mm:ss')] [watchdog] 拉起流水线：$outName"
    # 一次性注入 .env.local 到本守护进程环境，子进程继承
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^([A-Z_]+)=(.*)$') { Set-Item -Path "env:$($Matches[1])" -Value $Matches[2] }
    }
    Start-Process -FilePath $py -ArgumentList $argList `
        -WorkingDirectory $root -WindowStyle Hidden `
        -RedirectStandardOutput ($logFile) -RedirectStandardError ($logFile + ".err")
}

Write-Output "[$(Get-Date -Format 'HH:mm:ss')] [watchdog] 守护启动：$outName（每 ${IntervalSeconds}s 检查，锁定 PID $PID）"
try {
    while ($true) {
        if (Test-BookDone) {
            Write-Output "[$(Get-Date -Format 'HH:mm:ss')] [watchdog] 书已完成（章节达标 + 终审卡在），守护退出"
            break
        }
        # 精确匹配：命令行含本 output 文件名的 python 进程才算流水线在跑
        $proc = Get-CimInstance Win32_Process -Filter "Name like 'python%'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*$outName*" -and $_.CommandLine -like "*novel_pipeline.py*" }
        if (-not $proc) {
            Write-Output "[$(Get-Date -Format 'HH:mm:ss')] [watchdog] 流水线进程不存在且书未完成 → 断点续跑"
            Start-Pipeline
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
}
finally {
    Remove-Item $lockFile -ErrorAction SilentlyContinue
}
