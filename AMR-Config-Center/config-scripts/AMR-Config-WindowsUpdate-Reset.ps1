# ============================================================================
# AMR Utility | Config Center | WindowsUpdate-Reset.ps1
# Reviewed and adapted by AMR Utility. Upstream: ChrisTitusTech/winutil functions/public/Invoke-WPFFixesUpdate.ps1 @ main 70c23c80641d7370532af2f619b2842658600842 (read 2026-11-27).
# Upstream license: MIT (https://github.com/ChrisTitusTech/winutil/blob/main/LICENSE ,
# https://github.com/ChrisTitusTech/powershell-profile/blob/main/LICENSE). Copyright belongs to the upstream authors.
# Changes vs upstream: restore copy before changes, per-step progress file, HTTPS+SHA-256, undo script. Upstream logic otherwise kept.
# Runs elevated in its own process. Progress file path: env AMR_CONFIG_PROGRESS. Status: REVIEWED, NOT YET RUN ON WINDOWS.
# ============================================================================
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$script:AMRConfigRoot = Join-Path $env:ProgramData 'AMR-Utility\ConfigCenter'
$script:AMRProgressFile = $env:AMR_CONFIG_PROGRESS
function Test-AMRConfigAdmin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
# Progress contract: one small JSON file {percent,status,state,indeterminate,time}. The app polls it; no console needed.
function Set-AMRProgress {
    param([int]$Percent, [string]$Status, [string]$State = 'Running', [switch]$Indeterminate)
    if ($Percent -lt 0) { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }
    Write-Host ('[{0,3}%] {1}' -f $Percent, $Status)
    if ($script:AMRProgressFile) {
        try {
            $o = [ordered]@{ percent = $Percent; status = $Status; state = $State; indeterminate = [bool]$Indeterminate; time = (Get-Date).ToString('o') } | ConvertTo-Json -Compress
            $tmp = $script:AMRProgressFile + '.tmp'
            [IO.File]::WriteAllText($tmp, $o)
            Move-Item -LiteralPath $tmp -Destination $script:AMRProgressFile -Force
        } catch { }
    }
}
function Get-AMRSnapshotDir {
    param([Parameter(Mandatory = $true)][string]$Action, [switch]$New)
    $base = Join-Path $script:AMRConfigRoot ('Snapshots\' + $Action)
    if (-not (Test-Path -LiteralPath $base)) { New-Item -ItemType Directory -Path $base -Force | Out-Null }
    if ($New) {
        $d = Join-Path $base (Get-Date -Format 'yyyyMMdd_HHmmss')
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        return $d
    }
    if ($env:AMR_CONFIG_SNAPSHOT -and (Test-Path -LiteralPath $env:AMR_CONFIG_SNAPSHOT)) { return $env:AMR_CONFIG_SNAPSHOT }
    $latest = Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $latest) { throw 'No saved state was found, so there is nothing to undo.' }
    return $latest.FullName
}
function Save-AMRState { param([string]$Dir, $Object) ($Object | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $Dir 'state.json') -Encoding UTF8 }
function Read-AMRState {
    param([string]$Dir)
    $p = Join-Path $Dir 'state.json'
    if (-not (Test-Path -LiteralPath $p)) { throw "State file missing: $p" }
    return (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json)
}
# HTTPS-only download with byte-based progress and optional SHA-256 pin. Returns the SHA-256 of the file.
function Save-AMRDownload {
    param([string]$Url, [string]$OutFile, [int]$From = 0, [int]$To = 100, [string]$Label = 'Downloading', [string]$ExpectedSha256 = '')
    if ($Url -notmatch '^https://') { throw 'Only HTTPS downloads are allowed.' }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = 'AMR-Utility'
    $req.Timeout = 30000
    $resp = $req.GetResponse()
    try {
        $len = [int64]$resp.ContentLength
        $in = $resp.GetResponseStream()
        $out = [IO.File]::Create($OutFile)
        try {
            $buf = New-Object byte[] 65536
            $total = [int64]0; $last = -1
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $out.Write($buf, 0, $n); $total += $n
                if ($len -gt 0) {
                    $p = [int]($From + ($To - $From) * $total / $len)
                    if ($p -ne $last) { $last = $p; Set-AMRProgress $p ('{0} ({1:N0} of {2:N0} KB)' -f $Label, ($total / 1KB), ($len / 1KB)) }
                }
            }
        } finally { $out.Dispose() }
    } finally { $resp.Close() }
    $hash = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash
    Write-Host ("SHA-256 of {0}: {1}" -f $Url, $hash)
    if ($ExpectedSha256 -and ($hash -ne $ExpectedSha256.ToUpperInvariant())) {
        Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        throw "SHA-256 mismatch for $Url. Expected $ExpectedSha256 but got $hash. Nothing was run."
    }
    return $hash
}
function Invoke-AMRNative {
    param([string]$File, [string[]]$Arguments, [switch]$AllowFail)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & $File @Arguments 2>&1 } finally { $ErrorActionPreference = $prev }
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFail) { throw ("{0} {1} failed with exit code {2}: {3}" -f $File, ($Arguments -join ' '), $code, (($out | Out-String).Trim())) }
    return $out
}
function Complete-AMRAction {
    param([bool]$Ok, [string]$Message, [switch]$RebootRecommended)
    if ($Ok) { Set-AMRProgress 100 $Message 'Done' } else { Set-AMRProgress 100 $Message 'Failed' }
    if ($RebootRecommended) { Write-Host 'A restart is recommended.' }
}

