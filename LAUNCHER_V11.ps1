<#
AMR Windows Utility - IRM In-Memory Launcher V11 (Premium Welcome + SHA-256 Integrity)
Windows PowerShell 5.1
Downloads the pinned V11 main script, verifies its SHA-256, then streams it
into an elevated STA PowerShell process. The application is not written to disk.
#>
$ErrorActionPreference = 'Stop'
$mainUrl = 'https://raw.githubusercontent.com/3mr10aa/Tool-Pro/Master/AMR_WINDOWS_UTILITY_V11.ps1'

# SHA-256 of the exact modified application file delivered with this launcher.
$expectedSha256 = '2A86FB8FE6FEDC4822A4BBD57761BC85463EC8A98E64E8D5FE76D21C8D530197'

# --- Premium launcher-owned welcome screen ---
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:WelcomeForm = $null
$script:ReadyEvent = $null
$script:ChildProcess = $null
$pipeName = 'AMR_' + [guid]::NewGuid().ToString('N')
$eventName = 'Local\AMR_V11_READY_' + [guid]::NewGuid().ToString('N')
$launcherStartTicks = [DateTime]::UtcNow.Ticks
$server = $null
$client = $null

try {
    $script:ReadyEvent = [System.Threading.EventWaitHandle]::new(
        $false,
        [System.Threading.EventResetMode]::ManualReset,
        $eventName
    )

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'AMR Windows Utility'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.ClientSize = [System.Drawing.Size]::new(620,330)
    $form.BackColor = [System.Drawing.Color]::FromArgb(11,18,32)
    $form.ForeColor = [System.Drawing.Color]::FromArgb(241,245,249)
    $form.ShowInTaskbar = $false
    $form.TopMost = $true

    $accent = New-Object System.Windows.Forms.Panel
    $accent.Dock = [System.Windows.Forms.DockStyle]::Top
    $accent.Height = 5
    $accent.BackColor = [System.Drawing.Color]::FromArgb(59,130,246)
    $form.Controls.Add($accent)

    $brand = New-Object System.Windows.Forms.Label
    $brand.Dock = [System.Windows.Forms.DockStyle]::Top
    $brand.Height = 82
    $brand.Text = 'AMR WINDOWS UTILITY'
    $brand.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $brand.ForeColor = [System.Drawing.Color]::FromArgb(125,183,255)
    $brand.Font = [System.Drawing.Font]::new('Segoe UI Semibold',21,[System.Drawing.FontStyle]::Bold)
    $brand.Padding = [System.Windows.Forms.Padding]::new(18,10,18,0)
    $form.Controls.Add($brand)

    $welcome = New-Object System.Windows.Forms.Label
    $welcome.Dock = [System.Windows.Forms.DockStyle]::Fill
    $welcome.Padding = [System.Windows.Forms.Padding]::new(34,8,34,8)
    $welcome.Text = "Thank you for your appreciation.`r`n`r`nWe value your time and will work hard to deliver`r`nthe best and fastest user experience."
    $welcome.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $welcome.ForeColor = [System.Drawing.Color]::FromArgb(226,232,240)
    $welcome.Font = [System.Drawing.Font]::new('Segoe UI',13,[System.Drawing.FontStyle]::Regular)
    $form.Controls.Add($welcome)

    $footer = New-Object System.Windows.Forms.Panel
    $footer.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $footer.Height = 64
    $footer.Padding = [System.Windows.Forms.Padding]::new(46,4,46,12)
    $footer.BackColor = [System.Drawing.Color]::FromArgb(11,18,32)
    $form.Controls.Add($footer)

    $loading = New-Object System.Windows.Forms.Label
    $loading.Dock = [System.Windows.Forms.DockStyle]::Top
    $loading.Height = 24
    $loading.Text = 'Preparing your experience...'
    $loading.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $loading.ForeColor = [System.Drawing.Color]::FromArgb(148,163,184)
    $loading.Font = [System.Drawing.Font]::new('Segoe UI',9,[System.Drawing.FontStyle]::Regular)
    $footer.Controls.Add($loading)

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $progress.Height = 7
    $progress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $progress.MarqueeAnimationSpeed = 26
    $footer.Controls.Add($progress)

    $script:WelcomeForm = $form
    $form.Show()
    $form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()

    # --- Download and verify the exact application bytes before execution ---
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $client = New-Object Net.WebClient
    $client.Headers['User-Agent'] = 'AMR-Windows-Utility-IRM-Launcher/11'
    $mainBytes = $client.DownloadData($mainUrl)
    $client.Dispose(); $client = $null
    if (-not $mainBytes -or $mainBytes.Length -eq 0) {
        throw 'The main application source was empty.'
    }

    $shaProvider = [Security.Cryptography.SHA256]::Create()
    try {
        $actualHash = [BitConverter]::ToString(
            $shaProvider.ComputeHash($mainBytes)
        ).Replace('-','')
    } finally { $shaProvider.Dispose() }

    if ($actualHash -ne $expectedSha256) {
        throw "Main application integrity check failed. Expected $expectedSha256 but received $actualHash. No application code was started."
    }

    $utf8Strict = New-Object System.Text.UTF8Encoding($false,$true)
    try { $null = $utf8Strict.GetString($mainBytes) }
    catch { throw 'The downloaded application is not valid UTF-8.' }

    # The launcher owns this event; the application signals it from its existing
    # ContentRendered -> Signal-AMRExternalStartupReady path.
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
`$env:AMR_STARTUP_EVENT_NAME = '$eventName'
`$env:AMR_LAUNCHER_START_TICKS = '$launcherStartTicks'
. ([ScriptBlock]::Create(`$source))
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
    $powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) {
        throw 'Windows PowerShell 5.1 was not found.'
    }

    $server = New-Object IO.Pipes.NamedPipeServerStream(
        $pipeName,[IO.Pipes.PipeDirection]::Out,1,
        [IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::None
    )
    $start = @{
        FilePath=$powershellExe
        ArgumentList=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-STA','-EncodedCommand',$encoded)
        WindowStyle='Hidden'; PassThru=$true; ErrorAction='Stop'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $start.Verb = 'RunAs'
    }
    $script:ChildProcess = Start-Process @start
    $server.WaitForConnection()
    $server.Write($mainBytes,0,$mainBytes.Length)
    $server.Flush()
    $server.Dispose(); $server = $null

    # Keep the welcome screen responsive while waiting for the app's existing
    # Ready signal. Do not infer readiness from process start or download finish.
    $ready = $false
    $waitClock = [Diagnostics.Stopwatch]::StartNew()
    while ($waitClock.Elapsed.TotalSeconds -lt 180) {
        [System.Windows.Forms.Application]::DoEvents()
        if ($script:ReadyEvent.WaitOne(100)) { $ready = $true; break }
        if ($script:ChildProcess) {
            $script:ChildProcess.Refresh()
            if ($script:ChildProcess.HasExited) {
                throw "The AMR application process exited before signaling Ready (exit code $($script:ChildProcess.ExitCode))."
            }
        }
    }
    if (-not $ready) {
        throw 'Timed out waiting for the AMR application Ready signal (180 seconds).'
    }

    $form.Close()
    $script:WelcomeForm = $null
} catch {
    $message = [string]$_.Exception.Message
    if ($script:WelcomeForm) {
        try { $script:WelcomeForm.Close() } catch {}
        $script:WelcomeForm = $null
    }
    try {
        [System.Windows.Forms.MessageBox]::Show(
            $message,
            'AMR Windows Utility - Launcher Error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } catch {
        Write-Error ("AMR IRM Launcher Error: {0}" -f $message)
    }
} finally {
    if ($client) { try { $client.Dispose() } catch {} }
    if ($server) { try { $server.Dispose() } catch {} }
    if ($script:ReadyEvent) { try { $script:ReadyEvent.Dispose() } catch {} }
    if ($script:WelcomeForm) { try { $script:WelcomeForm.Dispose() } catch {} }
}
