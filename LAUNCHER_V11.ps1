#requires -Version 5.1
<#
AMR Windows Utility - Launcher V12
Windows PowerShell 5.1 | STA | Administrator
Downloads, verifies SHA-256, then starts the real PS1 file in an elevated STA process.
#>
$ErrorActionPreference = 'Stop'
$mainUrl = 'https://raw.githubusercontent.com/3mr10aa/Tool-Pro/Master/AMR_WINDOWS_UTILITY_V11.ps1'
$expectedSha256 = 'D525FCF4ED32EA1416A3FF022C6C97C10B2259B422F88E016450675DA7354EA4'
$root = Join-Path $env:LOCALAPPDATA 'AMR-Utility\Launcher'
$appPath = Join-Path $root 'AMR_WINDOWS_UTILITY_V11.ps1'
$bootstrapPath = Join-Path $root 'AMR_V12_BOOTSTRAP.ps1'
$errorLog = Join-Path $root 'StartupError.log'
$form = $null; $client = $null; $readyEvent = $null; $child = $null
function Set-AMRStatus([string]$message) {
    if ($script:statusLabel) { $script:statusLabel.Text = $message }
    if ($script:form) { $script:form.Refresh(); [Windows.Forms.Application]::DoEvents() }
}
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $form = New-Object Windows.Forms.Form
    $script:form = $form
    $form.Text = 'AMR Windows Utility'
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.StartPosition = 'CenterScreen'
    $form.ClientSize = New-Object Drawing.Size(660,360)
    $form.BackColor = [Drawing.Color]::FromArgb(13,21,36)
    $form.ForeColor = [Drawing.Color]::White
    $form.ShowInTaskbar = $true
    $form.TopMost = $true

    $accent = New-Object Windows.Forms.Panel
    $accent.Dock = 'Top'; $accent.Height = 6
    $accent.BackColor = [Drawing.Color]::FromArgb(62,151,255)
    $form.Controls.Add($accent)

    $brand = New-Object Windows.Forms.Label
    $brand.Location = New-Object Drawing.Point(34,28)
    $brand.Size = New-Object Drawing.Size(590,34)
    $brand.Text = 'AMR  /  WINDOWS UTILITY'
    $brand.ForeColor = [Drawing.Color]::FromArgb(116,185,255)
    $brand.Font = New-Object Drawing.Font('Segoe UI Semibold',15,[Drawing.FontStyle]::Bold)
    $form.Controls.Add($brand)

    $welcome = New-Object Windows.Forms.Label
    $welcome.Location = New-Object Drawing.Point(34,83)
    $welcome.Size = New-Object Drawing.Size(590,54)
    $welcome.Text = 'WELCOME'
    $welcome.ForeColor = [Drawing.Color]::White
    $welcome.Font = New-Object Drawing.Font('Segoe UI Semibold',29,[Drawing.FontStyle]::Bold)
    $form.Controls.Add($welcome)

    $message = New-Object Windows.Forms.Label
    $message.Location = New-Object Drawing.Point(37,146)
    $message.Size = New-Object Drawing.Size(580,48)
    $message.Text = "Thank you for choosing AMR.`r`nPreparing a smooth and secure Windows utility experience."
    $message.ForeColor = [Drawing.Color]::FromArgb(190,202,220)
    $message.Font = New-Object Drawing.Font('Segoe UI',10)
    $form.Controls.Add($message)

    $script:statusLabel = New-Object Windows.Forms.Label
    $script:statusLabel.Location = New-Object Drawing.Point(38,225)
    $script:statusLabel.Size = New-Object Drawing.Size(580,25)
    $script:statusLabel.Text = 'Initializing secure startup...'
    $script:statusLabel.ForeColor = [Drawing.Color]::FromArgb(132,190,255)
    $script:statusLabel.Font = New-Object Drawing.Font('Segoe UI',9)
    $form.Controls.Add($script:statusLabel)

    $progress = New-Object Windows.Forms.ProgressBar
    $progress.Location = New-Object Drawing.Point(38,258)
    $progress.Size = New-Object Drawing.Size(580,7)
    $progress.Style = 'Marquee'
    $progress.MarqueeAnimationSpeed = 24
    $form.Controls.Add($progress)

    $footer = New-Object Windows.Forms.Label
    $footer.Location = New-Object Drawing.Point(38,302)
    $footer.Size = New-Object Drawing.Size(580,22)
    $footer.Text = 'SECURE STARTUP   •   WINDOWS 10 / 11   •   POWERED BY AMR'
    $footer.ForeColor = [Drawing.Color]::FromArgb(111,129,153)
    $footer.Font = New-Object Drawing.Font('Segoe UI',8)
    $form.Controls.Add($footer)

    $form.Show()
    [Windows.Forms.Application]::DoEvents()

    Set-AMRStatus 'Preparing launcher workspace...'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    if (Test-Path -LiteralPath $errorLog) { Remove-Item -LiteralPath $errorLog -Force -ErrorAction SilentlyContinue }

    Set-AMRStatus 'Downloading the official AMR application...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $client = New-Object Net.WebClient
    $client.Headers['User-Agent'] = 'AMR-Windows-Utility-Launcher/12'
    $bytes = $client.DownloadData($mainUrl)
    $client.Dispose(); $client = $null
    if (-not $bytes -or $bytes.Length -lt 100000) { throw 'The downloaded application is empty or unexpectedly small.' }

    Set-AMRStatus 'Verifying application integrity (SHA-256)...'
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $actual = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','') }
    finally { $sha.Dispose() }
    if ($actual -ne $expectedSha256) { throw "SHA-256 verification failed. Expected: $expectedSha256`r`nReceived: $actual`r`nThe application was not started." }

    $utf8 = New-Object System.Text.UTF8Encoding($false,$true)
    try { $null = $utf8.GetString($bytes) } catch { throw 'The application download is not valid UTF-8.' }
    $tempApp = $appPath + '.download'
    [IO.File]::WriteAllBytes($tempApp,$bytes)
    if (Test-Path -LiteralPath $appPath) { Remove-Item -LiteralPath $appPath -Force }
    Move-Item -LiteralPath $tempApp -Destination $appPath -Force

    Set-AMRStatus 'Preparing elevated STA application process...'
    $eventName = 'Local\AMR_V12_READY_' + [guid]::NewGuid().ToString('N')
    $startTicks = [DateTime]::UtcNow.Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)
    $readyEvent = New-Object System.Threading.EventWaitHandle($false,[System.Threading.EventResetMode]::ManualReset,$eventName)

    $qApp = $appPath.Replace("'","''")
    $qEvent = $eventName.Replace("'","''")
    $qTicks = $startTicks.Replace("'","''")
    $qLog = $errorLog.Replace("'","''")
    $bootstrap = @"
