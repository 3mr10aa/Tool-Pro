#requires -Version 5.1
# AMR Tool-Pro | Premium animated bootstrap launcher | Parallel runtime + icon handoff
# Windows PowerShell 5.1 | Public command: irm <raw-launcher-url> | iex

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRaw = 'https://raw.githubusercontent.com/3mr10aa/Tool-Pro/main'
$runtimeRoot = Join-Path $env:LOCALAPPDATA 'AMR-ToolPro\Runtime'
$installRoot = $runtimeRoot # Legacy fallback until a verified version pointer is available.
$installParent = Split-Path -Parent $runtimeRoot
$versionsRoot = Join-Path $runtimeRoot 'Versions'
$sharedRoot = Join-Path $runtimeRoot 'Shared'
$iconVersionsRoot = Join-Path $sharedRoot 'IconVersions'
$localInstalledIconsRoot = Join-Path $sharedRoot 'LocalInstalled'
$currentStatePath = Join-Path $runtimeRoot 'current.json'
$currentState = $null
$stageRoot = $null
$launchBootstrapPath = $null
$appPidMarkerPath = Join-Path $env:TEMP ('AMR-ToolPro-AppPid-' + [guid]::NewGuid().ToString('N') + '.txt')
$bootstrapProcess = $null
$appProcess = $null
$pendingVersionCommit = $false
$pendingVersionId = $null
$pendingIconRelativePath = $null
$logPath = Join-Path $env:TEMP 'AMR_ToolPro_Launcher.log'
$telemetryRoot = Join-Path $env:LOCALAPPDATA 'AMR-ToolPro\Telemetry'
$telemetryEndpointFileUrl = $repoRaw + '/telemetry-endpoint.txt'
$launcherVersion = '2.5.2'
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

