<#
AMR Windows Utility - Lightweight Startup Launcher V8
Place this launcher in the same folder as AMR_WINDOWS_UTILITY_STARTUP_OPTIMIZED_V8.ps1.
Windows PowerShell 5.1 | STA | Single UAC request when elevation is required.
#>

$ErrorActionPreference = 'Stop'

# Hide only the legacy PowerShell console. Windows UAC consent remains visible by design.
try {
    if ($Host.Name -eq 'ConsoleHost' -and [string]::IsNullOrWhiteSpace([string]$env:WT_SESSION)) {
        if (-not ('AMRLauncher.NativeWindow' -as [type])) {
            Add-Type -Namespace AMRLauncher -Name NativeWindow -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@
        }
        $consoleHandle = [AMRLauncher.NativeWindow]::GetConsoleWindow()
        if ($consoleHandle -ne [IntPtr]::Zero) { [void][AMRLauncher.NativeWindow]::ShowWindow($consoleHandle,0) }
    }
} catch {}

function Test-AMRLauncherAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$needsAdmin = -not (Test-AMRLauncherAdmin)
$needsSta = ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA')
if ($needsAdmin -or $needsSta) {
    $launcherPath = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($launcherPath) -or -not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show('Save the launcher as a .ps1 file before running it.','AMR Windows Utility','OK','Warning') | Out-Null
        exit 1
    }
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',('"{0}"' -f $launcherPath))
    $startParams = @{ FilePath='powershell.exe'; ArgumentList=$arguments; WindowStyle='Hidden'; ErrorAction='Stop' }
    if ($needsAdmin) { $startParams.Verb = 'RunAs' }
    try { Start-Process @startParams | Out-Null }
    catch { exit 1 }
    exit
}

$mainScript = Join-Path $PSScriptRoot 'AMR_WINDOWS_UTILITY_STARTUP_OPTIMIZED_V8.ps1'
if (-not (Test-Path -LiteralPath $mainScript -PathType Leaf)) {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        "The main application file was not found:`r`n$mainScript`r`n`r`nKeep both V8 files in the same folder.",
        'AMR Windows Utility','OK','Error'
    ) | Out-Null
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
$eventName = 'Local\AMR.Startup.Ready.' + [guid]::NewGuid().ToString('N')
$eventCreated = $false
$readyEvent = $null
$appProcess = $null
$timer = $null
$form = $null
$startupFailed = $false

try {
    $readyEvent = [System.Threading.EventWaitHandle]::new($false,[System.Threading.EventResetMode]::ManualReset,$eventName,[ref]$eventCreated)
    $env:AMR_STARTUP_EVENT_NAME = $eventName
    $env:AMR_LAUNCHER_START_TICKS = [DateTime]::UtcNow.Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'AMR Windows Utility'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.ClientSize = [System.Drawing.Size]::new(520,210)
    $form.BackColor = [System.Drawing.Color]::FromArgb(15,27,43)
    $form.ForeColor = [System.Drawing.Color]::White
    $form.ShowInTaskbar = $false
    $form.TopMost = $true

    $brand = New-Object System.Windows.Forms.Label
    $brand.Dock = [System.Windows.Forms.DockStyle]::Top
    $brand.Height = 54
    $brand.Text = 'AMR WINDOWS UTILITY'
    $brand.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $brand.ForeColor = [System.Drawing.Color]::FromArgb(96,165,250)
    $brand.Font = [System.Drawing.Font]::new('Segoe UI',17,[System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($brand)

    $welcome = New-Object System.Windows.Forms.Label
    $welcome.Dock = [System.Windows.Forms.DockStyle]::Fill
    $welcome.Text = "Thank you for choosing AMR.`r`nWe appreciate your trust and are working to make your experience smoother and faster."
    $welcome.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $welcome.ForeColor = [System.Drawing.Color]::FromArgb(241,245,249)
    $welcome.Font = [System.Drawing.Font]::new('Segoe UI',12,[System.Drawing.FontStyle]::Regular)
    $form.Controls.Add($welcome)

    $loading = New-Object System.Windows.Forms.Label
    $loading.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $loading.Height = 34
    $loading.Text = 'Preparing your workspace...'
    $loading.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $loading.ForeColor = [System.Drawing.Color]::FromArgb(148,163,184)
    $loading.Font = [System.Drawing.Font]::new('Segoe UI',9,[System.Drawing.FontStyle]::Regular)
    $form.Controls.Add($loading)

    # Paint the splash before the large application script is even parsed.
    $form.Show()
    $form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()

    # Start the heavyweight 1.6 MB application only after the lightweight splash is visible.
    $powerShellExe = Join-Path $PSHOME 'powershell.exe'
    $appArgs = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',('"{0}"' -f $mainScript))
    $appProcess = Start-Process -FilePath $powerShellExe -ArgumentList $appArgs -WorkingDirectory $PSScriptRoot -WindowStyle Hidden -PassThru

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 150
    $timer.Add_Tick({
        try {
            if ($readyEvent -and $readyEvent.WaitOne(0)) {
                $timer.Stop()
                $form.Close()
                return
            }
            if ($appProcess -and $appProcess.HasExited) {
                $script:startupFailed = $true
                $timer.Stop()
                $form.Close()
                return
            }
        } catch {
            $script:startupFailed = $true
            $timer.Stop()
            $form.Close()
        }
    }.GetNewClosure())
    $timer.Start()
    [System.Windows.Forms.Application]::Run($form)

    if ($startupFailed) {
        [System.Windows.Forms.MessageBox]::Show(
            "AMR Windows Utility closed before the main window appeared.`r`nCheck the latest log in C:\ProgramData\AMR-Utility\Logs.",
            'AMR Startup','OK','Warning'
        ) | Out-Null
    }
} catch {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'AMR Startup Error','OK','Error') | Out-Null
    } catch {}
} finally {
    if ($timer) { try { $timer.Stop(); $timer.Dispose() } catch {} }
    if ($form) { try { $form.Dispose() } catch {} }
    if ($readyEvent) { try { $readyEvent.Dispose() } catch {} }
    Remove-Item Env:AMR_STARTUP_EVENT_NAME -ErrorAction SilentlyContinue
    Remove-Item Env:AMR_LAUNCHER_START_TICKS -ErrorAction SilentlyContinue
}
