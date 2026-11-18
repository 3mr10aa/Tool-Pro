#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$TelemetryRoot,
    [Parameter(Mandatory=$true)][string]$LauncherVersion,
    [Parameter(Mandatory=$true)][string]$EndpointFileUrl,
    [switch]$DisableTelemetry
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:WorkerLog = Join-Path $TelemetryRoot 'telemetry-worker.log'
$mutex = $null
$hasMutex = $false

function Write-AMRTelemetryLog {
    param([string]$Message)
    try {
        if (-not (Test-Path -LiteralPath $TelemetryRoot -PathType Container)) {
            New-Item -ItemType Directory -Path $TelemetryRoot -Force | Out-Null
        }
        Add-Content -LiteralPath $script:WorkerLog -Encoding UTF8 -Value ('[{0}] {1}' -f [DateTime]::UtcNow.ToString('o'), $Message)
    } catch {}
}

function Get-AMRDeviceProfile {
    param([string]$InstallId)

    $computer = $null; $os = $null; $processors = @(); $gpus = @(); $disks = @(); $drivers = @()
    $bios = $null; $baseboard = $null
    try { $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop } catch {}
    try { $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop } catch {}
    try { $processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 2) } catch {}
    try { $gpus = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop | Select-Object -First 8) } catch {}
    try { $disks = @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop | Select-Object -First 16) } catch {}
    try { $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop } catch {}
    try { $baseboard = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction Stop } catch {}

    try {
        $drivers = @(
            Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop |
            Where-Object { $_.DeviceClass -in @('DISPLAY', 'NET', 'MEDIA', 'BLUETOOTH') } |
            Select-Object -First 100 |
            ForEach-Object {
                [ordered]@{
                    name = [string]$_.DeviceName
                    class = [string]$_.DeviceClass
                    provider = [string]$_.DriverProviderName
                    version = [string]$_.DriverVersion
                    date = [string]$_.DriverDate
                    inf = [string]$_.InfName
                }
            }
        )
    } catch { $drivers = @() }

    $cpuData = @(
        foreach ($cpu in $processors) {
            [ordered]@{
                name = [string]$cpu.Name
                manufacturer = [string]$cpu.Manufacturer
                cores = [int]$cpu.NumberOfCores
                logicalProcessors = [int]$cpu.NumberOfLogicalProcessors
                maxClockMHz = [int]$cpu.MaxClockSpeed
            }
        }
    )
    $gpuData = @(
        foreach ($gpu in $gpus) {
            [ordered]@{
                name = [string]$gpu.Name
                driverVersion = [string]$gpu.DriverVersion
                adapterRamGB = $(if ($gpu.AdapterRAM) { [Math]::Round(([double]$gpu.AdapterRAM / 1GB), 2) } else { $null })
                videoProcessor = [string]$gpu.VideoProcessor
            }
        }
    )
    $diskData = @(
        foreach ($disk in $disks) {
            [ordered]@{
                model = [string]$disk.Model
                interface = [string]$disk.InterfaceType
                mediaType = [string]$disk.MediaType
                sizeGB = $(if ($disk.Size) { [Math]::Round(([double]$disk.Size / 1GB), 1) } else { $null })
            }
        }
    )
    $ramGB = $null
    if ($computer -and $computer.TotalPhysicalMemory) {
        $ramGB = [Math]::Round(([double]$computer.TotalPhysicalMemory / 1GB), 1)
    }

    return [ordered]@{
        installId = $InstallId
        collectedAtUtc = [DateTime]::UtcNow.ToString('o')
        manufacturer = $(if ($computer) { [string]$computer.Manufacturer } else { $null })
        model = $(if ($computer) { [string]$computer.Model } else { $null })
        systemType = $(if ($computer) { [string]$computer.SystemType } else { $null })
        os = [ordered]@{
            caption = $(if ($os) { [string]$os.Caption } else { $null })
            version = $(if ($os) { [string]$os.Version } else { $null })
            build = $(if ($os) { [string]$os.BuildNumber } else { $null })
            architecture = $(if ($os) { [string]$os.OSArchitecture } else { $env:PROCESSOR_ARCHITECTURE })
        }
        cpu = $cpuData
        ramGB = $ramGB
        gpus = $gpuData
        storage = $diskData
        motherboard = $(if ($baseboard) { [ordered]@{ manufacturer = [string]$baseboard.Manufacturer; product = [string]$baseboard.Product } } else { $null })
        bios = [ordered]@{
            manufacturer = $(if ($bios) { [string]$bios.Manufacturer } else { $null })
            version = $(if ($bios) { [string]$bios.SMBIOSBIOSVersion } else { $null })
            releaseDate = $(if ($bios -and $bios.ReleaseDate) { ([DateTime]$bios.ReleaseDate).ToUniversalTime().ToString('yyyy-MM-dd') } else { $null })
        }
        drivers = $drivers
    }
}

