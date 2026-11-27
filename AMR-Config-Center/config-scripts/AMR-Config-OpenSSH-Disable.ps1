# ============================================================================
# AMR Utility | Config Center | OpenSSH-Disable.ps1
# Reviewed and adapted by AMR Utility. Upstream: ChrisTitusTech/winutil SSH server setup (https://winutil.christitus.com/code-reference/features/remote-access/sshserver/).
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

$action = 'OpenSshServer'
try {
    if (-not (Test-AMRConfigAdmin)) { throw 'Administrator rights are required.' }
    $snap = Get-AMRSnapshotDir -Action $action
    $st = Read-AMRState -Dir $snap
    $sshDir = Join-Path $env:ProgramData 'ssh'
    $cfgPath = Join-Path $sshDir 'sshd_config'
    $akPath = Join-Path $sshDir 'administrators_authorized_keys'
    Set-AMRProgress 8 'Stopping sshd and ssh-agent'
    foreach ($s in @('sshd', 'ssh-agent')) { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue }
    Set-AMRProgress 25 'Restoring service startup types'
    foreach ($s in @($st.Services)) {
        $t = [string]$s.StartType
        if ($t -in @('Automatic', 'Manual', 'Disabled')) { Set-Service -Name $s.Name -StartupType $t -ErrorAction SilentlyContinue }
        if ($s.Status -eq 'Running') { Start-Service -Name $s.Name -ErrorAction SilentlyContinue }
    }
    Set-AMRProgress 40 'Restoring firewall rule'
    if ($null -eq $st.Firewall) { Remove-NetFirewallRule -Name 'sshd' -ErrorAction SilentlyContinue }
    else { Set-NetFirewallRule -Name 'sshd' -Enabled $(if ([int]$st.Firewall.Enabled -eq 1) { 'True' } else { 'False' }) -ErrorAction SilentlyContinue }
    Set-AMRProgress 55 'Restoring ssh configuration files'
    $cfgBak = Join-Path $snap 'sshd_config.bak'
    if ($st.SshdConfigExisted -and (Test-Path -LiteralPath $cfgBak)) { Copy-Item -LiteralPath $cfgBak -Destination $cfgPath -Force }
    $akBak = Join-Path $snap 'administrators_authorized_keys.bak'
    $note = ''
    if ($st.AuthorizedKeysExisted -and (Test-Path -LiteralPath $akBak)) {
        Copy-Item -LiteralPath $akBak -Destination $akPath -Force
        if ($st.AuthorizedKeysSddl) { $a = Get-Acl -LiteralPath $akPath; $a.SetSecurityDescriptorSddlForm([string]$st.AuthorizedKeysSddl); Set-Acl -LiteralPath $akPath -AclObject $a }
    } elseif (Test-Path -LiteralPath $akPath) {
        if ((Get-Item -LiteralPath $akPath).Length -eq 0) { Remove-Item -LiteralPath $akPath -Force }
        else { $note = ' The authorized-keys file now has keys in it, so it was kept (never deleted).' }
    }
    if ($st.CapabilityState -ne 'Installed') {
        Set-AMRProgress 70 'Removing OpenSSH Server capability' -Indeterminate
        Remove-WindowsCapability -Name $st.CapabilityName -Online | Out-Null
    }
    Complete-AMRAction -Ok $true -Message ('OpenSSH Server changes undone.' + $note)
} catch {
    Write-Error $_
    Complete-AMRAction -Ok $false -Message ('OpenSSH undo failed: ' + $_.Exception.Message)
    exit 1
}
