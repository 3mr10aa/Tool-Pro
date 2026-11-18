# AMR Windows Utility - standalone launcher
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'AMR_Windows_Utility_V1.ps1'
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    Write-Error "Application script was not found: $scriptPath"
    exit 1
}
$powerShell = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $powerShell -PathType Leaf)) { $powerShell = 'powershell.exe' }
$arguments = '-NoProfile -ExecutionPolicy Bypass -STA -File "' + $scriptPath.Replace('"','""') + '"'
try {
    Start-Process -FilePath $powerShell -ArgumentList $arguments -WorkingDirectory $PSScriptRoot
} catch {
    Write-Error ("Could not launch AMR Windows Utility: " + $_.Exception.Message)
    exit 1
}
