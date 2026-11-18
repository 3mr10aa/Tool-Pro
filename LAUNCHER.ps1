#requires -Version 5.1
# AMR Tool-Pro | Premium animated bootstrap launcher
# Windows PowerShell 5.1 | Public command: irm <raw-launcher-url> | iex

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRaw = 'https://raw.githubusercontent.com/3mr10aa/Tool-Pro/main'
$installRoot = Join-Path $env:LOCALAPPDATA 'AMR-ToolPro\Runtime'
$stageRoot = Join-Path $env:TEMP ('AMR-ToolPro-' + [guid]::NewGuid().ToString('N'))
$logPath = Join-Path $env:TEMP 'AMR_ToolPro_Launcher.log'
$script:LauncherForm = $null
$script:ProgressTrack = $null
$script:ProgressFill = $null
$script:PercentLabel = $null
$script:StatusLabel = $null
$script:DetailLabel = $null
$script:ProgressValue = 0
$script:LastUiUpdate = [DateTime]::MinValue

$expected = [ordered]@{
    'AMR_Windows_Utility_V1.ps1' = '79BA8860BDDDD732A8CF7A92B1AA92A15027C1ED90DF144B953585CE0123AF86'
    'AMR_WebView2/Microsoft.Web.WebView2.Core.dll' = 'ACDD517B951829F763D1255F32DF1E6A936CB8623A7EBFF6B8B24172DEDE6BD6'
    'AMR_WebView2/Microsoft.Web.WebView2.Wpf.dll' = 'BAAFA0A595C2CEFB3BE8F18288C3DB76F52E3966C8B99957D5E56CAF1B137BC1'
    'AMR_WebView2/x64/WebView2Loader.dll' = 'D3FCE90BDEECB08596E377DEA6A316354DD8949E32FF09B89D51BE00C14E21B6'
    'AMR_WebView2/x86/WebView2Loader.dll' = '1D348D3C0A5CB0D985389B68A0FD9BF966C2AED65F5E44BBC0233739B7A57F9E'
}

function Write-AMRLauncherLog {
    param([string]$Message)
    try { Add-Content -LiteralPath $logPath -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message) -Encoding UTF8 } catch {}
}