function Get-AMRInstallSecret {
    param([string]$SecretPath)
    if (Test-Path -LiteralPath $SecretPath -PathType Leaf) {
        try {
            $existing = (Get-Content -LiteralPath $SecretPath -Raw -ErrorAction Stop).Trim()
            if ($existing -match '^[A-Fa-f0-9]{64}$') { return $existing.ToLowerInvariant() }
        } catch {}
    }
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $secret = ([BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
    [System.IO.File]::WriteAllText($SecretPath, $secret, (New-Object System.Text.UTF8Encoding($false)))
    return $secret
}

function Invoke-AMRForgetRequest {
    param([string]$Endpoint, [string]$InstallId, [string]$InstallSecret, [string]$ForgetPath)
    $forgetEndpoint = $Endpoint -replace '/collect/?$', '/forget'
    $body = [ordered]@{ installId = $InstallId; installSecret = $InstallSecret } | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $result = Invoke-RestMethod -Method Post -Uri $forgetEndpoint -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 8 -ErrorAction Stop
    if (-not ($result -and $result.ok -eq $true)) { throw 'Server did not confirm deletion.' }
    Remove-Item -LiteralPath (Join-Path $TelemetryRoot 'User count.json'), (Join-Path $TelemetryRoot 'pending-upload.json'), (Join-Path $TelemetryRoot 'device-id.txt'), (Join-Path $TelemetryRoot 'install-secret.txt'), $ForgetPath -Force -ErrorAction SilentlyContinue
    Write-AMRTelemetryLog 'A previously queued diagnostics deletion was confirmed by the server.'
}

try {
    if (-not (Test-Path -LiteralPath $TelemetryRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $TelemetryRoot -Force | Out-Null
    }

    $consentPath = Join-Path $TelemetryRoot 'consent.json'
    $installIdPath = Join-Path $TelemetryRoot 'device-id.txt'
    $secretPath = Join-Path $TelemetryRoot 'install-secret.txt'
    $localDataPath = Join-Path $TelemetryRoot 'User count.json'
    $pendingPath = Join-Path $TelemetryRoot 'pending-upload.json'
    $forgetPath = Join-Path $TelemetryRoot 'forget-request.json'

    # Withdrawal is persisted before mutex acquisition so it still takes effect
    # even when a collection worker is already running.
    if ($DisableTelemetry) {
        $oldInstallId = $null
        if (Test-Path -LiteralPath $installIdPath -PathType Leaf) { try { $oldInstallId = (Get-Content -LiteralPath $installIdPath -Raw).Trim() } catch {} }
        $offConsent = [ordered]@{ schemaVersion = 2; deviceDiagnostics = $false; withdrawnAtUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json
        [System.IO.File]::WriteAllText($consentPath, $offConsent, (New-Object System.Text.UTF8Encoding($false)))
        if ($oldInstallId) {
            $forgetRecord = [ordered]@{ installId = $oldInstallId; requestedAtUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json
            [System.IO.File]::WriteAllText($forgetPath, $forgetRecord, (New-Object System.Text.UTF8Encoding($false)))
        }
        Remove-Item -LiteralPath $localDataPath, $pendingPath -Force -ErrorAction SilentlyContinue
    }

    # One worker per interactive user session. This prevents overlapping CIM scans/uploads.
    $mutex = New-Object System.Threading.Mutex($false, 'Local\AMRToolPro.Telemetry.Worker')
    try { $hasMutex = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $hasMutex = $true }
    if (-not $hasMutex) { exit 0 }

    if (-not (Test-Path -LiteralPath $consentPath -PathType Leaf)) { exit 0 }
    $consent = Get-Content -LiteralPath $consentPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($consent.deviceDiagnostics -ne $true) {
        if (Test-Path -LiteralPath $forgetPath -PathType Leaf) {
            $forget = Get-Content -LiteralPath $forgetPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $forgetId = [string]$forget.installId
            if ($forgetId -match '^[0-9a-fA-F-]{36}$' -and (Test-Path -LiteralPath $secretPath)) {
                $secret = (Get-Content -LiteralPath $secretPath -Raw).Trim()
                $endpointText = (Invoke-WebRequest -Uri $EndpointFileUrl -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop).Content.Trim()
                if ($endpointText -match '^https://[^\s]+/collect/?$') { Invoke-AMRForgetRequest -Endpoint $endpointText -InstallId $forgetId -InstallSecret $secret -ForgetPath $forgetPath }
            }
        }
        exit 0
    }

    $installId = $null
    if (Test-Path -LiteralPath $installIdPath -PathType Leaf) { try { $installId = (Get-Content -LiteralPath $installIdPath -Raw).Trim() } catch {} }
    $parsed = [Guid]::Empty
    if (-not [Guid]::TryParse([string]$installId, [ref]$parsed)) {
        $installId = [Guid]::NewGuid().ToString()
        [System.IO.File]::WriteAllText($installIdPath, $installId, (New-Object System.Text.UTF8Encoding($false)))
    }
    $installSecret = Get-AMRInstallSecret -SecretPath $secretPath

    $now = [DateTime]::UtcNow.ToString('o')
    $firstSeen = $now; $launchCount = 0
    if (Test-Path -LiteralPath $localDataPath -PathType Leaf) {
        try {
            $old = Get-Content -LiteralPath $localDataPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($old.installId -eq $installId) {
                if ($old.firstSeenUtc) { $firstSeen = [string]$old.firstSeenUtc }
                $launchCount = [Math]::Max(0, [int]$old.launchCount)
            }
        } catch { Write-AMRTelemetryLog ('Could not read previous local profile: ' + $_.Exception.Message) }
    }
    $launchCount++

    $device = Get-AMRDeviceProfile -InstallId $installId
    $record = [ordered]@{
        schemaVersion = 2
        installId = $installId
        installSecret = $installSecret
        firstSeenUtc = $firstSeen
        lastSeenUtc = $now
        launchCount = $launchCount
        launcherVersion = $LauncherVersion
        application = 'AMR Tool-Pro'
        device = $device
        consent = [ordered]@{ deviceDiagnostics = $true; consentedAtUtc = [string]$consent.consentedAtUtc }
    }
    $json = $record | ConvertTo-Json -Depth 12
    $localRecord = [ordered]@{}
    foreach ($entry in $record.GetEnumerator()) {
        if ($entry.Key -ne 'installSecret') { $localRecord[$entry.Key] = $entry.Value }
    }
    $localJson = $localRecord | ConvertTo-Json -Depth 12
    $tempPath = $localDataPath + '.tmp'
    [System.IO.File]::WriteAllText($tempPath, $localJson, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tempPath -Destination $localDataPath -Force
    [System.IO.File]::WriteAllText($pendingPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-AMRTelemetryLog ("Saved sanitized device profile. LaunchCount={0}." -f $launchCount)

    try {
        $latestConsent = Get-Content -LiteralPath $consentPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($latestConsent.deviceDiagnostics -ne $true) {
            Remove-Item -LiteralPath $localDataPath, $pendingPath -Force -ErrorAction SilentlyContinue
            Write-AMRTelemetryLog 'Consent was withdrawn during collection; no report was uploaded.'
            exit 0
        }
        $endpoint = (Invoke-WebRequest -Uri $EndpointFileUrl -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop).Content.Trim()
        $parsedEndpoint = $null
        if (-not [Uri]::TryCreate($endpoint, [UriKind]::Absolute, [ref]$parsedEndpoint) -or $parsedEndpoint.Scheme -ne 'https' -or $parsedEndpoint.AbsolutePath.TrimEnd('/') -ne '/collect') {
            throw 'Telemetry endpoint is not a valid HTTPS /collect endpoint.'
        }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $response = Invoke-RestMethod -Method Post -Uri $endpoint -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 12 -ErrorAction Stop
        if ($response -and $response.ok -eq $true) {
            Remove-Item -LiteralPath $pendingPath -Force -ErrorAction SilentlyContinue
            Write-AMRTelemetryLog 'Sanitized device profile synchronized successfully.'
        } else {
            Write-AMRTelemetryLog 'Server response was not successful; report remains queued locally.'
        }
    } catch {
        Write-AMRTelemetryLog ('Upload deferred; report remains queued locally: ' + $_.Exception.Message)
    }
} catch {
    Write-AMRTelemetryLog ('Background worker failed safely: ' + $_.Exception.Message)
} finally {
    if ($mutex) {
        try { if ($hasMutex) { $mutex.ReleaseMutex() } } catch {}
        try { $mutex.Dispose() } catch {}
    }
}
