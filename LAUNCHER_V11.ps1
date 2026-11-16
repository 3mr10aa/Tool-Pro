<#
AMR Windows Utility - IRM In-Memory Launcher V11 (fixed raw-byte SHA-256)
Windows PowerShell 5.1
Downloads the exact V11 main script from the verified repository path,
checks its pinned SHA-256, then streams it to an elevated STA PowerShell process.
The UAC consent dialog remains visible. No launcher or main script is written to disk.
#>
$ErrorActionPreference = 'Stop'
$mainUrl = 'https://raw.githubusercontent.com/3mr10aa/Tool-Pro/Master/AMR_WINDOWS_UTILITY_V11.ps1'
$expectedSha256 = '3E9A81880111D7E133DC627686F420CFD2C21F87E513A80BEBCD974D4401D3A7'
$pipeName = 'AMR_' + [guid]::NewGuid().ToString('N')
$eventName = 'Local\AMR.Startup.Ready.' + [guid]::NewGuid().ToString('N')
$server = $null; $readyEvent = $null; $form = $null; $child = $null
$client = $null
try {
    Add-Type -AssemblyName System.Windows.Forms
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'AMR Windows Utility'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.ClientSize = New-Object System.Drawing.Size(520,210)
    $form.BackColor = [System.Drawing.Color]::FromArgb(15,27,43)
    $form.ForeColor = [System.Drawing.Color]::White
    $form.ShowInTaskbar = $false; $form.TopMost = $true
    $brand = New-Object System.Windows.Forms.Label
    $brand.Dock = [System.Windows.Forms.DockStyle]::Top; $brand.Height = 54
    $brand.Text = 'AMR WINDOWS UTILITY'; $brand.TextAlign = 'MiddleCenter'
    $brand.ForeColor = [System.Drawing.Color]::FromArgb(96,165,250)
    $brand.Font = New-Object System.Drawing.Font('Segoe UI',17,[System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($brand)
    $welcome = New-Object System.Windows.Forms.Label
    $welcome.Dock = [System.Windows.Forms.DockStyle]::Fill
    $welcome.Text = "Thank you for choosing AMR.`r`nPreparing your workspace..."
    $welcome.TextAlign = 'MiddleCenter'; $welcome.ForeColor = [System.Drawing.Color]::FromArgb(241,245,249)
    $welcome.Font = New-Object System.Drawing.Font('Segoe UI',12,[System.Drawing.FontStyle]::Regular)
    $form.Controls.Add($welcome)
    $form.Show(); $form.Refresh(); [System.Windows.Forms.Application]::DoEvents()

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $client = New-Object Net.WebClient
    $client.Headers['User-Agent'] = 'AMR-Windows-Utility-IRM-Launcher/11-fixed'
    # Download raw bytes. DownloadString can use the machine's ANSI code page
    # when the server omits a charset, corrupting non-ASCII text and its hash.
    $mainBytes = $client.DownloadData($mainUrl)
    $client.Dispose(); $client = $null
    if (-not $mainBytes -or $mainBytes.Length -eq 0) { throw 'The main application source was empty.' }
    $shaProvider = [Security.Cryptography.SHA256]::Create()
    try {
        $actualHash = [BitConverter]::ToString($shaProvider.ComputeHash($mainBytes)).Replace('-','')
    } finally { $shaProvider.Dispose() }
    if ($actualHash -ne $expectedSha256) {
        throw "Main application integrity check failed. Expected $expectedSha256 but received $actualHash. No application code was started."
    }

    $utf8Strict = [System.Text.UTF8Encoding]::new($false, $true)
    try { $mainText = $utf8Strict.GetString($mainBytes) } catch { throw 'The downloaded application is not valid UTF-8.' }
    $server = New-Object IO.Pipes.NamedPipeServerStream($pipeName,[IO.Pipes.PipeDirection]::Out,1,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::None)
    # Allow the elevated child process to signal the event even when this launcher
    # was started without elevation (mandatory integrity levels can otherwise
    # prevent the child from opening the event with Modify access).
    $eventSecurity = New-Object System.Security.AccessControl.EventWaitHandleSecurity
    $currentUserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $eventRule = [System.Security.AccessControl.EventWaitHandleAccessRule]::new(
        $currentUserSid,
        ([System.Security.AccessControl.EventWaitHandleRights]::Modify -bor [System.Security.AccessControl.EventWaitHandleRights]::Synchronize),
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    [void]$eventSecurity.AddAccessRule($eventRule)
    $createdNew = $false
    $readyEvent = [System.Threading.EventWaitHandle]::new(
        $false,
        [System.Threading.EventResetMode]::ManualReset,
        $eventName,
        [ref]$createdNew,
        $eventSecurity
    )
    $env:AMR_STARTUP_EVENT_NAME = $eventName
    $env:AMR_LAUNCHER_START_TICKS = [DateTime]::UtcNow.Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)
    $bootstrap = @"
`$ErrorActionPreference = 'Stop'
`$pipe = New-Object IO.Pipes.NamedPipeClientStream('.', '$pipeName', [IO.Pipes.PipeDirection]::In)
`$pipe.Connect(45000)
`$memory = New-Object IO.MemoryStream
`$pipe.CopyTo(`$memory)
`$pipe.Dispose()
`$source = [Text.Encoding]::UTF8.GetString(`$memory.ToArray())
`$memory.Dispose()
`$env:AMR_INMEMORY_BOOTSTRAP = '1'
. ([ScriptBlock]::Create(`$source))
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
    $powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) { throw 'Windows PowerShell 5.1 was not found.' }
    $start = @{ FilePath=$powershellExe; ArgumentList=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-STA','-EncodedCommand',$encoded); WindowStyle='Hidden'; PassThru=$true; ErrorAction='Stop' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { $start.Verb = 'RunAs' }
    $child = Start-Process @start
    $server.WaitForConnection()
    $server.Write($mainBytes,0,$mainBytes.Length); $server.Flush(); $server.Dispose(); $server = $null
    $ready = $false
    while ($true) {
        [System.Windows.Forms.Application]::DoEvents()
        if ($readyEvent.WaitOne(100)) { $ready = $true; break }
        if ($child.HasExited) { break }
        if ($form.IsDisposed -or -not $form.Visible) { break }
    }
    if (-not $ready -and $child.HasExited) {
        [System.Windows.Forms.MessageBox]::Show('AMR closed before its main window appeared. Check C:\ProgramData\AMR-Utility\Logs.','AMR Startup','OK','Warning') | Out-Null
    }
    if ($form -and -not $form.IsDisposed) { $form.Close() }
} catch {
    try {
        if ($form -and -not $form.IsDisposed) { $form.Close() }
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [System.Windows.Forms.MessageBox]::Show([string]$_.Exception.Message,'AMR IRM Launcher Error','OK','Error') | Out-Null
    } catch { Write-Error $_ }
} finally {
    if ($client) { try { $client.Dispose() } catch {} }
    if ($server) { try { $server.Dispose() } catch {} }
    if ($readyEvent) { try { $readyEvent.Dispose() } catch {} }
    if ($eventSecurity) { try { $eventSecurity = $null } catch {} }
    if ($form) { try { $form.Dispose() } catch {} }
    Remove-Item Env:AMR_STARTUP_EVENT_NAME -ErrorAction SilentlyContinue
    Remove-Item Env:AMR_LAUNCHER_START_TICKS -ErrorAction SilentlyContinue
}
