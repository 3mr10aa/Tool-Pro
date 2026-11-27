# ============================================================================
# AMR Utility | Config Center | OpenSSH-Enable.ps1
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
    $snap = Get-AMRSnapshotDir -Action $action -New
    Set-AMRProgress 3 'Recording current OpenSSH state'
    $cap = Get-WindowsCapability -Online | Where-Object { $_.Name -like 'OpenSSH.Server*' } | Select-Object -First 1
    if (-not $cap) { throw 'The OpenSSH Server capability was not found on this Windows build.' }
    $capState = $cap.State.ToString()
    $sshDir = Join-Path $env:ProgramData 'ssh'
    $cfgPath = Join-Path $sshDir 'sshd_config'
    $akPath = Join-Path $sshDir 'administrators_authorized_keys'
    $svcBefore = @()
    foreach ($s in @('sshd', 'ssh-agent')) {
        $sv = Get-Service -Name $s -ErrorAction SilentlyContinue
        if ($sv) { $svcBefore += [pscustomobject]@{ Name = $s; StartType = $sv.StartType.ToString(); Status = $sv.Status.ToString() } }
    }
    $fw = Get-NetFirewallRule -Name 'sshd' -ErrorAction SilentlyContinue
    $fwBefore = $null; if ($fw) { $fwBefore = [pscustomobject]@{ Enabled = [int]$fw.Enabled } }
    $cfgHad = Test-Path -LiteralPath $cfgPath; $akHad = Test-Path -LiteralPath $akPath
    if ($cfgHad) { Copy-Item -LiteralPath $cfgPath -Destination (Join-Path $snap 'sshd_config.bak') -Force }
    $akSddl = $null
    if ($akHad) { Copy-Item -LiteralPath $akPath -Destination (Join-Path $snap 'administrators_authorized_keys.bak') -Force; $akSddl = (Get-Acl -LiteralPath $akPath).Sddl }
    Save-AMRState -Dir $snap -Object ([pscustomobject]@{ Action = $action; Time = (Get-Date).ToString('o'); CapabilityName = $cap.Name; CapabilityState = $capState; Services = $svcBefore; Firewall = $fwBefore; SshdConfigExisted = $cfgHad; AuthorizedKeysExisted = $akHad; AuthorizedKeysSddl = $akSddl })
    # Upstream sequence (winutil SSH server). Logic unchanged, except the full capability name is resolved first.
    if ($capState -ne 'Installed') {
        Set-AMRProgress 15 'Installing OpenSSH Server (Windows downloads it; this can take a few minutes)' -Indeterminate
        Add-WindowsCapability -Name $cap.Name -Online | Out-Null
    }
    Set-AMRProgress 50 'Starting sshd and ssh-agent'
    Set-Service -Name sshd -StartupType Automatic; Start-Service -Name sshd
    Set-Service -Name ssh-agent -StartupType Automatic; Start-Service -Name ssh-agent
    Set-AMRProgress 60 'Opening inbound TCP 22 (firewall rule sshd)'
    $rule = Get-NetFirewallRule -Name 'sshd' -ErrorAction SilentlyContinue
    if ($null -eq $rule) { New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null }
    elseif ([int]$rule.Enabled -eq 2) { Set-NetFirewallRule -Name 'sshd' -Enabled True }
    Set-AMRProgress 72 'Applying administrator authorized-keys configuration'
    $profileKeysPath = Join-Path $env:USERPROFILE '.ssh\authorized_keys'
    if (-not (Test-Path -Path $sshDir)) { New-Item -Path $sshDir -ItemType Directory -Force | Out-Null }
    $configContent = if (Test-Path -Path $cfgPath) { [string](Get-Content -Path $cfgPath -Raw) } else { '' }
    $restored = $configContent -replace '(?m)^# (Match Group administrators)$', '$1'
    $restored = $restored -replace '(?m)^# (\s+AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys)$', '$1'
    $overridden = $restored -ne $configContent
    if (-not (Test-Path -Path $akPath)) { New-Item -Path $akPath -ItemType File -Force | Out-Null }
    if ($overridden -and (Test-Path -Path $profileKeysPath)) {
        $current = @(Get-Content -Path $akPath)
        $move = @(Get-Content -Path $profileKeysPath | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') -and $current -notcontains $_ })
        if ($move.Count -gt 0) { Add-Content -Path $akPath -Value $move }
    }
    $acl = Get-Acl -Path $akPath
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($r in @($acl.Access)) { [void]$acl.RemoveAccessRule($r) }
    foreach ($sid in @('S-1-5-32-544', 'S-1-5-18')) { [void]$acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new([System.Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'Allow')) }
    Set-Acl -Path $akPath -AclObject $acl
    if ($overridden) { Set-Content -Path $cfgPath -Value $restored -Force; Restart-Service -Name sshd -Force }
    Complete-AMRAction -Ok $true -Message 'OpenSSH Server enabled. Use Disable OpenSSH Server to undo.'
} catch {
    Write-Error $_
    Complete-AMRAction -Ok $false -Message ('OpenSSH enable failed: ' + $_.Exception.Message)
    exit 1
}
