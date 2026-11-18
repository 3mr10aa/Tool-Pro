# AMR Tool-Pro | Self-contained GitHub bootstrap launcher
# Windows PowerShell 5.1 | Supports: irm <raw-launcher-url> | iex

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRaw = 'https://raw.githubusercontent.com/3mr10aa/Tool-Pro/main'
$installRoot = Join-Path $env:LOCALAPPDATA 'AMR-ToolPro\Runtime'
$stageRoot = Join-Path $env:TEMP ('AMR-ToolPro-' + [guid]::NewGuid().ToString('N'))
$logPath = Join-Path $env:TEMP 'AMR_ToolPro_Launcher.log'

# These pins are populated automatically by the publish command from the exact
# files in the local release folder. Never leave a placeholder in a published launcher.
$expected = @{
    'AMR_Windows_Utility_V1.ps1' = '9EAA05167E9D4B2417A05CE845E67BAA9880C605CA733B5D6E8FFC0636A78EDA'
    'AMR_WebView2/Microsoft.Web.WebView2.Core.dll' = 'ACDD517B951829F763D1255F32DF1E6A936CB8623A7EBFF6B8B24172DEDE6BD6'
    'AMR_WebView2/Microsoft.Web.WebView2.Wpf.dll' = 'BAAFA0A595C2CEFB3BE8F18288C3DB76F52E3966C8B99957D5E56CAF1B137BC1'
    'AMR_WebView2/x64/WebView2Loader.dll' = 'D3FCE90BDEECB08596E377DEA6A316354DD8949E32FF09B89D51BE00C14E21B6'
    'AMR_WebView2/x86/WebView2Loader.dll' = '1D348D3C0A5CB0D985389B68A0FD9BF966C2AED65F5E44BBC0233739B7A57F9E'
}

function Write-AMRLauncherLog {
    param([string]$Message)
    try {
        Add-Content -LiteralPath $logPath -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8
    } catch {}
}

function Get-AMRFile {
    param([string]$RelativePath, [string]$Destination)
    $url = $repoRaw + '/' + (($RelativePath -split '/') -join '/')
    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Invoke-WebRequest -Uri $url -OutFile $Destination -UseBasicParsing -TimeoutSec 90
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        throw "Download did not create the expected file: $RelativePath"
    }
    $item = Get-Item -LiteralPath $Destination
    if ($item.Length -le 0) { throw "Downloaded file is empty: $RelativePath" }

    $pin = [string]$expected[$RelativePath]
    if ($pin -notmatch '^[A-Fa-f0-9]{64}$') {
        throw "Launcher integrity pin is missing or invalid for $RelativePath. Re-publish LAUNCHER.ps1 using the provided PowerShell publish command."
    }
    $actual = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
    if ($actual -ne $pin.ToUpperInvariant()) {
        throw "SHA-256 verification failed for $RelativePath. Expected $pin but received $actual"
    }
    Write-AMRLauncherLog ("Verified {0} | SHA256={1}" -f $RelativePath, $actual)
}

try {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is not available.' }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null

    Write-AMRLauncherLog 'Starting AMR Tool-Pro bootstrap.'
    foreach ($relative in $expected.Keys) {
        $destination = Join-Path $stageRoot ($relative -replace '/', '\')
        Get-AMRFile -RelativePath $relative -Destination $destination
    }

    $appStage = Join-Path $stageRoot 'AMR_Windows_Utility_V1.ps1'
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($appStage, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        throw ('Application PowerShell syntax validation failed: ' + $parseErrors[0].Message)
    }

    # Publish the verified complete runtime as one directory, preserving the
    # exact folder layout expected by the app's WebView2 loader.
    $parent = Split-Path -Parent $installRoot
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $backupRoot = $installRoot + '.previous'
    if (Test-Path -LiteralPath $backupRoot) { Remove-Item -LiteralPath $backupRoot -Recurse -Force }
    if (Test-Path -LiteralPath $installRoot) { Move-Item -LiteralPath $installRoot -Destination $backupRoot -Force }
    try {
        Move-Item -LiteralPath $stageRoot -Destination $installRoot -Force
        if (Test-Path -LiteralPath $backupRoot) { Remove-Item -LiteralPath $backupRoot -Recurse -Force }
    } catch {
        if ((Test-Path -LiteralPath $backupRoot) -and -not (Test-Path -LiteralPath $installRoot)) {
            Move-Item -LiteralPath $backupRoot -Destination $installRoot -Force
        }
        throw
    }

    $appPath = Join-Path $installRoot 'AMR_Windows_Utility_V1.ps1'
    $powershellExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) { $powershellExe = 'powershell.exe' }
    $quotedApp = '"' + $appPath.Replace('"', '""') + '"'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -STA -File ' + $quotedApp
    Write-AMRLauncherLog ("Launching verified application: {0}" -f $appPath)
    Start-Process -FilePath $powershellExe -ArgumentList $arguments -WorkingDirectory $installRoot -ErrorAction Stop | Out-Null
}
catch {
    Write-AMRLauncherLog ('ERROR: ' + $_.Exception.Message)
    $message = 'AMR Tool-Pro could not start.' + [Environment]::NewLine + [Environment]::NewLine + $_.Exception.Message + [Environment]::NewLine + [Environment]::NewLine + 'Launcher log: ' + $logPath
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($message, 'AMR Tool-Pro Launcher', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch { Write-Error $message }
}
finally {
    if (Test-Path -LiteralPath $stageRoot) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
