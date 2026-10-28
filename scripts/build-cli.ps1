# FitDot 命令行构建脚本（兼容 Windows PowerShell 5.1 与 PowerShell 7）
#
# 为什么需要这个脚本：
#   HarmonyOS 工程的 hvigor 构建需要两个环境变量，且 hvigor 的可执行入口在
#   DevEco Studio 安装目录里（不在工程里）。本脚本自动定位 IDE 并设置好环境。
#
# 用法：
#   powershell -File scripts\build-cli.ps1                # 默认 assembleHap
#   powershell -File scripts\build-cli.ps1 clean          # 清理构建产物
#   powershell -File scripts\build-cli.ps1 assembleHap -IdePath "D:\DevEco Studio"
#
# 已验证：2026-10-10，DevEco Studio 26.0.0.851 / SDK 26.0.0.105 → BUILD SUCCESSFUL

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Task = 'assembleHap',

    [string]$IdePath
)

$ErrorActionPreference = 'Stop'

# ---- 1. 定位 DevEco Studio ----
$candidates = @()
if ($IdePath) { $candidates += $IdePath }

# 从注册表卸载项里找
try {
    $candidates += (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like '*DevEco*' } |
        Select-Object -ExpandProperty InstallLocation -ErrorAction SilentlyContinue)
} catch { }

# 常见默认路径
$candidates += 'D:\Program Files\DevEco Studio'
$candidates += 'C:\Program Files\DevEco Studio'
$candidates += 'C:\Program Files\Huawei\DevEco Studio'

$ide = $null
foreach ($c in $candidates) {
    if (-not $c) { continue }
    if (Test-Path (Join-Path $c 'tools\hvigor\bin\hvigorw.js')) { $ide = $c; break }
}

if (-not $ide) {
    $msg = '未找到 DevEco Studio 安装目录。' + [Environment]::NewLine +
           '请用 -IdePath 参数手动指定，例如：' + [Environment]::NewLine +
           '  powershell -File scripts\build-cli.ps1 -IdePath "D:\Program Files\DevEco Studio"'
    Write-Error $msg
    exit 1
}

Write-Host "DevEco Studio : $ide" -ForegroundColor Cyan

# ---- 2. 校验工具链 ----
$sdk      = Join-Path $ide 'sdk'
$nodeExe  = Join-Path $ide 'tools\node\node.exe'
$hvigorJs = Join-Path $ide 'tools\hvigor\bin\hvigorw.js'

$missing = @()
foreach ($p in @($sdk, $nodeExe, $hvigorJs)) {
    if (-not (Test-Path $p)) { $missing += $p }
}
if ($missing.Count -gt 0) {
    Write-Error ('缺少必需组件：' + [Environment]::NewLine + ($missing -join [Environment]::NewLine))
    exit 1
}
Write-Host "SDK           : $sdk" -ForegroundColor Cyan

# ---- 3. 设置 hvigor 需要的环境变量 ----
# 不设 DEVECO_SDK_HOME 会报 00303217 Configuration Error
$env:DEVECO_SDK_HOME = $sdk
$env:NODE_HOME       = Join-Path $ide 'tools\node'
$env:PATH            = (Join-Path $ide 'tools\node') + ';' + (Join-Path $ide 'tools\ohpm\bin') + ';' + $env:PATH

# ---- 4. 构建 ----
$projectRoot = Split-Path $PSScriptRoot -Parent
Write-Host "工程目录      : $projectRoot" -ForegroundColor Cyan
Write-Host "任务          : $Task" -ForegroundColor Cyan
Write-Host ''

# 重要：hvigor 会把进度、告警都写到 stderr。
# 若此处仍保持 $ErrorActionPreference = 'Stop'，PowerShell 会把它当作
# NativeCommandError 终止错误，脚本会在构建刚开始时就中断。
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'

Push-Location $projectRoot
try {
    & $nodeExe $hvigorJs $Task
    $code = $LASTEXITCODE
} finally {
    Pop-Location
    $ErrorActionPreference = $prevEAP
}

if ($code -eq 0) {
    $hap = Get-ChildItem (Join-Path $projectRoot 'entry\build') -Recurse -File -Filter '*.hap' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($hap) {
        Write-Host ''
        Write-Host ("产物: {0}  ({1:N0} B)" -f $hap.FullName, $hap.Length) -ForegroundColor Green
    }
}

exit $code
