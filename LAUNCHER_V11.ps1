<#
AMR Windows Utility - IRM In-Memory Launcher V11
Windows PowerShell 5.1 | WPF | Administrator | STA
Downloads the approved main script, verifies its exact SHA-256 bytes,
and streams it to an elevated STA PowerShell process without saving it to disk.
#>
$ErrorActionPreference = 'Stop'
$mainUrl = 'https://raw.githubusercontent.com/3mr10aa/Tool-Pro/Master/AMR_WINDOWS_UTILITY_V11.ps1'
# Hash observed from the exact current GitHub raw download in the user's launcher error.
$expectedSha256 = '468CCD57E13593CC2095063FEE7D7747A1B27001D2BAF2DFC811E83896C3978B'
$client = $null; $server = $null; $readyEvent = $null; $form = $null; $child = $null
$pipeName = 'AMR_' + [guid]::NewGuid().ToString('N')
$eventName = 'Local\AMR_V11_READY_' + [guid]::NewGuid().ToString('N')
$startTicks = [DateTime]::UtcNow.Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'AMR Windows Utility'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.StartPosition = 'CenterScreen'
    $form.ClientSize = [System.Drawing.Size]::new(620,300)
    $form.BackColor = [System.Drawing.Color]::FromArgb(11,18,32)
    $form.ForeColor = [System.Drawing.Color]::White
    $form.ShowInTaskbar = $false; $form.TopMost = $true
    $brand = New-Object System.Windows.Forms.Label
    $brand.Dock = 'Top'; $brand.Height = 82
    $brand.Text = 'AMR WINDOWS UTILITY'; $brand.TextAlign = 'MiddleCenter'
    $brand.ForeColor = [System.Drawing.Color]::FromArgb(125,183,255)
    $brand.Font = [System.Drawing.Font]::new('Segoe UI',21,[System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($brand)
    $welcome = New-Object System.Windows.Forms.Label
    $welcome.Dock = 'Fill'; $welcome.TextAlign = 'MiddleCenter'
    $welcome.Text = "Thank you for your appreciation.`r`n`r`nWe value your time and will work hard to deliver`r`nthe best and fastest user experience."
    $welcome.Font = [System.Drawing.Font]::new('Segoe UI',12)
    $form.Controls.Add($welcome)
    $loading = New-Object System.Windows.Forms.Label
    $loading.Dock = 'Bottom'; $loading.Height = 38
    $loading.Text = 'Preparing your experience...'; $loading.TextAlign = 'MiddleCenter'
    $loading.ForeColor = [System.Drawing.Color]::FromArgb(148,163,184)
    $form.Controls.Add($loading)
    $form.Show(); $form.Refresh(); [System.Windows.Forms.Application]::DoEvents()

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $client = New-Object Net.WebClient
    $client.Headers['User-Agent'] = 'AMR-Windows-Utility-IRM-Launcher/11'
    $mainBytes = $client.DownloadData($mainUrl)
    $client.Dispose(); $client = $null
    if (-not $mainBytes -or $mainBytes.Length -eq 0) { throw 'The main application download was empty.' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $actualHash = [BitConverter]::ToString($sha.ComputeHash($mainBytes)).Replace('-','') }
    finally { $sha.Dispose() }
    if ($actualHash -ne $expectedSha256) {
        throw "Integrity check failed. Expected $expectedSha256 but received $actualHash. No application code was started."
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false,$true)
    try { $null = $utf8.GetString($mainBytes) } catch { throw 'The downloaded application is not valid UTF-8.' }

    $readyEvent = [System.Threading.EventWaitHandle]::new($false,[System.Threading.EventResetMode]::ManualReset,$eventName)
    $server = New-Object IO.Pipes.NamedPipeServerStream($pipeName,[IO.Pipes.PipeDirection]::Out,1,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::None)
    $bootstrap = @"
`$ErrorActionPreference = 'Stop'
`$pipe = New-Object IO.Pipes.NamedPipeClientStream('.', '$pipeName', [IO.Pipes.PipeDirection]::In)
`$pipe.Connect(45000)
`$memory = New-Object IO.MemoryStream
`$pipe.CopyTo(`$memory); `$pipe.Dispose()
`$source = [Text.Encoding]::UTF8.GetString(`$memory.ToArray()); `$memory.Dispose()
`$env:AMR_INMEMORY_BOOTSTRAP = '1'
`$env:AMR_STARTUP_EVENT_NAME = '$eventName'
`$env:AMR_LAUNCHER_START_TICKS = '$startTicks'
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
    $ready = $false; $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.Elapsed.TotalSeconds -lt 180) {
        [System.Windows.Forms.Application]::DoEvents()
        if ($readyEvent.WaitOne(100)) { $ready = $true; break }
        $child.Refresh()
        if ($child.HasExited) { throw "AMR exited before its main window appeared (exit code $($child.ExitCode))." }
    }
    if (-not $ready) { throw 'Timed out waiting for the AMR main window to finish rendering.' }
    $form.Close(); $form = $null
} catch {
    $message = [string]$_.Exception.Message
    if ($form) { try { $form.Close() } catch {} }
    try { [System.Windows.Forms.MessageBox]::Show($message,'AMR Windows Utility - Launcher Error',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null }
    catch { Write-Error $message }
} finally {
    if ($client) { try { $client.Dispose() } catch {} }
    if ($server) { try { $server.Dispose() } catch {} }
    if ($readyEvent) { try { $readyEvent.Dispose() } catch {} }
    if ($form) { try { $form.Dispose() } catch {} }
}