function Test-AMRIconCacheMatchesSource {
    param([string]$IconDirectory,[string]$SourceBlob,[int]$Minimum = 100,[switch]$TrustRecordedFingerprint)
    try {
        if (-not (Test-AMRIconCacheUsable -IconDirectory $IconDirectory -Minimum $Minimum)) { return $false }
        $markerPath = Join-Path $IconDirectory '.amr-icons-source.json'
        $archivePath = Join-Path $IconDirectory 'icons.zip'
        $appMetaPath = Join-Path $IconDirectory 'icons.cache.json'
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $archivePath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $appMetaPath -PathType Leaf)) { return $false }
        $marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (([string]$marker.sourceGitBlobSha1).ToLowerInvariant() -ne ([string]$SourceBlob).ToLowerInvariant()) { return $false }
        $appMeta = Get-Content -LiteralPath $appMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$appMeta.schemaVersion -lt 2 -or
            [string]$appMeta.repository -ne '3mr10aa/Tool-Pro' -or
            [string]$appMeta.branch -ne 'main' -or
            [string]$appMeta.file -ne 'Icons.zip' -or
            [long]$appMeta.size -ne (Get-Item -LiteralPath $archivePath).Length -or
            ([string]$appMeta.sha).ToLowerInvariant() -ne ([string]$SourceBlob).ToLowerInvariant()) { return $false }
        if (-not $TrustRecordedFingerprint -and (Get-AMRGitBlobSha1 -Path $archivePath) -ne ([string]$SourceBlob).ToLowerInvariant()) { return $false }
        $extensions = @(Get-AMRIconImageExtensions)
        $actualFiles = @(Get-ChildItem -LiteralPath $IconDirectory -File -ErrorAction Stop |
            Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() -and $_.Length -gt 128 })
        $actualCount = $actualFiles.Count
        $recordedCount = 0
        if (-not [int]::TryParse([string]$marker.imageCount,[ref]$recordedCount)) { return $false }
        $manifestPath = Join-Path $IconDirectory 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $false }
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if ([int]$manifest.schemaVersion -ne 1 -or [int]$manifest.iconCount -ne $recordedCount -or
            $null -eq $manifest.entries) { return $false }
        $manifestEntries = @($manifest.entries.PSObject.Properties)
        if ($manifestEntries.Count -ne $recordedCount) { return $false }
        $actualNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($file in $actualFiles) { [void]$actualNames.Add($file.Name) }
        foreach ($record in $manifestEntries) {
            $fileName = [string]$record.Value.file
            if ([string]::IsNullOrWhiteSpace($fileName) -or [IO.Path]::GetFileName($fileName) -ne $fileName -or
                [IO.Path]::GetExtension($fileName).ToLowerInvariant() -ne '.png' -or
                -not $actualNames.Contains($fileName)) { return $false }
        }
        return ($recordedCount -ge $Minimum -and $actualCount -eq $recordedCount)
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

        # The optimized archive has one authoritative manifest beside its image set.
        $manifestEntries = @($zip.Entries | Where-Object { ([string]$_.FullName).Replace('\','/') -match '(^|/)Icons/manifest\.json$' })
        if ($manifestEntries.Count -ne 1) { throw 'Icons.zip must contain exactly one Icons/manifest.json file.' }
        $manifestStream = $manifestEntries[0].Open()
        $manifestReader = New-Object System.IO.StreamReader($manifestStream,[System.Text.Encoding]::UTF8,$true)
        try { $manifestText = $manifestReader.ReadToEnd() } finally { $manifestReader.Dispose(); $manifestStream.Dispose() }
        $manifest = $manifestText | ConvertFrom-Json -ErrorAction Stop
        if ([int]$manifest.schemaVersion -ne 1 -or [int]$manifest.iconCount -ne $entries.Count -or $null -eq $manifest.entries) {
            throw 'Icons.zip manifest schema or icon count does not match the archive image entries.'
        }
        $manifestRecords = @($manifest.entries.PSObject.Properties)
        if ($manifestRecords.Count -ne $entries.Count) { throw 'Icons.zip manifest entry count does not match the archive.' }
        $archiveNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $entries) {
            $leaf = [System.IO.Path]::GetFileName([string]$entry.FullName)
            if ([string]::IsNullOrWhiteSpace($leaf) -or $leaf -match '[\\/:*?"<>|]' -or -not $archiveNames.Add($leaf)) {
                throw 'Icons.zip contains an invalid or duplicate image filename.'
            }
        }
        foreach ($record in $manifestRecords) {
            $fileName = [string]$record.Value.file
            if ([string]::IsNullOrWhiteSpace($fileName) -or [IO.Path]::GetFileName($fileName) -ne $fileName -or
                [IO.Path]::GetExtension($fileName).ToLowerInvariant() -ne '.png' -or
                -not $archiveNames.Contains($fileName)) {
                throw ('Icons.zip manifest references a missing or invalid image: ' + $fileName)
            }
        }

        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        # Replace only top-level archive images and the archive-owned manifest.
        # Preserve app-owned subfolders such as LocalInstalled.
        Get-ChildItem -LiteralPath $Destination -File -ErrorAction SilentlyContinue |
            Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } |
            Remove-Item -Force -ErrorAction Stop
        $oldManifest = Join-Path $Destination 'manifest.json'
        if (Test-Path -LiteralPath $oldManifest -PathType Leaf) { Remove-Item -LiteralPath $oldManifest -Force -ErrorAction Stop }
        $extracted = 0
        foreach ($entry in $entries) {
            $leaf = [System.IO.Path]::GetFileName([string]$entry.FullName)
            $destinationPath = Join-Path $Destination $leaf
            $inputStream = $null; $outputStream = $null
            try {
                $inputStream = $entry.Open()
                $outputStream = New-Object System.IO.FileStream($destinationPath,[System.IO.FileMode]::Create,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None,1048576,[System.IO.FileOptions]::SequentialScan)
                $inputStream.CopyTo($outputStream,1048576)
                $outputStream.Flush()
            } finally {
                if ($outputStream) { $outputStream.Dispose() }
                if ($inputStream) { $inputStream.Dispose() }
            }
            $extracted++
        }
        if ($extracted -lt $Minimum) { throw "Only $extracted image files were extracted from Icons.zip." }
        [System.IO.File]::WriteAllText($oldManifest,$manifestText,(New-Object System.Text.UTF8Encoding($false)))
        return $extracted
    } finally { $zip.Dispose() }
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
    # Copy only the five manifest-controlled runtime files and the saved manifest.
    # Never recurse through Runtime, Versions, Shared, Telemetry, or icon generations.
    foreach ($relative in $expected.Keys) {
        $sourcePath = Join-Path $Source ($relative -replace '/', '\\')
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { continue }
        $destinationPath = Join-Path $Destination ($relative -replace '/', '\\')
        $destinationParent = Split-Path -Parent $destinationPath
        if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
            New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        }
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force -ErrorAction Stop
    }
    $manifestSource = Join-Path $Source '.amr-runtime-state.json'
    if (Test-Path -LiteralPath $manifestSource -PathType Leaf) {
        Copy-Item -LiteralPath $manifestSource -Destination (Join-Path $Destination '.amr-runtime-state.json') -Force -ErrorAction Stop
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

function Invoke-AMRParallelRuntimePreparation {
    param(
        [string[]]$RelativePaths,
        [string]$StageRoot,
        [System.Collections.IDictionary]$ExpectedBlobs,
        [bool]$ExtractIcons
    )
    $maxWorkers = [Math]::Min(4,[Math]::Max(1,$RelativePaths.Count + [int]$ExtractIcons))
    $pool = [RunspaceFactory]::CreateRunspacePool(1,$maxWorkers)
    $pool.Open()
    $progressMap = [hashtable]::Synchronized(@{})
    $tasks = New-Object System.Collections.ArrayList
    $downloadWorker = {
        param($Url,$Destination,$RelativePath,$ProgressMap)
        $parent = Split-Path -Parent $Destination
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Method = 'GET'
        $request.UserAgent = 'AMR-ToolPro-Premium-Launcher/3.1'
        $request.AllowAutoRedirect = $true
        $request.KeepAlive = $true
        try { $request.ServicePoint.ConnectionLimit = 8 } catch {}
        $request.Timeout = 45000
        $request.ReadWriteTimeout = 45000
        $response = $null; $inputStream = $null; $outputStream = $null
        [int64]$received = 0; [int64]$total = 0
        try {
            $response = $request.GetResponse()
            $total = [int64]$response.ContentLength
            $inputStream = $response.GetResponseStream()
            $outputStream = New-Object System.IO.FileStream($Destination,[System.IO.FileMode]::Create,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None,1048576,[System.IO.FileOptions]::SequentialScan)
            $buffer = New-Object byte[] 1048576
            while (($read = $inputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
                $outputStream.Write($buffer,0,$read)
                $received += $read
                $ProgressMap[$RelativePath] = [pscustomobject]@{ Received=$received; Total=$total; Done=$false }
            }
            $outputStream.Flush()
        } finally {
            if ($outputStream) { $outputStream.Dispose() }
            if ($inputStream) { $inputStream.Dispose() }
            if ($response) { $response.Dispose() }
        }
        if ($received -le 0) { throw "Downloaded file is empty: $RelativePath" }
        $ProgressMap[$RelativePath] = [pscustomobject]@{ Received=$received; Total=$total; Done=$true }
        return $Destination
    }
    $extensionsDefinition = (Get-Command Get-AMRIconImageExtensions -CommandType Function).Definition
    $expandDefinition = (Get-Command Expand-AMRIconArchive -CommandType Function).Definition
    $extractWorker = "function Get-AMRIconImageExtensions {`n$extensionsDefinition`n}`nfunction Expand-AMRIconArchive {`n$expandDefinition`n}`n`$ArchivePath=`$args[0]; `$Destination=`$args[1]; `$Minimum=`$args[2]; Expand-AMRIconArchive -ArchivePath `$ArchivePath -Destination `$Destination -Minimum `$Minimum"

    $startDownload = {
        param($relative)
        $destination = Join-Path $StageRoot ($relative -replace '/','\')
        $url = $repoRaw + '/' + $relative
        $ps = [PowerShell]::Create(); $ps.RunspacePool = $pool
        [void]$ps.AddScript($downloadWorker.ToString()).AddArgument($url).AddArgument($destination).AddArgument($relative).AddArgument($progressMap)
        $async = $ps.BeginInvoke()
        [void]$tasks.Add([pscustomobject]@{ Kind='Download'; Relative=$relative; Path=$destination; PowerShell=$ps; Async=$async })
    }
    $startExtraction = {
        $archive = Join-Path $StageRoot 'Icons.zip'
        $destination = Join-Path $StageRoot 'Icons'
        $ps = [PowerShell]::Create(); $ps.RunspacePool = $pool
        [void]$ps.AddScript($extractWorker).AddArgument($archive).AddArgument($destination).AddArgument(100)
        $async = $ps.BeginInvoke()
        [void]$tasks.Add([pscustomobject]@{ Kind='Extract'; Relative='Icons.zip extraction'; Path=$destination; PowerShell=$ps; Async=$async })
        Write-AMRLauncherLog 'Started icon extraction on a worker runspace while component downloads continue.'
    }

    try {
        foreach ($relative in $RelativePaths) { & $startDownload $relative }
        $extractionStarted = $false
        if ($ExtractIcons -and ($RelativePaths -notcontains 'Icons.zip')) { & $startExtraction; $extractionStarted = $true }
        $completed = 0
        $targetCompleted = $RelativePaths.Count + [int]$ExtractIcons
        while ($completed -lt $targetCompleted) {
            Pump-AMRLauncherUI
            $fractionSum = 0.0
            foreach ($relative in $RelativePaths) {
                $item = $progressMap[$relative]
                if ($null -eq $item) { continue }
                if ($item.Done) { $fractionSum += 1.0 }
                elseif ($item.Total -gt 0) { $fractionSum += [Math]::Min(0.99,$item.Received / [double]$item.Total) }
                else { $fractionSum += [Math]::Min(0.90,$item.Received / [double](4MB)) }
            }
            $downloadPercent = if ($RelativePaths.Count -gt 0) { [int][Math]::Floor(($fractionSum / $RelativePaths.Count) * 72.0) } else { 72 }
            $active = @($RelativePaths | Where-Object { -not $progressMap.ContainsKey($_) -or -not $progressMap[$_].Done })
            $detail = if ($active.Count -gt 0) { 'Parallel: ' + ($active -join '  +  ') } else { 'Downloads complete; verifying files and extracting icons...' }
            Set-AMRLauncherProgress -Percent ([Math]::Min(80,8 + $downloadPercent)) -Status 'Downloading AMR components in parallel...' -Detail $detail

            foreach ($task in @($tasks.ToArray())) {
                if (-not $task.Async.IsCompleted) { continue }
                $output = $null
                try { $output = $task.PowerShell.EndInvoke($task.Async) }
                catch {
                    $streamErrors = @($task.PowerShell.Streams.Error | ForEach-Object { $_.ToString() }) -join '; '
                    throw ("$($task.Relative) failed: " + $_.Exception.Message + $(if ($streamErrors) { ' | ' + $streamErrors } else { '' }))
                }
                if ($task.PowerShell.HadErrors) {
                    $streamErrors = @($task.PowerShell.Streams.Error | ForEach-Object { $_.ToString() }) -join '; '
                    throw ("$($task.Relative) failed: " + $streamErrors)
                }
                $task.PowerShell.Dispose()
                [void]$tasks.Remove($task)
                $completed++
                if ($task.Kind -eq 'Download') {
                    $relative = [string]$task.Relative
                    $normalized = $relative.Replace('\','/')
                    if (-not $ExpectedBlobs.Contains($normalized)) { throw "No GitHub source identity exists for '$relative'." }
                    $expectedBlob = [string]$ExpectedBlobs[$normalized]
                    $actualBlob = Get-AMRGitBlobSha1 -Path $task.Path
                    if ($actualBlob -ne $expectedBlob.ToLowerInvariant()) { throw "GitHub source verification failed for $relative. Expected $expectedBlob but received $actualBlob" }
                    $actualSha256 = (Get-FileHash -LiteralPath $task.Path -Algorithm SHA256).Hash
                    $item = Get-Item -LiteralPath $task.Path
                    Write-AMRLauncherLog ("Verified {0} | {1} bytes | GitBlob={2} | SHA256={3}" -f $relative,$item.Length,$actualBlob,$actualSha256)
                    if ($relative -eq 'Icons.zip' -and $ExtractIcons -and -not $extractionStarted) { & $startExtraction; $extractionStarted = $true }
                } else {
                    $iconCount = [int](@($output | Select-Object -Last 1)[0])
                    $sourceBlob = [string]$ExpectedBlobs['Icons.zip']
                    if ($sourceBlob -notmatch '^[a-fA-F0-9]{40}$') { throw 'Cannot save icon cache state without a valid GitHub Icons.zip fingerprint.' }
                    $iconMarker = [ordered]@{
                        schemaVersion = 1
                        sourceGitBlobSha1 = $sourceBlob.ToLowerInvariant()
                        extractedAtUtc = [DateTime]::UtcNow.ToString('o')
                        imageCount = $iconCount
                    }
                    $markerPath = Join-Path $task.Path '.amr-icons-source.json'
                    [System.IO.File]::WriteAllText($markerPath,($iconMarker | ConvertTo-Json -Depth 3),(New-Object System.Text.UTF8Encoding($false)))
                    Write-AMRLauncherLog ("Parallel extraction completed: $iconCount verified icon image(s); cache fingerprint saved: $sourceBlob")
                }
            }
            Start-Sleep -Milliseconds 25
        }
    } finally {
        foreach ($task in @($tasks.ToArray())) {
            try { if (-not $task.Async.IsCompleted) { $task.PowerShell.Stop() } } catch {}
            try { $task.PowerShell.Dispose() } catch {}
        }
        try { $pool.Close() } catch {}
        try { $pool.Dispose() } catch {}
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is not available.' }
    New-Item -ItemType Directory -Path $versionsRoot,$sharedRoot,$iconVersionsRoot,$localInstalledIconsRoot -Force | Out-Null
    if (Test-Path -LiteralPath $currentStatePath -PathType Leaf) {
        try {
            $currentState = Get-Content -LiteralPath $currentStatePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            $candidateVersionId = [string]$currentState.versionId
            if ($candidateVersionId -match '^[a-fA-F0-9]{40}(-[a-fA-F0-9]{8})?$') {
                $candidateRoot = Join-Path $versionsRoot $candidateVersionId
                if (Test-Path -LiteralPath (Join-Path $candidateRoot 'AMR_Windows_Utility_V1.ps1') -PathType Leaf) {
                    $installRoot = $candidateRoot
                    Write-AMRLauncherLog ('Selected previously committed immutable runtime version: ' + $candidateVersionId)
                }
            }
        } catch {
            $currentState = $null
            Write-AMRLauncherLog ('Current-version pointer is invalid; retaining legacy runtime fallback. ' + $_.Exception.Message)
        }
    }
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
        [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
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
    # Hide the invoking console only under the real Windows ConsoleHost.
    try {
        if ($Host.Name -eq 'ConsoleHost') {
            $consoleHandle = [AMR.ToolProLauncherNative]::GetConsoleWindow()
            if ($consoleHandle -ne [IntPtr]::Zero) {
                [void][AMR.ToolProLauncherNative]::ShowWindow($consoleHandle, 0)
                Write-AMRLauncherLog 'Hidden the invoking PowerShell console behind the launcher.'
            }
        }
    } catch { Write-AMRLauncherLog ('Could not hide the invoking console window: ' + $_.Exception.Message) }
    # Smooth cubic ease-out entrance.
    $fadeInStarted = [DateTime]::UtcNow
    $fadeInTimer = New-Object System.Windows.Forms.Timer
    $fadeInTimer.Interval = 15
    $fadeInTimer.Add_Tick({
        $fadeT = [Math]::Min(1.0,([DateTime]::UtcNow - $fadeInStarted).TotalMilliseconds / 420.0)
        $fadeEase = 1.0 - [Math]::Pow(1.0 - $fadeT,3.0)
        $script:LauncherForm.Opacity = [Math]::Max(0.0,[Math]::Min(1.0,$fadeEase))
        if ($fadeT -ge 1.0) {
            $script:LauncherForm.Opacity = 1
            $fadeInTimer.Stop()
            $fadeInTimer.Dispose()
        }
    }.GetNewClosure())
    $fadeInTimer.Start()
    Pump-AMRLauncherUI

    Write-AMRLauncherLog 'Starting AMR Tool-Pro premium bootstrap.'
    Set-AMRLauncherProgress -Percent 0 -Status 'Getting everything ready for you...' -Detail 'Connecting securely to GitHub...'
    # Telemetry consent is intentionally deferred until after the main app is visible.
    # Nothing related to consent, collection, or networking can delay the app launch.
    # Local-first startup: a previously committed immutable version is trusted
    # from its locally saved GitHub-verified manifest. Do not contact GitHub or
    # re-hash the full application/DLL payload before opening an already verified
    # installation. A separate source check is intentionally not on this path.
    $remoteTree = $null
    $sourceComparisonAvailable = $false
    $sourceComparisonError = $null
    $localMatchesSource = $false
    $script:AMRLocalFastPath = $false
    $savedManifestPath = Join-Path $installRoot '.amr-runtime-state.json'
    if ($currentState -and (Test-Path -LiteralPath $savedManifestPath -PathType Leaf)) {
        try {
            $savedState = Get-Content -LiteralPath $savedManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            $savedMap = @{}
            foreach ($property in $savedState.files.PSObject.Properties) { $savedMap[$property.Name] = ([string]$property.Value).ToLowerInvariant() }
            $validLocalState = ([string]$savedState.repository -eq '3mr10aa/Tool-Pro' -and [string]$savedState.branch -eq 'main' -and
                [string]$currentState.repository -eq '3mr10aa/Tool-Pro' -and [string]$currentState.branch -eq 'main' -and
                [string]$savedState.commit -eq [string]$currentState.commit -and
                [string]$currentState.versionId -match '^[a-fA-F0-9]{40}(-[a-fA-F0-9]{8})?$')
            foreach ($relative in $expected.Keys) {
                $candidate = Join-Path $installRoot ($relative -replace '/', '\\')
                if (-not (Test-Path -LiteralPath $candidate -PathType Leaf) -or $savedMap[$relative] -notmatch '^[a-f0-9]{40}$') { $validLocalState = $false; break }
            }
            $savedIconBlob = ([string]$savedState.iconGitBlobSha1).ToLowerInvariant()
            if ($savedIconBlob -notmatch '^[a-f0-9]{40}$') { $validLocalState = $false }
            if ($validLocalState) {
                $savedMap['Icons.zip'] = $savedIconBlob
                $remoteTree = [pscustomobject]@{ Commit=[string]$savedState.commit; Files=$savedMap }
                $localMatchesSource = $true
                $script:AMRLocalFastPath = $true
                Write-AMRLauncherLog ('Local-first mode: selected committed runtime ' + [string]$currentState.versionId + '; skipped live GitHub requests and full runtime hashing.')
                Set-AMRLauncherProgress -Percent 78 -Status 'Opening your installed AMR runtime...' -Detail 'Using your previously verified local version.'
            }
        } catch {
            $localMatchesSource = $false
            $script:AMRLocalFastPath = $false
            Write-AMRLauncherLog ('Local runtime state could not be trusted; falling back to full source verification. ' + $_.Exception.Message)
        }
    }

    if (-not $localMatchesSource) {
        try {
            Set-AMRLauncherProgress -Percent 3 -Status 'Checking your local AMR runtime...' -Detail 'Verifying the installed version against GitHub...'
            $remoteTree = Get-AMRRemoteTree
            $sourceComparisonAvailable = $true
            Write-AMRLauncherLog ('GitHub source tree fetched. Commit=' + $remoteTree.Commit)
        } catch {
            $sourceComparisonError = $_.Exception.Message
            Write-AMRLauncherLog ('GitHub source comparison unavailable: ' + $sourceComparisonError)
        }
    }

    if (-not $localMatchesSource -and $sourceComparisonAvailable) {
        $localMatchesSource = Test-AMRRuntimeAgainstManifest -Root $installRoot -Manifest $remoteTree.Files
    } elseif (-not $localMatchesSource) {
        # Offline fallback: only run a runtime that was previously verified against
        # GitHub and whose current bytes still match that saved source manifest.
        $savedManifestPath = Join-Path $installRoot '.amr-runtime-state.json'
        if (Test-Path -LiteralPath $savedManifestPath -PathType Leaf) {
            try {
                $savedState = Get-Content -LiteralPath $savedManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $savedMap = @{}
                foreach ($property in $savedState.files.PSObject.Properties) { $savedMap[$property.Name] = [string]$property.Value }
                if ($savedState.iconGitBlobSha1 -match '^[a-fA-F0-9]{40}$') {
                    $savedMap['Icons.zip'] = ([string]$savedState.iconGitBlobSha1).ToLowerInvariant()
                }
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

    $remoteIconBlob = [string]$remoteTree.Files['Icons.zip']
    if ($remoteIconBlob -notmatch '^[a-f0-9]{40}$') { throw 'GitHub did not provide a valid Icons.zip Git blob fingerprint.' }

    # Resolve the icon directory by its content fingerprint. Existing icon generations
    # remain untouched; app versions point to the matching generation through a junction.
    $iconsPath = $null
    $priorIconsPath = $null
    $iconCacheMatchesSource = $false
    $iconCacheChecked = $false
    if ($currentState -and $currentState.iconPath) {
        $savedIconPath = [string]$currentState.iconPath
        if ($savedIconPath -eq 'Icons' -or $savedIconPath -match '^Shared\\IconVersions\\[a-fA-F0-9]{40}(-[a-fA-F0-9]{8})?$') {
            $savedCandidate = Join-Path $runtimeRoot ($savedIconPath -replace '/', '\')
            if (Test-Path -LiteralPath $savedCandidate -PathType Container) {
                $iconsPath = $savedCandidate
                $priorIconsPath = $savedCandidate
            }
        }
    }
    if (-not $iconsPath) {
        $legacyIconsCandidate = Join-Path $runtimeRoot 'Icons'
        if (Test-AMRIconCacheMatchesSource -IconDirectory $legacyIconsCandidate -SourceBlob $remoteIconBlob -Minimum 100 -TrustRecordedFingerprint:$script:AMRLocalFastPath) {
            $iconsPath = $legacyIconsCandidate
            $priorIconsPath = $legacyIconsCandidate
            $iconCacheMatchesSource = $true
            $iconCacheChecked = $true
            Write-AMRLauncherLog 'Reusing the existing verified legacy icon cache in place; no migration or extraction is required.'
        } else {
            $iconsPath = Join-Path $iconVersionsRoot $remoteIconBlob
        }
    }
    if (-not $iconCacheChecked) {
        $iconCacheMatchesSource = Test-AMRIconCacheMatchesSource -IconDirectory $iconsPath -SourceBlob $remoteIconBlob -Minimum 100 -TrustRecordedFingerprint:$script:AMRLocalFastPath
    }
    if (-not $iconCacheMatchesSource -and (Test-Path -LiteralPath $iconsPath -PathType Container)) {
        # Preserve a damaged/incomplete generation instead of overwriting or deleting it.
        if (-not $priorIconsPath) { $priorIconsPath = $iconsPath }
        $iconsPath = Join-Path $iconVersionsRoot ($remoteIconBlob + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    }

    # Migrate user-installed icon data only when switching from a legacy icon folder
    # to a shared content-addressed generation, and only once after successful copying.
    $legacyIconRoot = Join-Path $runtimeRoot 'Icons'
    $usesSharedIconGeneration = -not [string]::Equals([IO.Path]::GetFullPath($iconsPath).TrimEnd('\'),[IO.Path]::GetFullPath($legacyIconRoot).TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)
    $legacyProgramDataInstalledIcons = Join-Path $env:ProgramData 'AMR-Utility\Icons\LocalInstalled'
    $legacyRuntimeInstalledIcons = Join-Path $legacyIconRoot 'LocalInstalled'
    $needsProgramDataIconMigration = (-not (Test-Path -LiteralPath $legacyRuntimeInstalledIcons -PathType Container)) -and (Test-Path -LiteralPath $legacyProgramDataInstalledIcons -PathType Container)
    $localInstalledMigrationMarker = Join-Path $sharedRoot '.local-installed-migrated'
    if (($usesSharedIconGeneration -or $needsProgramDataIconMigration) -and -not (Test-Path -LiteralPath $localInstalledMigrationMarker -PathType Leaf)) {
        $legacyInstalledCandidates = @(
            $legacyProgramDataInstalledIcons,
            $legacyRuntimeInstalledIcons
        )
        if ($priorIconsPath) { $legacyInstalledCandidates += (Join-Path $priorIconsPath 'LocalInstalled') }
        $migrationSucceeded = $true
        foreach ($legacyInstalled in $legacyInstalledCandidates) {
            if (-not (Test-Path -LiteralPath $legacyInstalled -PathType Container)) { continue }
            try {
                $legacyAttributes = [System.IO.File]::GetAttributes($legacyInstalled)
                if (($legacyAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                foreach ($entry in (Get-ChildItem -LiteralPath $legacyInstalled -Force -ErrorAction Stop)) {
                    $targetEntry = Join-Path $localInstalledIconsRoot $entry.Name
                    if (-not (Test-Path -LiteralPath $targetEntry)) {
                        Copy-Item -LiteralPath $entry.FullName -Destination $localInstalledIconsRoot -Recurse -Force -ErrorAction Stop
                    }
                }
                Write-AMRLauncherLog ('Preserved legacy LocalInstalled icon data from: ' + $legacyInstalled)
            } catch {
                $migrationSucceeded = $false
                Write-AMRLauncherLog ('LocalInstalled icon migration warning: ' + $_.Exception.Message)
            }
        }
        if ($migrationSucceeded) {
            [System.IO.File]::WriteAllText($localInstalledMigrationMarker,[DateTime]::UtcNow.ToString('o'),(New-Object System.Text.UTF8Encoding($false)))
        }
    }

    $needsIconExtraction = -not $iconCacheMatchesSource
    if ($iconCacheMatchesSource) {
        Write-AMRLauncherLog ('Icon cache fingerprint and recorded file count match GitHub Icons.zip (' + $remoteIconBlob + '); skipping download and extraction.')
    } elseif (Test-AMRIconCacheUsable -IconDirectory $iconsPath -Minimum 100) {
        Write-AMRLauncherLog 'An icon folder exists but its source fingerprint or recorded completeness check failed; preserving it and preparing a clean generation.'
    } else {
        Write-AMRLauncherLog 'The verified icon generation is missing or incomplete; extraction is required.'
    }
    if ($localMatchesSource -and $needsIconExtraction) { $localMatchesSource = $false }
    $expectedIconRelativePath = [string]$iconsPath
    if ($expectedIconRelativePath.StartsWith($runtimeRoot,[StringComparison]::OrdinalIgnoreCase)) {
        $expectedIconRelativePath = $expectedIconRelativePath.Substring($runtimeRoot.Length).TrimStart('\')
    }
    $pointerIconMatches = ($currentState -and [string]::Equals([string]$currentState.iconPath,$expectedIconRelativePath,[StringComparison]::OrdinalIgnoreCase))
    $legacyRuntimeActive = [string]::Equals([IO.Path]::GetFullPath($installRoot).TrimEnd('\'),[IO.Path]::GetFullPath($runtimeRoot).TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)
    $legacyIconLinkMatches = [string]::Equals([IO.Path]::GetFullPath((Join-Path $installRoot 'Icons')).TrimEnd('\'),[IO.Path]::GetFullPath($iconsPath).TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)
    $needsIconLinkRepair = $false
    if ($localMatchesSource -and $currentState -and -not $pointerIconMatches) {
        $localMatchesSource = $false
        $needsIconLinkRepair = $true
        Write-AMRLauncherLog 'The active runtime pointer does not reference the selected verified icon generation; preparing a new immutable runtime link.'
    }
    if ($localMatchesSource -and $legacyRuntimeActive -and -not $legacyIconLinkMatches) {
        $localMatchesSource = $false
        $needsIconLinkRepair = $true
        Write-AMRLauncherLog 'The legacy runtime icon directory does not match the verified shared icon generation; preparing a version with the correct junction.'
    }

    if ($localMatchesSource) {
        $appPath = Join-Path $installRoot 'AMR_Windows_Utility_V1.ps1'
        $dllCoreLocal = Join-Path $installRoot 'AMR_WebView2\Microsoft.Web.WebView2.Core.dll'
        $dllWpfLocal = Join-Path $installRoot 'AMR_WebView2\Microsoft.Web.WebView2.Wpf.dll'
        $iconLink = Join-Path $installRoot 'Icons'
        if (-not (Test-Path -LiteralPath $appPath -PathType Leaf) -or -not (Test-Path -LiteralPath $dllCoreLocal -PathType Leaf) -or -not (Test-Path -LiteralPath $dllWpfLocal -PathType Leaf)) {
            throw 'The local runtime passed source comparison but failed the required runtime layout check.'
        }
        if (-not (Test-Path -LiteralPath $iconLink -PathType Container)) {
            throw 'The selected runtime has no local Icons directory/junction.'
        }
        Set-AMRLauncherProgress -Percent 92 -Status 'Your local AMR runtime is ready...' -Detail 'Launching the previously verified local version without waiting for GitHub.'
        Write-AMRLauncherLog 'Local runtime accepted from its saved verified manifest; skipping GitHub comparison, downloads, staging, and replacement for this launch.'
        $stageRoot = $null
    } else {
        Set-AMRLauncherProgress -Percent 8 -Status 'A newer or different runtime was found...' -Detail 'Preparing an isolated version without touching the active runtime...'
        New-Item -ItemType Directory -Path $versionsRoot,$sharedRoot,$iconVersionsRoot,$localInstalledIconsRoot -Force | Out-Null
        $stageRoot = Join-Path $versionsRoot ('.staging-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null

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
        if ($fileCount -lt 1 -and -not $needsIconExtraction -and -not $needsIconLinkRepair) { throw 'Runtime comparison returned an inconsistent update decision.' }
        $extractIconsNow = $needsIconExtraction
        $downloadPaths = @($changed)

        # Copy only the five runtime components. The archive is considered only when
        # extraction is actually needed, so ordinary launches never hash or download it.
        Copy-AMRRuntimeToStage -Source $installRoot -Destination $stageRoot
        if ($extractIconsNow) {
            $archiveReused = $false
            $archiveCandidates = @(
                (Join-Path $installRoot 'Icons.zip'),
                (Join-Path $runtimeRoot 'Icons.zip')
            ) | Select-Object -Unique
            foreach ($archiveCandidate in $archiveCandidates) {
                if (-not (Test-Path -LiteralPath $archiveCandidate -PathType Leaf)) { continue }
                try {
                    $candidateBlob = Get-AMRGitBlobSha1 -Path $archiveCandidate
                    if ($candidateBlob -eq $remoteIconBlob) {
                        Copy-Item -LiteralPath $archiveCandidate -Destination (Join-Path $stageRoot 'Icons.zip') -Force -ErrorAction Stop
                        $archiveReused = $true
                        Write-AMRLauncherLog ('Reusing locally cached Icons.zip after Git blob verification: ' + $archiveCandidate)
                        break
                    }
                    Write-AMRLauncherLog ('Ignoring a local Icons.zip whose Git blob does not match the current source: ' + $archiveCandidate)
                } catch {
                    Write-AMRLauncherLog ('Could not reuse local Icons.zip; a verified download will be used. ' + $_.Exception.Message)
                }
            }
            if (-not $archiveReused) { $downloadPaths += 'Icons.zip' }
        }
        try {
            Invoke-AMRParallelRuntimePreparation -RelativePaths $downloadPaths -StageRoot $stageRoot -ExpectedBlobs $remoteTree.Files -ExtractIcons $extractIconsNow
        } catch {
            $parallelError = $_.Exception.Message
            Write-AMRLauncherLog ('Parallel preparation reported a failure; checking whether the required runtime files can still be completed safely. ' + $parallelError)
            # Keep icon failures non-fatal: the application has its own verified
            # ProgramData icon bootstrap. Runtime files are still mandatory.
            $missingRuntime = @()
            foreach ($relative in $changed) {
                $candidate = Join-Path $stageRoot ($relative -replace '/', '\')
                $isVerified = $false
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    try { $isVerified = ((Get-AMRGitBlobSha1 -Path $candidate) -eq [string]$remoteTree.Files[$relative]) } catch {}
                }
                if (-not $isVerified) { $missingRuntime += $relative }
            }
            if ($missingRuntime.Count -gt 0) {
                Write-AMRLauncherLog ('Retrying only runtime files that are still missing or unverified: ' + ($missingRuntime -join ', '))
                Invoke-AMRParallelRuntimePreparation -RelativePaths $missingRuntime -StageRoot $stageRoot -ExpectedBlobs $remoteTree.Files -ExtractIcons $false
            }
            if (-not (Test-AMRRuntimeAgainstManifest -Root $stageRoot -Manifest $remoteTree.Files)) {
                throw ('Required runtime preparation failed integrity validation after retry. ' + $parallelError)
            }
            $script:AMRIconPreparationFailed = $true
            Write-AMRLauncherLog 'Runtime integrity is intact. Icon preparation was skipped after failure; the application icon worker will use its existing fallback.'
        }

        # Persist source identities only after every downloaded component passed Git blob verification.
        $stateFiles = [ordered]@{}
        foreach ($relative in $expected.Keys) { $stateFiles[$relative] = [string]$remoteTree.Files[$relative] }
        $state = [ordered]@{
            schemaVersion = 1
            repository = '3mr10aa/Tool-Pro'
            branch = 'main'
            commit = $remoteTree.Commit
            verifiedAtUtc = [DateTime]::UtcNow.ToString('o')
            iconGitBlobSha1 = $remoteIconBlob
            files = $stateFiles
        }
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

        # The launcher ICO extraction is optional and remains unchanged.
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

        # Publish extracted icons into a new immutable content-addressed folder.
        # Keep the verified ZIP and write the app's native cache metadata beside it;
        # this lets the elevated app reuse the same download instead of downloading it again.
        $stagedIcons = Join-Path $stageRoot 'Icons'
        $stagedArchive = Join-Path $stageRoot 'Icons.zip'
        $stagedMarkerPath = Join-Path $stagedIcons '.amr-icons-source.json'
        $stagedMarkerValid = $false
        if (Test-Path -LiteralPath $stagedMarkerPath -PathType Leaf) {
            try {
                $stagedMarker = Get-Content -LiteralPath $stagedMarkerPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $stagedMarkerValid = (([string]$stagedMarker.sourceGitBlobSha1).ToLowerInvariant() -eq $remoteIconBlob)
            } catch {}
        }
        $stagedIconsReady = $extractIconsNow -and
            (Test-AMRIconCacheUsable -IconDirectory $stagedIcons -Minimum 100) -and
            (Test-Path -LiteralPath (Join-Path $stagedIcons 'manifest.json') -PathType Leaf) -and $stagedMarkerValid
        if ($stagedIconsReady) {
            if (Test-Path -LiteralPath $iconsPath -PathType Container) {
                $iconsPath = Join-Path $iconVersionsRoot ($remoteIconBlob + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
            }
            [System.IO.Directory]::Move($stagedIcons,$iconsPath)
            if (-not (Test-Path -LiteralPath $stagedArchive -PathType Leaf)) { throw 'Verified icon archive disappeared before cache publication.' }
            Copy-Item -LiteralPath $stagedArchive -Destination (Join-Path $iconsPath 'icons.zip') -Force -ErrorAction Stop
            $appImageExtensions = @('.png','.jpg','.jpeg','.jpe','.jfif','.bmp','.dib','.gif','.tif','.tiff','.ico','.webp','.wdp','.jxr','.hdp','.heic','.heif','.avif','.jp2','.j2k','.dds','.tga','.pcx','.ppm','.pgm','.pbm')
            $appImageCount = @(Get-ChildItem -LiteralPath $iconsPath -File -ErrorAction Stop | Where-Object { $appImageExtensions -contains $_.Extension.ToLowerInvariant() -and $_.Length -gt 32 }).Count
            if ($appImageCount -lt 100) { throw 'The published icon generation does not meet the application cache minimum.' }
            $appCache = [ordered]@{
                schemaVersion = 2
                repository = '3mr10aa/Tool-Pro'
                branch = 'main'
                file = 'Icons.zip'
                source = ($repoRaw + '/Icons.zip')
                size = [long](Get-Item -LiteralPath (Join-Path $iconsPath 'icons.zip')).Length
                sha = $remoteIconBlob
                imageCount = $appImageCount
                manifest = 'manifest.json'
                manifestSchemaVersion = 1
                updatedUtc = [DateTime]::UtcNow.ToString('o')
            }
            [System.IO.File]::WriteAllText((Join-Path $iconsPath 'icons.cache.json'),($appCache | ConvertTo-Json -Depth 4),(New-Object System.Text.UTF8Encoding($false)))
            Remove-Item -LiteralPath $stagedArchive -Force -ErrorAction SilentlyContinue
            Write-AMRLauncherLog ('Published verified icon generation and application-native cache metadata: ' + $iconsPath)
        } elseif ($extractIconsNow) {
            Write-AMRLauncherLog 'Icon download or extraction was unavailable. Preserving any previous icon generation and allowing the application fallback to run.'
            if ($priorIconsPath -and (Test-Path -LiteralPath $priorIconsPath -PathType Container)) {
                $iconsPath = $priorIconsPath
            } else {
                New-Item -ItemType Directory -Path $iconsPath -Force | Out-Null
            }
        }
        if (-not (Test-Path -LiteralPath $iconsPath -PathType Container)) {
            New-Item -ItemType Directory -Path $iconsPath -Force | Out-Null
        }

        # Preserve LocalInstalled independently of the downloaded archive. A junction
        # lets every immutable icon generation share the same user-specific cache.
        $localLink = Join-Path $iconsPath 'LocalInstalled'
        if (-not (Test-Path -LiteralPath $localLink)) {
            New-Item -ItemType Junction -Path $localLink -Target $localInstalledIconsRoot -ErrorAction Stop | Out-Null
        }
        $stageIconLink = Join-Path $stageRoot 'Icons'
        if (Test-Path -LiteralPath $stageIconLink) { Remove-Item -LiteralPath $stageIconLink -Force -Recurse -ErrorAction Stop }
        New-Item -ItemType Junction -Path $stageIconLink -Target $iconsPath -ErrorAction Stop | Out-Null

        # Each app version has a unique directory. Only this unused staging directory
        # is renamed; the active Runtime and its loaded WebView2 files are never moved.
        $versionId = ([string]$remoteTree.Commit).ToLowerInvariant() + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
        $finalVersionRoot = Join-Path $versionsRoot $versionId
        [System.IO.Directory]::Move($stageRoot,$finalVersionRoot)
        $stageRoot = $null
        $installRoot = $finalVersionRoot
        $pendingVersionCommit = $true
        $pendingVersionId = $versionId
        $pendingIconRelativePath = [string]$iconsPath
        if ($pendingIconRelativePath.StartsWith($runtimeRoot,[StringComparison]::OrdinalIgnoreCase)) {
            $pendingIconRelativePath = $pendingIconRelativePath.Substring($runtimeRoot.Length).TrimStart('\')
        }
        Write-AMRLauncherLog ('Prepared isolated runtime version: ' + $versionId + '. Existing versions were not moved or deleted.')
    }

    $appPath = Join-Path $installRoot 'AMR_Windows_Utility_V1.ps1'
    # Load branding from the verified application source on EVERY launch,
    # including cache-hit launches where no runtime staging occurs.
    try {
        if (Test-Path -LiteralPath $appPath -PathType Leaf) {
            $iconReader = New-Object System.IO.StreamReader($appPath,(New-Object System.Text.UTF8Encoding($false,$true)),$true)
            try { $appTextForLauncherIcon = $iconReader.ReadToEnd() } finally { $iconReader.Dispose() }
            $iconMatchForLauncher = [regex]::Match($appTextForLauncherIcon, '\$amrIconBytes\s*=\s*\[Convert\]::FromBase64String\(''([^'']+)''\)')
            if ($iconMatchForLauncher.Success) {
                $launcherIconBytes = [Convert]::FromBase64String($iconMatchForLauncher.Groups[1].Value)
                if ($launcherIconBytes.Length -ge 22 -and $launcherIconBytes[0] -eq 0 -and $launcherIconBytes[1] -eq 0 -and $launcherIconBytes[2] -eq 1) {
                    $launcherFrameCount = [BitConverter]::ToUInt16($launcherIconBytes,4)
                    $launcherChosenFrame = $null
                    for ($frameIndex = 0; $frameIndex -lt $launcherFrameCount; $frameIndex++) {
                        $frameEntry = 6 + (16 * $frameIndex)
                        if (($frameEntry + 16) -gt $launcherIconBytes.Length) { break }
                        $frameW = [int]$launcherIconBytes[$frameEntry]; if ($frameW -eq 0) { $frameW = 256 }
                        $frameH = [int]$launcherIconBytes[$frameEntry + 1]; if ($frameH -eq 0) { $frameH = 256 }
                        $frameLength = [BitConverter]::ToUInt32($launcherIconBytes,$frameEntry + 8)
                        $frameOffset = [BitConverter]::ToUInt32($launcherIconBytes,$frameEntry + 12)
                        if ($frameW -ge 32 -and $frameH -ge 32 -and $frameLength -gt 0 -and ($frameOffset + $frameLength) -le $launcherIconBytes.Length) {
                            if ($null -eq $launcherChosenFrame -or ($frameW * $frameH) -gt ($launcherChosenFrame.Width * $launcherChosenFrame.Height)) {
                                $launcherChosenFrame = @{ Width=$frameW; Height=$frameH; Length=[int]$frameLength; Offset=[int]$frameOffset }
                            }
                        }
                    }
                    if ($null -ne $launcherChosenFrame) {
                        $launcherPngBytes = New-Object byte[] $launcherChosenFrame.Length
                        [Buffer]::BlockCopy($launcherIconBytes,$launcherChosenFrame.Offset,$launcherPngBytes,0,$launcherPngBytes.Length)
                        $launcherPngStream = New-Object System.IO.MemoryStream(,$launcherPngBytes)
                        try {
                            $launcherSourceImage = [System.Drawing.Image]::FromStream($launcherPngStream)
                            try {
                                $captionIcon.Image = New-Object System.Drawing.Bitmap($launcherSourceImage)
                                $launcherIcoBytes = New-Object byte[] (22 + $launcherPngBytes.Length)
                                $launcherIcoBytes[2]=1; $launcherIcoBytes[4]=1
                                $launcherIcoBytes[6]=[byte]($launcherChosenFrame.Width -band 255)
                                $launcherIcoBytes[7]=[byte]($launcherChosenFrame.Height -band 255)
                                $launcherIcoBytes[10]=1; $launcherIcoBytes[12]=32
                                [Buffer]::BlockCopy([BitConverter]::GetBytes([uint32]$launcherPngBytes.Length),0,$launcherIcoBytes,14,4)
                                [Buffer]::BlockCopy([BitConverter]::GetBytes([uint32]22),0,$launcherIcoBytes,18,4)
                                [Buffer]::BlockCopy($launcherPngBytes,0,$launcherIcoBytes,22,$launcherPngBytes.Length)
                                $launcherIcoStream = New-Object System.IO.MemoryStream(,$launcherIcoBytes)
                                try { $form.Icon = New-Object System.Drawing.Icon($launcherIcoStream) } finally { $launcherIcoStream.Dispose() }
                            } finally { $launcherSourceImage.Dispose() }
                        } finally { $launcherPngStream.Dispose() }
                        Write-AMRLauncherLog ('Loaded launcher branding icon from verified application source ({0}x{1}).' -f $launcherChosenFrame.Width,$launcherChosenFrame.Height)
                    } else { Write-AMRLauncherLog 'Application icon data was found, but no suitable ICO frame was available.' }
                } else { Write-AMRLauncherLog 'Application icon data was not a valid ICO stream.' }
            } else { Write-AMRLauncherLog 'Application source did not contain the expected embedded AMR icon declaration.' }
        }
    } catch { Write-AMRLauncherLog ('Launcher branding icon load failed: ' + $_.Exception.Message) }

    $powershellExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) { $powershellExe = 'powershell.exe' }

    # The app reads its icon cache from ProgramData, while launcher preparation
    # happens safely under LocalAppData. Bridge the two in the SAME elevated
    # process used to launch the app, so this does not add a second UAC prompt.
    $launchBootstrapPath = Join-Path $env:TEMP ('AMR-ToolPro-Launch-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $launchBootstrap = @'
$ErrorActionPreference = 'Stop'
$sourceIcons = __ICON_SOURCE__
$appPath = __APP_PATH__
$logPath = __LOG_PATH__
$expectedIconBlob = '__ICON_BLOB__'
function Write-AMRLaunchBootstrapLog {
    param([string]$Message)
    try { Add-Content -LiteralPath $logPath -Encoding UTF8 -Value ('[' + [DateTime]::UtcNow.ToString('o') + '] ' + $Message) } catch {}
}
function Get-AMRLaunchBootstrapGitBlobSha1 {
    param([string]$Path)
    $info = Get-Item -LiteralPath $Path -ErrorAction Stop
    $header = [Text.Encoding]::ASCII.GetBytes(('blob {0}' -f $info.Length) + [char]0)
    $sha = [Security.Cryptography.SHA1]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try {
        [void]$sha.TransformBlock($header,0,$header.Length,$header,0)
        $buffer = New-Object byte[] 65536
        while (($read=$stream.Read($buffer,0,$buffer.Length)) -gt 0) { [void]$sha.TransformBlock($buffer,0,$read,$buffer,0) }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0),0,0)
        return ([BitConverter]::ToString($sha.Hash)).Replace('-','').ToLowerInvariant()
    } finally { $stream.Dispose(); $sha.Dispose() }
}
try {
    $sourceZip = Join-Path $sourceIcons 'icons.zip'
    $sourceMetaPath = Join-Path $sourceIcons 'icons.cache.json'
    $sourceManifestPath = Join-Path $sourceIcons 'manifest.json'
    $sourceMeta = $null
    if ((Test-Path -LiteralPath $sourceZip -PathType Leaf) -and
        (Test-Path -LiteralPath $sourceMetaPath -PathType Leaf) -and
        (Test-Path -LiteralPath $sourceManifestPath -PathType Leaf)) {
        $sourceMeta = Get-Content -LiteralPath $sourceMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $sourceManifest = Get-Content -LiteralPath $sourceManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$sourceManifest.schemaVersion -ne 1 -or
            [int]$sourceManifest.iconCount -ne [int]$sourceMeta.imageCount -or
            @($sourceManifest.entries.PSObject.Properties).Count -ne [int]$sourceMeta.imageCount) {
            throw 'The staged icon manifest is incomplete or does not match its cache metadata.'
        }
    }
    if ($sourceMeta -and [int]$sourceMeta.schemaVersion -ge 2 -and
        [string]$sourceMeta.repository -eq '3mr10aa/Tool-Pro' -and
        [string]$sourceMeta.branch -eq 'main' -and
        [string]$sourceMeta.file -eq 'Icons.zip' -and
        ([string]$sourceMeta.sha).ToLowerInvariant() -eq $expectedIconBlob -and
        [long]$sourceMeta.size -eq (Get-Item -LiteralPath $sourceZip).Length) {

        $destinationIcons = Join-Path $env:ProgramData 'AMR-Utility\Icons'
        New-Item -ItemType Directory -Path $destinationIcons -Force | Out-Null
        $destinationZip = Join-Path $destinationIcons 'icons.zip'
        $destinationMetaPath = Join-Path $destinationIcons 'icons.cache.json'
        $destinationMatches = $false
        try {
            $destinationManifestPath = Join-Path $destinationIcons 'manifest.json'
            if ((Test-Path -LiteralPath $destinationZip -PathType Leaf) -and
                (Test-Path -LiteralPath $destinationMetaPath -PathType Leaf) -and
                (Test-Path -LiteralPath $destinationManifestPath -PathType Leaf)) {
                $existingMeta = Get-Content -LiteralPath $destinationMetaPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $existingManifest = Get-Content -LiteralPath $destinationManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $existingCount = @(Get-ChildItem -LiteralPath $destinationIcons -File -ErrorAction Stop |
                    Where-Object { @('.png','.jpg','.jpeg','.jpe','.jfif','.bmp','.dib','.gif','.tif','.tiff','.ico','.webp','.wdp','.jxr','.hdp','.heic','.heif','.avif','.jp2','.j2k','.dds','.tga','.pcx','.ppm','.pgm','.pbm') -contains $_.Extension.ToLowerInvariant() -and $_.Length -gt 32 }).Count
                $destinationMatches = ([string]$existingMeta.repository -eq '3mr10aa/Tool-Pro' -and
                    [string]$existingMeta.branch -eq 'main' -and [string]$existingMeta.file -eq 'Icons.zip' -and
                    ([string]$existingMeta.sha).ToLowerInvariant() -eq $expectedIconBlob -and
                    [long]$existingMeta.size -eq (Get-Item -LiteralPath $destinationZip).Length -and
                    $existingCount -eq [int]$sourceMeta.imageCount -and
                    [int]$existingManifest.schemaVersion -eq 1 -and
                    [int]$existingManifest.iconCount -eq [int]$sourceMeta.imageCount -and
                    @($existingManifest.entries.PSObject.Properties).Count -eq [int]$sourceMeta.imageCount)
            }
        } catch { $destinationMatches = $false }

        if (-not $destinationMatches) {
            # Invalidate the old marker before touching any image or archive. If the
            # copy is interrupted, the app will detect a cold cache and run its fallback.
            if (Test-Path -LiteralPath $destinationMetaPath -PathType Leaf) {
                Remove-Item -LiteralPath $destinationMetaPath -Force -ErrorAction Stop
            }
            $supported = @('.png','.jpg','.jpeg','.jpe','.jfif','.bmp','.dib','.gif','.tif','.tiff','.ico','.webp','.wdp','.jxr','.hdp','.heic','.heif','.avif','.jp2','.j2k','.dds','.tga','.pcx','.ppm','.pgm','.pbm')
            $sourceImages = @(Get-ChildItem -LiteralPath $sourceIcons -File -ErrorAction Stop |
                Where-Object { $supported -contains $_.Extension.ToLowerInvariant() -and $_.Length -gt 32 })
            if ($sourceImages.Count -lt [int]$sourceMeta.imageCount) { throw 'Launcher icon generation is incomplete; app fallback will be used.' }
            # ProgramData\AMR-Utility\Icons is the archive-owned top-level cache.
            # Remove stale archive images before publishing the new generation;
            # LocalInstalled remains isolated in its own subfolder and is untouched.
            Get-ChildItem -LiteralPath $destinationIcons -File -ErrorAction Stop |
                Where-Object { $supported -contains $_.Extension.ToLowerInvariant() } |
                Remove-Item -Force -ErrorAction Stop
            foreach ($imageFile in $sourceImages) {
                $target = Join-Path $destinationIcons $imageFile.Name
                $temporary = $target + '.amr-launcher-new'
                Copy-Item -LiteralPath $imageFile.FullName -Destination $temporary -Force -ErrorAction Stop
                Move-Item -LiteralPath $temporary -Destination $target -Force -ErrorAction Stop
            }
            $manifestTemporary = $destinationManifestPath + '.amr-launcher-new'
            Copy-Item -LiteralPath $sourceManifestPath -Destination $manifestTemporary -Force -ErrorAction Stop
            Move-Item -LiteralPath $manifestTemporary -Destination $destinationManifestPath -Force -ErrorAction Stop
            $zipTemporary = $destinationZip + '.amr-launcher-new'
            Copy-Item -LiteralPath $sourceZip -Destination $zipTemporary -Force -ErrorAction Stop
            if ((Get-AMRLaunchBootstrapGitBlobSha1 -Path $zipTemporary) -ne $expectedIconBlob) {
                Remove-Item -LiteralPath $zipTemporary -Force -ErrorAction SilentlyContinue
                throw 'ProgramData icon archive failed its GitHub blob verification; app fallback will be used.'
            }
            Move-Item -LiteralPath $zipTemporary -Destination $destinationZip -Force -ErrorAction Stop
            $metaTemporary = $destinationMetaPath + '.amr-launcher-new'
            Copy-Item -LiteralPath $sourceMetaPath -Destination $metaTemporary -Force -ErrorAction Stop
            Move-Item -LiteralPath $metaTemporary -Destination $destinationMetaPath -Force -ErrorAction Stop
            Write-AMRLaunchBootstrapLog ('Published verified launcher icon cache into ProgramData: ' + $sourceImages.Count + ' images.')
        } else {
            Write-AMRLaunchBootstrapLog 'ProgramData icon cache matches the saved source fingerprint and metadata; skipping archive re-hash and copy.'
        }
    } else {
        Write-AMRLaunchBootstrapLog 'No complete verified launcher icon generation was available; continuing so the app icon fallback can run.'
    }
} catch {
    Write-AMRLaunchBootstrapLog ('Non-fatal icon cache handoff warning; app fallback remains enabled: ' + $_.Exception.Message)
}
try {
    # Run the app in a fresh Windows PowerShell process using -File, matching the
    # previously working direct-launch path. Do not invoke it with '&' inside this
    # bootstrap: the app has its own STA/admin self-bootstrap and an 'exit' there
    # would terminate this wrapper before the launcher can observe the app window.
    $appPowerShell = Join-Path $PSHOME 'powershell.exe'
    $quotedAppPath = '"' + $appPath.Replace('"','""') + '"'
    $appArguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File ' + $quotedAppPath
    $child = Start-Process -FilePath $appPowerShell -ArgumentList $appArguments -WorkingDirectory (Split-Path -Parent $appPath) -WindowStyle Hidden -PassThru -ErrorAction Stop
    [System.IO.File]::WriteAllText(__APP_PID_FILE__,[string]$child.Id,(New-Object System.Text.UTF8Encoding($false)))
    $child.WaitForExit()
} finally {
    try { Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue } catch {}
}
'@
    $launchBootstrap = $launchBootstrap.Replace('__ICON_SOURCE__', (ConvertTo-AMRPSSingleQuoted ([string]$iconsPath)))
    $launchBootstrap = $launchBootstrap.Replace('__APP_PATH__', (ConvertTo-AMRPSSingleQuoted $appPath))
    $launchBootstrap = $launchBootstrap.Replace('__LOG_PATH__', (ConvertTo-AMRPSSingleQuoted $logPath))
    $launchBootstrap = $launchBootstrap.Replace('__APP_PID_FILE__', (ConvertTo-AMRPSSingleQuoted $appPidMarkerPath))
    $launchBootstrap = $launchBootstrap.Replace('__ICON_BLOB__', ([string]$remoteIconBlob).ToLowerInvariant())
    [System.IO.File]::WriteAllText($launchBootstrapPath,$launchBootstrap,(New-Object System.Text.UTF8Encoding($false)))
    $quotedBootstrap = '"' + $launchBootstrapPath.Replace('"','""') + '"'
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File ' + $quotedBootstrap
    Set-AMRLauncherProgress -Percent 94 -Status 'Launching AMR Tool-Pro...' -Detail 'Waiting for the main application window to appear...'
    Write-AMRLauncherLog ('Launching verified app through the elevated icon-cache handoff from ' + $appPath)
    # The main application requires Administrator privileges. Its own bootstrap
    # relaunches itself with RunAs when started unelevated, then exits the first
    # PowerShell process. Launch elevated here so the launcher tracks the real
    # application process instead of mistaking that intentional self-relaunch
    # for an application crash. Windows will show the standard UAC consent prompt.
    $bootstrapProcess = Start-Process -FilePath $powershellExe -ArgumentList $arguments -WorkingDirectory $installRoot -WindowStyle Hidden -Verb RunAs -PassThru -ErrorAction Stop

    # The elevated bootstrap writes the PID of the separate -STA -File app process
    # only after the icon-cache handoff is complete. Track that real app process,
    # not the short-lived wrapper process.
    $pidDeadline = [DateTime]::UtcNow.AddSeconds(45)
    while ([DateTime]::UtcNow -lt $pidDeadline -and -not (Test-Path -LiteralPath $appPidMarkerPath -PathType Leaf)) {
        Pump-AMRLauncherUI
        $bootstrapProcess.Refresh()
        if ($bootstrapProcess.HasExited) { throw 'The elevated launch bootstrap exited before starting the AMR application.' }
        Start-Sleep -Milliseconds 60
    }
    if (-not (Test-Path -LiteralPath $appPidMarkerPath -PathType Leaf)) { throw 'The elevated launch bootstrap did not report the AMR application process ID.' }
    $appPidText = (Get-Content -LiteralPath $appPidMarkerPath -Raw -ErrorAction Stop).Trim()
    $appPid = 0
    if (-not [int]::TryParse($appPidText,[ref]$appPid) -or $appPid -le 0) { throw 'The elevated launch bootstrap reported an invalid application process ID.' }
    $appProcess = Get-Process -Id $appPid -ErrorAction Stop

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

    if ($pendingVersionCommit) {
        try {
            $pointer = [ordered]@{
                schemaVersion = 1
                repository = '3mr10aa/Tool-Pro'
                branch = 'main'
                versionId = $pendingVersionId
                commit = [string]$remoteTree.Commit
                iconPath = $pendingIconRelativePath
                committedAtUtc = [DateTime]::UtcNow.ToString('o')
            }
            $pointerTemp = $currentStatePath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
            [System.IO.File]::WriteAllText($pointerTemp,($pointer | ConvertTo-Json -Depth 4),(New-Object System.Text.UTF8Encoding($false)))
            if (Test-Path -LiteralPath $currentStatePath -PathType Leaf) {
                [System.IO.File]::Replace($pointerTemp,$currentStatePath,$null)
            } else {
                [System.IO.File]::Move($pointerTemp,$currentStatePath)
            }
            Write-AMRLauncherLog ('Committed current runtime pointer after the new application window became visible: ' + $pendingVersionId)
        } catch {
            Write-AMRLauncherLog ('WARNING: new runtime started successfully, but current-version pointer could not be committed; previous pointer remains intact. ' + $_.Exception.Message)
            try { if ($pointerTemp -and (Test-Path -LiteralPath $pointerTemp)) { Remove-Item -LiteralPath $pointerTemp -Force -ErrorAction SilentlyContinue } } catch {}
        }
    }

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
        $ease = 1.0 - [Math]::Pow(1.0 - $t, 4.0)
        $x = [int][Math]::Round($startBounds.X + (($targetX - $startBounds.X) * $ease))
        $y = [int][Math]::Round($startBounds.Y + (($targetY - $startBounds.Y) * $ease))
        $w = [int][Math]::Round($startBounds.Width + (($targetW - $startBounds.Width) * $ease))
        $h = [int][Math]::Round($startBounds.Height + (($targetH - $startBounds.Height) * $ease))
        $form.SetBounds($x, $y, [Math]::Max(1, $w), [Math]::Max(1, $h))
        # Fade begins late, after the window has visibly expanded into the app footprint.
        if ($t -gt 0.70) {
            $fadeT = ($t - 0.70) / 0.30
            $form.Opacity = [Math]::Max(0.0, 1.0 - [Math]::Pow($fadeT, 1.65))
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

    # Keep extracted icons locally; refresh only when the verified GitHub archive fingerprint changes.
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
    if ($appPidMarkerPath -and (Test-Path -LiteralPath $appPidMarkerPath -PathType Leaf)) { Remove-Item -LiteralPath $appPidMarkerPath -Force -ErrorAction SilentlyContinue }
    if ($launchBootstrapPath -and -not $appProcess -and (Test-Path -LiteralPath $launchBootstrapPath -PathType Leaf)) {
        Remove-Item -LiteralPath $launchBootstrapPath -Force -ErrorAction SilentlyContinue
    }
}
