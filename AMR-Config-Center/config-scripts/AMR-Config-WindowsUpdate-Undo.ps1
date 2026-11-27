# ============================================================================
# AMR Utility | Config Center | WindowsUpdate-Undo.ps1
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
    $snap = Get-AMRSnapshotDir -Action $action
    $st = Read-AMRState -Dir $snap
    Write-Host "Restoring from $snap (saved $($st.Time))"
    Set-AMRProgress 3 'Reading saved copy'
    $k = 0; $all = @($st.Registry)
    foreach ($r in $all) {
        $k++
        Set-AMRProgress (3 + [int](40 * $k / [math]::Max(1, $all.Count))) ("Restoring registry key: " + $r.Key)
        Invoke-AMRNative -File 'reg.exe' -Arguments @('import', (Join-Path $snap $r.File)) | Out-Null
    }
    foreach ($d in @($st.Folders)) {
        Set-AMRProgress 50 "Restoring $d"
        $dst = Join-Path $env:WinDir ('System32\' + $d)
        & robocopy.exe (Join-Path $snap $d) $dst /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP *> $null
        if ($LASTEXITCODE -ge 8) { Write-Warning "Folder restore for $d returned $LASTEXITCODE" }
    }
    Set-AMRProgress 60 'Restoring service startup types'
    foreach ($s in @($st.Services)) {
        $mode = switch ([int]$s.Start) { 2 { if ($s.Delayed -eq 1) { 'delayed-auto' } else { 'auto' } } 3 { 'demand' } 4 { 'disabled' } default { $null } }
        if ($mode) { Invoke-AMRNative -File 'sc.exe' -Arguments @('config', $s.Name, 'start=', $mode) -AllowFail | Out-Null }
    }
    Set-AMRProgress 70 'Restoring network settings'
    $nd = Join-Path $snap 'netsh_dump.txt'
    if (Test-Path -LiteralPath $nd) { Invoke-AMRNative -File 'netsh.exe' -Arguments @('-f', $nd) -AllowFail | Out-Null }
    $px = Join-Path $snap 'winhttp_proxy.txt'
    if (Test-Path -LiteralPath $px) {
        $t = Get-Content -LiteralPath $px -Raw
        if ($t -match 'Proxy Server\(s\)\s*:\s*(.+)') {
            $srv = $Matches[1].Trim(); $byp = ''
            if ($t -match 'Bypass List\s*:\s*(.+)') { $byp = $Matches[1].Trim() }
            if ($byp -and $byp -ne '(none)') { Invoke-AMRNative -File 'netsh.exe' -Arguments @('winhttp', 'set', 'proxy', "proxy-server=$srv", "bypass-list=$byp") -AllowFail | Out-Null }
            else { Invoke-AMRNative -File 'netsh.exe' -Arguments @('winhttp', 'set', 'proxy', "proxy-server=$srv") -AllowFail | Out-Null }
        }
    }
    Set-AMRProgress 82 'Restoring local security policy'
    $inf = Join-Path $snap 'secpol_before.inf'
    if (Test-Path -LiteralPath $inf) { Invoke-AMRNative -File 'secedit.exe' -Arguments @('/configure', '/db', (Join-Path $snap 'undo.sdb'), '/cfg', $inf, '/areas', 'SECURITYPOLICY', 'USER_RIGHTS', '/quiet') -AllowFail | Out-Null }
    Start-Process -NoNewWindow -Wait -FilePath 'gpupdate' -ArgumentList '/force'
    Complete-AMRAction -Ok $true -Message 'Saved settings restored. Restart Windows. Not restorable: deleted BITS jobs, the old update download cache (Windows rebuilds it), DLL re-registration (harmless).' -RebootRecommended
} catch {
    Write-Error $_
    Complete-AMRAction -Ok $false -Message ('Undo failed: ' + $_.Exception.Message)
    exit 1
}
