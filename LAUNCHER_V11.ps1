<#
AMR Windows Utility - IRM In-Memory Launcher V10
Usage (Windows PowerShell 5.1):
irm 'https://raw.githubusercontent.com/3mr10aa/Tool-Pro/Master/AMR_WINDOWS_UTILITY_LAUNCHER_V11.ps1' | iex

The launcher retrieves the main script into memory, verifies its pinned SHA-256,
then streams it over a local named pipe to a hidden elevated STA PowerShell process.
No launcher/main .ps1 file is written to disk. UAC consent remains visible.
#>
$ErrorActionPreference = 'Stop'
$mainUrl = 'https://raw.githubusercontent.com/3mr10aa/Tool-Pro/Master/AMR_WINDOWS_UTILITY_ENGINEERING_SMART_INSTALL_V11.ps1'
$expectedSha256 = '3E9A81880111D7E133DC627686F420CFD2C21F87E513A80BEBCD974D4401D3A7'
$pipeName = 'AMR_' + [guid]::NewGuid().ToString('N')
$eventName = 'Local\AMR.Startup.Ready.' + [guid]::NewGuid().ToString('N')
$server = $null; $readyEvent = $null; $form = $null; $timer = $null; $child = $null
$failed = $false
try {
    # Paint a lightweight welcome screen before retrieving/parsing the 1.6 MB app.
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
    $welcome.Text = "Thank you for choosing AMR.`r`nWe appreciate your trust and are working to make your experience smoother and faster."
    $welcome.TextAlign = 'MiddleCenter'; $welcome.ForeColor = [System.Drawing.Color]::FromArgb(241,245,249)
    $welcome.Font = New-Object System.Drawing.Font('Segoe UI',12,[System.Drawing.FontStyle]::Regular)
    $form.Controls.Add($welcome)
    $loading = New-Object System.Windows.Forms.Label
    $loading.Dock = [System.Windows.Forms.DockStyle]::Bottom; $loading.Height = 34
    $loading.Text = 'Preparing your workspace...'; $loading.TextAlign = 'MiddleCenter'
    $loading.ForeColor = [System.Drawing.Color]::FromArgb(148,163,184)
    $loading.Font = New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Regular)
    $form.Controls.Add($loading)
    $form.Show(); $form.Refresh(); [System.Windows.Forms.Application]::DoEvents()

    # Fetch source text only into memory. TLS 1.2 is explicitly enabled for Windows PowerShell 5.1.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $client = New-Object Net.WebClient
    $client.Headers['User-Agent'] = 'AMR-Windows-Utility-IRM-Launcher/11'
    $mainText = $client.DownloadString($mainUrl)
    $client.Dispose()
    $mainText = $mainText.TrimStart([char]0xFEFF)
    if ([string]::IsNullOrWhiteSpace($mainText)) { throw 'The main application source was empty.' }
    $shaProvider = [Security.Cryptography.SHA256]::Create()
    try { $actualHash = [BitConverter]::ToString($shaProvider.ComputeHash([Text.Encoding]::UTF8.GetBytes($mainText))).Replace('-','') } finally { $shaProvider.Dispose() }
    if ($actualHash -ne $expectedSha256) { throw 'Main application integrity check failed. The downloaded source does not match the version pinned in this launcher.' }

    # Named pipe transfers the script text directly to the elevated process; no temp script is created.
    $server = New-Object IO.Pipes.NamedPipeServerStream($pipeName,[IO.Pipes.PipeDirection]::Out,1,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::None)
    $readyEvent = New-Object System.Threading.EventWaitHandle($false,[System.Threading.EventResetMode]::ManualReset,$eventName)
    $env:AMR_STARTUP_EVENT_NAME = $eventName
    $env:AMR_LAUNCHER_START_TICKS = [DateTime]::UtcNow.Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)

    # This small bootstrap is encoded on the command line; the large application body travels via pipe.
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
    # Elevate only the child application process. Windows displays its normal UAC consent dialog.
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { $start.Verb = 'RunAs' }
    $child = Start-Process @start

    $server.WaitForConnection()
    $bytes = [Text.Encoding]::UTF8.GetBytes($mainText)
    $server.Write($bytes,0,$bytes.Length); $server.Flush(); $server.Dispose(); $server = $null

    # Keep the splash alive until the WPF window reports its first rendered frame.
    while ($true) {
        [System.Windows.Forms.Application]::DoEvents()
        if ($readyEvent.WaitOne(100)) { break }
        if ($child.HasExited) { $failed = $true; break }
        if ($form.IsDisposed -or -not $form.Visible) { break }
    }
    if ($form -and -not $form.IsDisposed) { $form.Close() }
    if ($failed) { [System.Windows.Forms.MessageBox]::Show('AMR closed before its main window appeared. Check C:\ProgramData\AMR-Utility\Logs.','AMR Startup','OK','Warning') | Out-Null }
} catch {
    try {
        if ($form -and -not $form.IsDisposed) { $form.Close() }
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [System.Windows.Forms.MessageBox]::Show([string]$_.Exception.Message,'AMR IRM Launcher Error','OK','Error') | Out-Null
    } catch { Write-Error $_ }
} finally {
    if ($server) { try { $server.Dispose() } catch {} }
    if ($readyEvent) { try { $readyEvent.Dispose() } catch {} }
    if ($form) { try { $form.Dispose() } catch {} }
    Remove-Item Env:AMR_STARTUP_EVENT_NAME -ErrorAction SilentlyContinue
    Remove-Item Env:AMR_LAUNCHER_START_TICKS -ErrorAction SilentlyContinue
}