`$ErrorActionPreference = 'Stop'
try {
    `$env:AMR_INMEMORY_BOOTSTRAP = '1'
    `$env:AMR_STARTUP_EVENT_NAME = '$qEvent'
    `$env:AMR_LAUNCHER_START_TICKS = '$qTicks'
    & '$qApp'
} catch {
    `$detail = (`$_ | Out-String)
    try { [IO.File]::WriteAllText('$qLog', `$detail, (New-Object Text.UTF8Encoding(`$false))) } catch {}
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [Windows.Forms.MessageBox]::Show("AMR could not start.`r`n`r`n" + `$_.Exception.Message + "`r`n`r`nDetails: $qLog",'AMR Startup Error','OK','Error') | Out-Null
    } catch {}
    exit 1
}
"@
    [IO.File]::WriteAllText($bootstrapPath,$bootstrap,(New-Object Text.UTF8Encoding($false)))

    $powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) { throw 'Windows PowerShell 5.1 executable was not found.' }
    $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $bootstrapPath + '"'
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $start = @{ FilePath=$powershellExe; ArgumentList=$argLine; PassThru=$true; ErrorAction='Stop' }
    if (-not $isAdmin) { $start.Verb = 'RunAs' }
    $child = Start-Process @start

    Set-AMRStatus 'Launching AMR and waiting for its main window...'
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $ready = $false
    while ($clock.Elapsed.TotalSeconds -lt 180) {
        [Windows.Forms.Application]::DoEvents()
        if ($readyEvent.WaitOne(100)) { $ready = $true; break }
        $child.Refresh()
        if ($child.HasExited) {
            $extra = ''
            if (Test-Path -LiteralPath $errorLog) { $extra = "`r`n`r`n" + (Get-Content -LiteralPath $errorLog -Raw) }
            throw "The AMR process exited before the main window rendered. Exit code: $($child.ExitCode).$extra"
        }
    }
    if (-not $ready) { throw 'Timed out after 180 seconds waiting for the AMR main window to render.' }
    Set-AMRStatus 'AMR is ready. Enjoy using the utility.'
    Start-Sleep -Milliseconds 500
    $form.Close()
}
catch {
    $msg = [string]$_.Exception.Message
    if ($form) { try { $form.TopMost = $false } catch {} }
    try { [Windows.Forms.MessageBox]::Show($msg,'AMR Windows Utility - Launcher Error',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error) | Out-Null }
    catch { Write-Host $msg -ForegroundColor Red }
}
finally {
    if ($client) { try { $client.Dispose() } catch {} }
    if ($readyEvent) { try { $readyEvent.Dispose() } catch {} }
    if ($form) { try { $form.Dispose() } catch {} }
}