function Pump-AMRLauncherUI {
    if ($script:LauncherForm -and -not $script:LauncherForm.IsDisposed) {
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Set-AMRLauncherProgress {
    param([int]$Percent, [string]$Status, [string]$Detail)
    if (-not $script:LauncherForm -or $script:LauncherForm.IsDisposed) { return }
    $value = [Math]::Max(0, [Math]::Min(99, $Percent))
    $script:ProgressValue = $value
    $width = [int][Math]::Round(($script:ProgressTrack.ClientSize.Width * $value) / 100.0)
    $script:ProgressFill.Width = [Math]::Max(0, [Math]::Min($script:ProgressTrack.ClientSize.Width, $width))
    $script:PercentLabel.Text = ('{0}%' -f $value)
    $script:StatusLabel.Text = $Status
    $script:DetailLabel.Text = $Detail
    $script:LauncherForm.Refresh()
    Pump-AMRLauncherUI
}

function Get-AMRFile {
    param(
        [string]$RelativePath,
        [string]$Destination,
        [int]$FileIndex,
        [int]$FileCount,
        [System.Collections.IDictionary]$ExpectedPins
    )
    # Normalize the lookup key and receive the pin dictionary explicitly.
    # This avoids relying on dynamic scope when the launcher is invoked via irm | iex.
    $normalizedPath = $RelativePath.Replace('\', '/')
    $url = $repoRaw + '/' + $normalizedPath
    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $request = [System.Net.HttpWebRequest]::Create($url)
    $request.Method = 'GET'
    $request.UserAgent = 'AMR-ToolPro-Premium-Launcher/2.0'
    $request.AllowAutoRedirect = $true
    $request.Timeout = 45000
    $request.ReadWriteTimeout = 45000
    $response = $null
    $inputStream = $null
    $outputStream = $null
    try {
        $response = $request.GetResponse()
        $totalBytes = [int64]$response.ContentLength
        $inputStream = $response.GetResponseStream()
        $outputStream = New-Object System.IO.FileStream($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $buffer = New-Object byte[] 65536
        [int64]$received = 0
        $lastPaint = [DateTime]::MinValue
        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outputStream.Write($buffer, 0, $read)
            $received += $read
            $now = [DateTime]::UtcNow
            if (($now - $lastPaint).TotalMilliseconds -ge 90) {
                if ($totalBytes -gt 0) {
                    $fraction = [Math]::Min(1.0, ($received / [double]$totalBytes))
                } else {
                    # Unknown Content-Length: keep the current file's share moving,
                    # but reserve its final few points until EOF confirms completion.
                    $fraction = [Math]::Min(0.94, $received / [double]([Math]::Max(1, 4MB)))
                }
                $overall = (($FileIndex + $fraction) / $FileCount) * 82.0
                $detail = if ($totalBytes -gt 0) {
                    '{0}  |  {1:N1} / {2:N1} MB' -f $RelativePath, ($received / 1MB), ($totalBytes / 1MB)
                } else {
                    '{0}  |  {1:N1} MB received' -f $RelativePath, ($received / 1MB)
                }
                Set-AMRLauncherProgress -Percent ([int][Math]::Floor($overall)) -Status 'Downloading verified AMR components...' -Detail $detail
                $lastPaint = $now
            }
        }
        $outputStream.Flush()
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Dispose() }
    }

    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) { throw "Download did not create: $RelativePath" }
    $item = Get-Item -LiteralPath $Destination
    if ($item.Length -le 0) { throw "Downloaded file is empty: $RelativePath" }
    # Finish this file's progress only after its stream reached EOF successfully.
    $completePercent = [int][Math]::Floor((($FileIndex + 1) / $FileCount) * 82.0)
    Set-AMRLauncherProgress -Percent $completePercent -Status 'Downloading verified AMR components...' -Detail ('Received {0:N1} MB  |  {1} of {2} files' -f ($item.Length / 1MB), ($FileIndex + 1), $FileCount)

    if ($null -eq $ExpectedPins) { throw 'The launcher integrity-pin dictionary was not passed to the download worker.' }
    if (-not $ExpectedPins.Contains($normalizedPath)) { throw "No integrity-pin entry exists for '$normalizedPath'." }
    $pin = [string]$ExpectedPins[$normalizedPath]
    if ($pin -notmatch '^[A-Fa-f0-9]{64}$') {
        throw "Integrity-pin entry for '$normalizedPath' is malformed (expected exactly 64 hexadecimal characters)."
    }
    $actual = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
    if ($actual -ne $pin.ToUpperInvariant()) {
        throw "SHA-256 verification failed for $RelativePath. Expected $pin but received $actual"
    }
    Write-AMRLauncherLog ("Verified {0} | {1} bytes | SHA256={2}" -f $RelativePath, $item.Length, $actual)
}

try {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is not available.' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    if (-not ('AMR.ToolProLauncherNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace AMR {
    [StructLayout(LayoutKind.Sequential)] public struct AccentPolicy { public int AccentState; public int AccentFlags; public int GradientColor; public int AnimationId; }
    [StructLayout(LayoutKind.Sequential)] public struct WindowCompositionAttributeData { public int Attribute; public IntPtr Data; public int SizeOfData; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    public static class ToolProLauncherNative {
        [DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowCompositionAttribute(IntPtr hwnd, ref WindowCompositionAttributeData data);
        [DllImport("user32.dll")] public static extern bool ReleaseCapture();
        [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hwnd, int msg, int wParam, int lParam);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int processId);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr extraData);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out int processId);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hwnd);
        private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr extraData);
        public static IntPtr FindVisibleWindow(int targetPid) {
            IntPtr found = IntPtr.Zero;
            EnumWindows(delegate(IntPtr hwnd, IntPtr extra) {
                int pid; GetWindowThreadProcessId(hwnd, out pid);
                if (pid == targetPid && IsWindowVisible(hwnd) && !IsIconic(hwnd)) { found = hwnd; return false; }
                return true;
            }, IntPtr.Zero);
            return found;
        }
    }
}
'@
    }

    # Premium splash design follows the supplied install_fixed.ps1.txt reference.
    $form = New-Object System.Windows.Forms.Form
    $script:LauncherForm = $form
    $form.Text = 'AMR | WINDOWS UTILITY'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.ClientSize = New-Object System.Drawing.Size(590, 310)
    $form.MinimumSize = New-Object System.Drawing.Size(590, 310)
    $form.BackColor = [System.Drawing.Color]::FromArgb(22, 29, 41)
    $form.ForeColor = [System.Drawing.Color]::White
    $form.ShowInTaskbar = $true
    $form.TopMost = $true
    $form.Opacity = 0

    $caption = New-Object System.Windows.Forms.Panel
    $caption.Location = New-Object System.Drawing.Point(0, 0)
    $caption.Size = New-Object System.Drawing.Size(590, 36)
    $caption.BackColor = [System.Drawing.Color]::FromArgb(38, 52, 70)
    $form.Controls.Add($caption)

    $captionIcon = New-Object System.Windows.Forms.PictureBox
    $captionIcon.Location = New-Object System.Drawing.Point(12, 7)
    $captionIcon.Size = New-Object System.Drawing.Size(22, 22)
    $captionIcon.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $caption.Controls.Add($captionIcon)

    $captionTitle = New-Object System.Windows.Forms.Label
    $captionTitle.Location = New-Object System.Drawing.Point(42, 4)
    $captionTitle.Size = New-Object System.Drawing.Size(430, 28)
    $captionTitle.Text = 'AMR  |  WINDOWS UTILITY'
    $captionTitle.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $captionTitle.ForeColor = [System.Drawing.Color]::White
    $captionTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $caption.Controls.Add($captionTitle)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Location = New-Object System.Drawing.Point(552, 3)
    $closeButton.Size = New-Object System.Drawing.Size(32, 28)
    $closeButton.Text = [char]0x00D7
    $closeButton.Font = New-Object System.Drawing.Font('Segoe UI', 15)
    $closeButton.ForeColor = [System.Drawing.Color]::FromArgb(210, 220, 233)
    $closeButton.BackColor = [System.Drawing.Color]::FromArgb(45, 65, 88)
    $closeButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $closeButton.FlatAppearance.BorderSize = 0
    $closeButton.Add_Click({ $script:LauncherForm.Close() })
    $caption.Controls.Add($closeButton)

    $dragCaption = {
        if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            [void][AMR.ToolProLauncherNative]::ReleaseCapture()
            [void][AMR.ToolProLauncherNative]::SendMessage($script:LauncherForm.Handle, 0xA1, 0x2, 0)
        }
    }.GetNewClosure()
    $caption.Add_MouseDown($dragCaption)
    $captionTitle.Add_MouseDown($dragCaption)

    $applyAcrylic = {
        try {
            $policy = New-Object AMR.AccentPolicy
            $policy.AccentState = 4
            $policy.AccentFlags = 2
            $policy.GradientColor = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]0x44563A20), 0)
            $size = [Runtime.InteropServices.Marshal]::SizeOf([type][AMR.AccentPolicy])
            $memory = [Runtime.InteropServices.Marshal]::AllocHGlobal($size)
            try {
                [Runtime.InteropServices.Marshal]::StructureToPtr($policy, $memory, $false)
                $data = New-Object AMR.WindowCompositionAttributeData
                $data.Attribute = 19
                $data.Data = $memory
                $data.SizeOfData = $size
                $ok = [AMR.ToolProLauncherNative]::SetWindowCompositionAttribute($script:LauncherForm.Handle, [ref]$data)
                if (-not $ok) {
                    $policy.AccentState = 3
                    [Runtime.InteropServices.Marshal]::StructureToPtr($policy, $memory, $true)
                    [void][AMR.ToolProLauncherNative]::SetWindowCompositionAttribute($script:LauncherForm.Handle, [ref]$data)
                }
            } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($memory) }
        } catch { Write-AMRLauncherLog ('Acrylic effect unavailable: ' + $_.Exception.Message) }
    }.GetNewClosure()
    $form.Add_Shown($applyAcrylic)

    $thanks = New-Object System.Windows.Forms.Label
    $thanks.Location = New-Object System.Drawing.Point(30, 49)
    $thanks.Size = New-Object System.Drawing.Size(530, 25)
    $thanks.Text = 'Thank you for your trust and support. We truly appreciate you.'
    $thanks.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
    $thanks.BackColor = [System.Drawing.Color]::Transparent
    $thanks.ForeColor = [System.Drawing.Color]::White
    $thanks.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $form.Controls.Add($thanks)

    $edition = New-Object System.Windows.Forms.Label
    $edition.Location = New-Object System.Drawing.Point(30, 81)
    $edition.Size = New-Object System.Drawing.Size(530, 27)
    $edition.Text = 'PREMIUM EDITION'
    $edition.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $edition.BackColor = [System.Drawing.Color]::Transparent
    $edition.ForeColor = [System.Drawing.Color]::FromArgb(229, 190, 75)
    $edition.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $form.Controls.Add($edition)

    $tagline = New-Object System.Windows.Forms.Label
    $tagline.Location = New-Object System.Drawing.Point(30, 112)
    $tagline.Size = New-Object System.Drawing.Size(530, 22)
    $tagline.Text = 'We work hard every day for your happiness.'
    $tagline.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $tagline.BackColor = [System.Drawing.Color]::Transparent
    $tagline.ForeColor = [System.Drawing.Color]::FromArgb(198, 211, 228)
    $tagline.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $form.Controls.Add($tagline)

    $script:StatusLabel = New-Object System.Windows.Forms.Label
    $script:StatusLabel.Location = New-Object System.Drawing.Point(42, 151)
    $script:StatusLabel.Size = New-Object System.Drawing.Size(506, 24)
    $script:StatusLabel.Text = 'Getting everything ready for you...'
    $script:StatusLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $script:StatusLabel.BackColor = [System.Drawing.Color]::Transparent
    $script:StatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
    $form.Controls.Add($script:StatusLabel)

    $script:ProgressTrack = New-Object System.Windows.Forms.Panel
    $script:ProgressTrack.Location = New-Object System.Drawing.Point(42, 187)
    $script:ProgressTrack.Size = New-Object System.Drawing.Size(440, 12)
    $script:ProgressTrack.BackColor = [System.Drawing.Color]::FromArgb(48, 67, 91)
    $form.Controls.Add($script:ProgressTrack)

    $script:ProgressFill = New-Object System.Windows.Forms.Panel
    $script:ProgressFill.Location = New-Object System.Drawing.Point(0, 0)
    $script:ProgressFill.Size = New-Object System.Drawing.Size(0, 12)
    $script:ProgressFill.BackColor = [System.Drawing.Color]::FromArgb(72, 166, 255)
    $script:ProgressTrack.Controls.Add($script:ProgressFill)

    $script:PercentLabel = New-Object System.Windows.Forms.Label
    $script:PercentLabel.Location = New-Object System.Drawing.Point(490, 180)
    $script:PercentLabel.Size = New-Object System.Drawing.Size(58, 25)
    $script:PercentLabel.Text = '0%'
    $script:PercentLabel.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $script:PercentLabel.BackColor = [System.Drawing.Color]::Transparent
    $script:PercentLabel.ForeColor = [System.Drawing.Color]::FromArgb(112, 190, 255)
    $script:PercentLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $form.Controls.Add($script:PercentLabel)

    $script:DetailLabel = New-Object System.Windows.Forms.Label
    $script:DetailLabel.Location = New-Object System.Drawing.Point(42, 214)
    $script:DetailLabel.Size = New-Object System.Drawing.Size(506, 22)
    $script:DetailLabel.Text = 'Preparing secure connection to GitHub...'
    $script:DetailLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8)
    $script:DetailLabel.BackColor = [System.Drawing.Color]::Transparent
    $script:DetailLabel.ForeColor = [System.Drawing.Color]::FromArgb(157, 174, 196)
    $form.Controls.Add($script:DetailLabel)

    $footer = New-Object System.Windows.Forms.Label
    $footer.Location = New-Object System.Drawing.Point(30, 258)
    $footer.Size = New-Object System.Drawing.Size(530, 20)
    $footer.Text = 'SECURE DOWNLOAD  •  SHA-256 VERIFIED  •  AMR TOOL-PRO'
    $footer.Font = New-Object System.Drawing.Font('Segoe UI', 7, [System.Drawing.FontStyle]::Bold)
    $footer.BackColor = [System.Drawing.Color]::Transparent
    $footer.ForeColor = [System.Drawing.Color]::FromArgb(126, 151, 181)
    $footer.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $form.Controls.Add($footer)

    $form.Show()
    $form.Refresh()
    $fadeInTimer = New-Object System.Windows.Forms.Timer
    $fadeInTimer.Interval = 15
    $fadeInTimer.Add_Tick({
        if ($script:LauncherForm.Opacity -lt 0.97) { $script:LauncherForm.Opacity = [Math]::Min(1.0, $script:LauncherForm.Opacity + 0.12) }
        else { $script:LauncherForm.Opacity = 1; $fadeInTimer.Stop(); $fadeInTimer.Dispose() }
    }.GetNewClosure())
    $fadeInTimer.Start()
    Pump-AMRLauncherUI

    Write-AMRLauncherLog 'Starting AMR Tool-Pro premium bootstrap.'
    Set-AMRLauncherProgress -Percent 0 -Status 'Getting everything ready for you...' -Detail 'Connecting securely to GitHub...'
    New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null

    $fileCount = $expected.Count
    $index = 0
    foreach ($relative in $expected.Keys) {
        $destination = Join-Path $stageRoot ($relative -replace '/', '\')
        Get-AMRFile -RelativePath $relative -Destination $destination -FileIndex $index -FileCount $fileCount -ExpectedPins $expected
        $index++
    }

    $appStage = Join-Path $stageRoot 'AMR_Windows_Utility_V1.ps1'
    Set-AMRLauncherProgress -Percent 84 -Status 'All downloads complete — validating application...' -Detail 'Checking PowerShell syntax and runtime file layout...'
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($appStage, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        $syntaxSummary = ($parseErrors | Select-Object -First 5 | ForEach-Object { 'Line {0}: {1}' -f $_.Extent.StartLineNumber, $_.Message }) -join [Environment]::NewLine
        throw ('Application PowerShell syntax validation failed:' + [Environment]::NewLine + $syntaxSummary)
    }
    $appInfo = Get-Item -LiteralPath $appStage
    if ($appInfo.Length -lt 100000) { throw 'The downloaded application script is unexpectedly small.' }
    $dllCore = Join-Path $stageRoot 'AMR_WebView2\Microsoft.Web.WebView2.Core.dll'
    $dllWpf = Join-Path $stageRoot 'AMR_WebView2\Microsoft.Web.WebView2.Wpf.dll'
    if (-not (Test-Path -LiteralPath $dllCore -PathType Leaf) -or -not (Test-Path -LiteralPath $dllWpf -PathType Leaf)) {
        throw 'The verified WebView2 managed assemblies are missing from the staged runtime.'
    }
    Set-AMRLauncherProgress -Percent 91 -Status 'Integrity and syntax checks passed...' -Detail 'Preparing the verified runtime without touching your existing files...'

    # Pull the high-resolution AMR ICO frame from the verified main script.
    try {
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $reader = New-Object System.IO.StreamReader($appStage, $strictUtf8, $true)
        try { $appTextForIcon = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $iconMatch = [regex]::Match($appTextForIcon, '\$amrIconBytes\s*=\s*\[Convert\]::FromBase64String\(''([^'']+)''\)')
        if ($iconMatch.Success) {
            $iconBytes = [Convert]::FromBase64String($iconMatch.Groups[1].Value)
            if ($iconBytes.Length -ge 22 -and $iconBytes[0] -eq 0 -and $iconBytes[1] -eq 0 -and $iconBytes[2] -eq 1) {
                $frameCount = [BitConverter]::ToUInt16($iconBytes, 4)
                $chosen = $null
                for ($i = 0; $i -lt $frameCount; $i++) {
                    $entry = 6 + (16 * $i)
                    $w = [int]$iconBytes[$entry]; if ($w -eq 0) { $w = 256 }
                    $h = [int]$iconBytes[$entry + 1]; if ($h -eq 0) { $h = 256 }
                    $length = [BitConverter]::ToUInt32($iconBytes, $entry + 8)
                    $offset = [BitConverter]::ToUInt32($iconBytes, $entry + 12)
                    if ($w -ge 48 -and $h -ge 48 -and ($offset + $length) -le $iconBytes.Length) {
                        $chosen = @{ Width = $w; Height = $h; Length = [int]$length; Offset = [int]$offset }
                        break
                    }
                }
                if ($null -ne $chosen) {
                    $pngBytes = New-Object byte[] $chosen.Length
                    [Buffer]::BlockCopy($iconBytes, $chosen.Offset, $pngBytes, 0, $chosen.Length)
                    $pngStream = New-Object System.IO.MemoryStream(,$pngBytes)
                    try {
                        $sourceImage = [System.Drawing.Image]::FromStream($pngStream)
                        try { $captionIcon.Image = New-Object System.Drawing.Bitmap($sourceImage) } finally { $sourceImage.Dispose() }
                    } finally { $pngStream.Dispose() }
                    $singleIco = New-Object byte[] (22 + $chosen.Length)
                    $singleIco[2] = 1; $singleIco[4] = 1
                    $singleIco[6] = [byte]($chosen.Width -band 255); $singleIco[7] = [byte]($chosen.Height -band 255)
                    $singleIco[10] = 1; $singleIco[12] = 32
                    [Buffer]::BlockCopy([BitConverter]::GetBytes([uint32]$chosen.Length), 0, $singleIco, 14, 4)
                    [Buffer]::BlockCopy([BitConverter]::GetBytes([uint32]22), 0, $singleIco, 18, 4)
                    [Buffer]::BlockCopy($pngBytes, 0, $singleIco, 22, $chosen.Length)
                    $iconStream = New-Object System.IO.MemoryStream(,$singleIco)
                    try { $form.Icon = New-Object System.Drawing.Icon($iconStream) } finally { $iconStream.Dispose() }
                    Write-AMRLauncherLog ('Applied embedded AMR icon ({0}x{1}).' -f $chosen.Width, $chosen.Height)
                }
            }
        }
    } catch { Write-AMRLauncherLog ('Optional launcher icon extraction failed: ' + $_.Exception.Message) }

    # Atomically replace the complete runtime; restore the previous runtime if publish fails.
    $installParent = Split-Path -Parent $installRoot
    New-Item -ItemType Directory -Path $installParent -Force | Out-Null
    $backupRoot = $installRoot + '.previous'
    if (Test-Path -LiteralPath $backupRoot) { Remove-Item -LiteralPath $backupRoot -Recurse -Force }
    $hadPrevious = Test-Path -LiteralPath $installRoot
    if ($hadPrevious) { Move-Item -LiteralPath $installRoot -Destination $backupRoot -Force }
    try {
        Move-Item -LiteralPath $stageRoot -Destination $installRoot -Force
        $stageRoot = $null
        if (Test-Path -LiteralPath $backupRoot) { Remove-Item -LiteralPath $backupRoot -Recurse -Force }
    } catch {
        if ((Test-Path -LiteralPath $backupRoot) -and -not (Test-Path -LiteralPath $installRoot)) {
            Move-Item -LiteralPath $backupRoot -Destination $installRoot -Force
        }
        throw
    }

    $appPath = Join-Path $installRoot 'AMR_Windows_Utility_V1.ps1'
    $powershellExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) { $powershellExe = 'powershell.exe' }
    $quotedApp = '"' + $appPath.Replace('"', '""') + '"'
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File ' + $quotedApp
    Set-AMRLauncherProgress -Percent 94 -Status 'Launching AMR Tool-Pro...' -Detail 'Waiting for the main application window to appear...'
    Write-AMRLauncherLog ('Launching verified app from ' + $appPath)
    $appProcess = Start-Process -FilePath $powershellExe -ArgumentList $arguments -WorkingDirectory $installRoot -WindowStyle Hidden -PassThru -ErrorAction Stop

    # Detect the actual visible WPF window; do not fake a 100% download indicator.
    $appHandle = [IntPtr]::Zero
    $stableSince = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(180)
    while ([DateTime]::UtcNow -lt $deadline) {
        Pump-AMRLauncherUI
        $appProcess.Refresh()
        if ($appProcess.HasExited) { throw 'The AMR application exited before its main window appeared.' }
        $candidate = [IntPtr]::Zero
        try {
            $candidate = $appProcess.MainWindowHandle
            if ($candidate -eq [IntPtr]::Zero) { $candidate = [AMR.ToolProLauncherNative]::FindVisibleWindow($appProcess.Id) }
        } catch {}
        if ($candidate -ne [IntPtr]::Zero) {
            if ($candidate -ne $appHandle) { $appHandle = $candidate; $stableSince = [DateTime]::UtcNow }
            elseif ($null -ne $stableSince -and ([DateTime]::UtcNow - $stableSince).TotalSeconds -ge 1.2) { break }
        } else { $appHandle = [IntPtr]::Zero; $stableSince = $null }
        if ($null -ne $stableSince) {
            $elapsed = ([DateTime]::UtcNow - $stableSince).TotalSeconds
            $waitingPercent = [Math]::Min(98, 94 + [int][Math]::Floor($elapsed * 1.5))
            if ($waitingPercent -gt $script:ProgressValue) {
                Set-AMRLauncherProgress -Percent $waitingPercent -Status 'Almost there — polishing the handoff...' -Detail 'The application is opening. Preparing a seamless transition...'
            }
        }
        Start-Sleep -Milliseconds 70
    }
    if ($appHandle -eq [IntPtr]::Zero) { throw 'The AMR main window did not become visible within 180 seconds.' }

    $appRect = New-Object AMR.RECT
    if (-not [AMR.ToolProLauncherNative]::GetWindowRect($appHandle, [ref]$appRect)) { throw 'Could not read the AMR application window bounds for the transition.' }
    $targetX = $appRect.Left; $targetY = $appRect.Top
    $targetW = [Math]::Max(320, ($appRect.Right - $appRect.Left))
    $targetH = [Math]::Max(240, ($appRect.Bottom - $appRect.Top))

    # The last 100% is reserved for the confirmed, visible application handoff.
    Set-AMRLauncherProgress -Percent 100 -Status 'Your AMR experience is ready!' -Detail 'Enjoy the new experience. Thank you for your support.'
    Write-AMRLauncherLog ('Main window confirmed (PID {0}, HWND {1}); beginning animated handoff.' -f $appProcess.Id, $appHandle)
    Pump-AMRLauncherUI
    Start-Sleep -Milliseconds 180

    # Cinematic morph: ease-out expansion toward the real app window, then fade away.
    # The launcher stays topmost during the morph, so it never obscures the app afterward.
    $startBounds = $form.Bounds
    $steps = 34
    for ($step = 1; $step -le $steps; $step++) {
        $t = $step / [double]$steps
        $ease = 1.0 - [Math]::Pow(1.0 - $t, 3.0)
        $x = [int][Math]::Round($startBounds.X + (($targetX - $startBounds.X) * $ease))
        $y = [int][Math]::Round($startBounds.Y + (($targetY - $startBounds.Y) * $ease))
        $w = [int][Math]::Round($startBounds.Width + (($targetW - $startBounds.Width) * $ease))
        $h = [int][Math]::Round($startBounds.Height + (($targetH - $startBounds.Height) * $ease))
        $form.SetBounds($x, $y, [Math]::Max(1, $w), [Math]::Max(1, $h))
        # Fade begins late, after the window has visibly expanded into the app footprint.
        if ($t -gt 0.70) {
            $fadeT = ($t - 0.70) / 0.30
            $form.Opacity = [Math]::Max(0.0, 1.0 - ($fadeT * $fadeT))
        }
        Pump-AMRLauncherUI
        Start-Sleep -Milliseconds 12
    }

    $form.TopMost = $false
    $form.Hide()
    $form.Close()
    $form.Dispose()
    $script:LauncherForm = $null
    try {
        [void][AMR.ToolProLauncherNative]::AllowSetForegroundWindow($appProcess.Id)
        [void][AMR.ToolProLauncherNative]::ShowWindow($appHandle, 9)
        [void][AMR.ToolProLauncherNative]::SetForegroundWindow($appHandle)
    } catch { Write-AMRLauncherLog ('Final foreground activation warning: ' + $_.Exception.Message) }
    Write-AMRLauncherLog 'Launcher transition completed; only the main application remains visible.'
}
catch {
    Write-AMRLauncherLog ('LAUNCHER ERROR: ' + $_.Exception.ToString())
    try {
        if ($script:LauncherForm -and -not $script:LauncherForm.IsDisposed) {
            $script:LauncherForm.TopMost = $false
            $script:LauncherForm.Close()
            $script:LauncherForm.Dispose()
            $script:LauncherForm = $null
        }
    } catch {}
    $message = 'AMR Tool-Pro could not start.' + [Environment]::NewLine + [Environment]::NewLine + $_.Exception.Message + [Environment]::NewLine + [Environment]::NewLine + 'Launcher log: ' + $logPath
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [System.Windows.Forms.MessageBox]::Show($message, 'AMR Tool-Pro Launcher', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch { Write-Error $message }
}
finally {
    try {
        if ($script:LauncherForm -and -not $script:LauncherForm.IsDisposed) {
            $script:LauncherForm.Close(); $script:LauncherForm.Dispose(); $script:LauncherForm = $null
        }
    } catch {}
    if ($stageRoot -and (Test-Path -LiteralPath $stageRoot)) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
