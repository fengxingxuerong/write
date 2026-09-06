# 墨匠新版质量一键实测脚本
# 用法：右键 -> 使用 PowerShell 运行；或：
#   powershell -ExecutionPolicy Bypass -File run_quality_test.ps1
$ErrorActionPreference = "Stop"
$scripts = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scripts

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  墨匠 新版质量 一键实测" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# 检查 python
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) {
    Write-Host "[ERROR] 未找到 python，请先安装并加入 PATH" -ForegroundColor Red
    exit 1
}

# AMD API Key：优先环境变量，其次手动输入
$amdKey = $env:NOVEL_KEY_AMD
if (-not $amdKey) {
    $amdKey = Read-Host "请粘贴 AMD API Key（回车跳过则从代码默认读取）"
}

Write-Host ""
Write-Host "[Step 1/2] 新版标准生成实测（3000 字 x 1 章）..." -ForegroundColor Yellow
python -u generate_novel.py `
    --base-url "https://developer.amd.com.cn/radeon/api/v1/chat/completions" `
    --model "DeepSeek-V4-Flash" `
    --api-key $amdKey `
    --total-words 3000 `
    --max-chapters 1 `
    --output test_quality.jsonl `
    --chapter-wait 1

Write-Host ""
Write-Host "[Step 2/2] 旧成书《碎脉铸仙录》基线扫描..." -ForegroundColor Yellow
python qa_scan_existing.py ..\data\generated\novel_10w_pipeline_final.txt

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  实测完成！" -ForegroundColor Green
Write-Host "  新书：scripts\test_quality.jsonl / test_quality.txt" -ForegroundColor Green
Write-Host "  基线：上方《碎脉铸仙录》33 章汇总" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Read-Host "按回车键退出"