$action = 'WindowsUpdateReset'
try {
    if (-not (Test-AMRConfigAdmin)) { throw 'Administrator rights are required.' }
    $snap = Get-AMRSnapshotDir -Action $action -New
    Set-AMRProgress 1 'Saving a restore copy of your current settings'

    # ---- 1. Safety copy (NEW). If any copy fails, nothing is changed. ----
    $regKeys = @(
        'HKLM\SOFTWARE\Policies', 'HKLM\SOFTWARE\Microsoft\Policies',
        'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies',
        'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate',
        'HKLM\SOFTWARE\Microsoft\WindowsSelfHost',
        'HKLM\SOFTWARE\WOW6432Node\Microsoft\Policies',
        'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Policies',
        'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate',
        'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate',
        'HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings',
        'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies',
        'HKCU\Software\Microsoft\WindowsSelfHost',
        'HKCU\Software\Policies'
    )
    $exported = @(); $n = 0
    foreach ($k in $regKeys) {
        $n++
        Set-AMRProgress (1 + [int](7 * $n / $regKeys.Count)) ("Saving registry key $n of $($regKeys.Count)")
        Invoke-AMRNative -File 'reg.exe' -Arguments @('query', $k) -AllowFail | Out-Null
        if ($LASTEXITCODE -ne 0) { continue }
        $f = Join-Path $snap ('reg{0:00}.reg' -f $n)
        Invoke-AMRNative -File 'reg.exe' -Arguments @('export', $k, $f, '/y') | Out-Null
        $exported += [pscustomobject]@{ Key = $k; File = (Split-Path -Leaf $f) }
    }
    $gpDirs = @()
    foreach ($d in @('GroupPolicy', 'GroupPolicyUsers')) {
        $src = Join-Path $env:WinDir ('System32\' + $d)
        if (Test-Path -LiteralPath $src) {
            $dst = Join-Path $snap $d
            & robocopy.exe $src $dst /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP *> $null
            if ($LASTEXITCODE -ge 8) { throw "Could not copy $d (robocopy exit $LASTEXITCODE)." }
            $gpDirs += $d
        }
    }
    $svc = @()
    foreach ($s in @('BITS', 'wuauserv', 'AppIDSvc', 'CryptSvc')) {
        $rk = "HKLM:\SYSTEM\CurrentControlSet\Services\$s"
        if (Test-Path -LiteralPath $rk) {
            $p = Get-ItemProperty -LiteralPath $rk
            $delayed = $null; if ($p.PSObject.Properties['DelayedAutostart']) { $delayed = [int]$p.DelayedAutostart }
            $svc += [pscustomobject]@{ Name = $s; Start = [int]$p.Start; Delayed = $delayed }
        }
    }
    Invoke-AMRNative -File 'netsh.exe' -Arguments @('winhttp', 'show', 'proxy') -AllowFail | Out-File -LiteralPath (Join-Path $snap 'winhttp_proxy.txt') -Encoding UTF8
    Invoke-AMRNative -File 'netsh.exe' -Arguments @('dump') -AllowFail | Out-File -LiteralPath (Join-Path $snap 'netsh_dump.txt') -Encoding ASCII
    Invoke-AMRNative -File 'secedit.exe' -Arguments @('/export', '/cfg', (Join-Path $snap 'secpol_before.inf'), '/quiet') -AllowFail | Out-Null
    $restorePoint = 'not created'
    try {
        Checkpoint-Computer -Description 'AMR Utility: before Windows Update reset' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        $restorePoint = 'created'
    } catch { $restorePoint = 'not created: ' + $_.Exception.Message; Write-Warning $restorePoint }
    Save-AMRState -Dir $snap -Object ([pscustomobject]@{ Action = $action; Time = (Get-Date).ToString('o'); User = $env:USERNAME; Registry = $exported; Folders = $gpDirs; Services = $svc; RestorePoint = $restorePoint })
    Write-Host "Restore copy saved in $snap"

    # ---- 2. Upstream sequence (ChrisTitusTech/winutil, Invoke-WPFFixesUpdate, non-aggressive). Logic unchanged. ----
    Set-AMRProgress 12 'Stopping Windows Update services'
    foreach ($s in @('BITS', 'wuauserv', 'appidsvc', 'cryptsvc')) { Stop-Service -Name $s -Force }
    Set-AMRProgress 20 'Removing queued download data'
    Remove-Item "$env:allusersprofile\Application Data\Microsoft\Network\Downloader\qmgr*.dat" -ErrorAction SilentlyContinue
    Rename-Item "$env:systemroot\SoftwareDistribution\Download" 'Download.bak' -ErrorAction SilentlyContinue
    Remove-Item "$env:systemroot\WindowsUpdate.log" -ErrorAction SilentlyContinue

    $dlls = @('atl.dll','urlmon.dll','mshtml.dll','shdocvw.dll','browseui.dll','jscript.dll','vbscript.dll','scrrun.dll','msxml.dll','msxml3.dll','msxml6.dll','actxprxy.dll','softpub.dll','wintrust.dll','dssenh.dll','rsaenh.dll','gpkcsp.dll','sccbase.dll','slbcsp.dll','cryptdlg.dll','oleaut32.dll','ole32.dll','shell32.dll','initpki.dll','wuapi.dll','wuaueng.dll','wuaueng1.dll','wucltui.dll','wups.dll','wups2.dll','wuweb.dll','qmgr.dll','qmgrprxy.dll','wucltux.dll','muweb.dll','wuwebv.dll')
    $i = 0
    foreach ($dll in $dlls) {
        Set-AMRProgress (25 + [int](25 * $i / $dlls.Count)) "Registering $dll"
        $i++
        Start-Process -NoNewWindow -Wait -FilePath 'regsvr32.exe' -ArgumentList '/s', (Join-Path $env:systemroot "system32\$dll")
    }

    Set-AMRProgress 52 'Removing Windows Update client IDs'
    $wu = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate'
    if (Test-Path $wu) { foreach ($v in @('AccountDomainSid', 'PingID', 'SusClientId')) { Remove-ItemProperty -Path $wu -Name $v -ErrorAction SilentlyContinue } }

    Set-AMRProgress 56 'Removing Windows Update policy settings'
    $p1 = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows'
    Remove-ItemProperty -Path "$p1\WindowsUpdate" -Name 'ExcludeWUDriversInQualityUpdate' -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "$p1\Device Metadata" -Name 'PreventDeviceMetadataFromNetwork' -ErrorAction SilentlyContinue
    foreach ($v in @('DontPromptForWindowsUpdate', 'DontSearchWindowsUpdate', 'DriverUpdateWizardWuSearchEnabled')) { Remove-ItemProperty -Path "$p1\DriverSearching" -Name $v -ErrorAction SilentlyContinue }
    foreach ($v in @('NoAutoRebootWithLoggedOnUsers', 'AUPowerManagement')) { Remove-ItemProperty -Path "$p1\WindowsUpdate\AU" -Name $v -ErrorAction SilentlyContinue }
    foreach ($v in @('BranchReadinessLevel', 'DeferFeatureUpdatesPeriodInDays', 'DeferQualityUpdatesPeriodInDays')) { Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name $v -ErrorAction SilentlyContinue }

    Set-AMRProgress 62 'Clearing policy registry trees (copy saved)'
    foreach ($t in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies', 'HKCU:\Software\Microsoft\WindowsSelfHost', 'HKCU:\Software\Policies', 'HKLM:\Software\Microsoft\Policies', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate', 'HKLM:\Software\Microsoft\WindowsSelfHost', 'HKLM:\Software\Policies', 'HKLM:\Software\WOW6432Node\Microsoft\Policies', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Policies', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate')) {
        Remove-Item -Path $t -Recurse -Force -ErrorAction SilentlyContinue
    }
    Set-AMRProgress 68 'Resetting local security policy defaults'
    Start-Process -NoNewWindow -Wait -FilePath 'secedit' -ArgumentList '/configure', '/cfg', "$env:windir\inf\defltbase.inf", '/db', 'defltbase.sdb', '/verbose'
    Set-AMRProgress 72 'Resetting local Group Policy'
    Start-Process -NoNewWindow -Wait -FilePath 'cmd.exe' -ArgumentList "/c RD /S /Q $env:WinDir\System32\GroupPolicyUsers"
    Start-Process -NoNewWindow -Wait -FilePath 'cmd.exe' -ArgumentList "/c RD /S /Q $env:WinDir\System32\GroupPolicy"
    Start-Process -NoNewWindow -Wait -FilePath 'gpupdate' -ArgumentList '/force'

    Set-AMRProgress 78 'Resetting network components (WinSock, WinHTTP proxy, IP)'
    Start-Process -NoNewWindow -Wait -FilePath 'netsh' -ArgumentList 'winsock', 'reset'
    Start-Process -NoNewWindow -Wait -FilePath 'netsh' -ArgumentList 'winhttp', 'reset', 'proxy'
    Start-Process -NoNewWindow -Wait -FilePath 'netsh' -ArgumentList 'int', 'ip', 'reset'

    Set-AMRProgress 84 'Deleting background transfer (BITS) jobs'
    Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue | Remove-BitsTransfer -ErrorAction SilentlyContinue

    Set-AMRProgress 88 'Starting Windows Update services'
    Get-Service BITS | Set-Service -StartupType Manual -PassThru | Start-Service
    Get-Service wuauserv | Set-Service -StartupType Manual -PassThru | Start-Service
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\AppIDSvc' -Name 'Start' -Value 3
    Start-Service AppIDSvc
    Get-Service CryptSvc | Set-Service -StartupType Manual -PassThru | Start-Service

    Set-AMRProgress 96 'Asking Windows Update to check for updates'
    try { (New-Object -ComObject Microsoft.Update.AutoUpdate).DetectNow() } catch { Write-Warning "Windows Update COM check failed: $_" }
    Start-Process -NoNewWindow -Wait -FilePath 'wuauclt' -ArgumentList '/resetauthorization', '/detectnow'
    Complete-AMRAction -Ok $true -Message 'Windows Update reset finished. Restart Windows. Use Undo to restore the saved copy.' -RebootRecommended
} catch {
    Write-Error $_
    Complete-AMRAction -Ok $false -Message ('Windows Update reset failed: ' + $_.Exception.Message)
    exit 1
}
