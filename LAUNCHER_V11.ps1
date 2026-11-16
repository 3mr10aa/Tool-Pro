<#
AMR Windows Utility - IRM In-Memory Launcher V11 (updated SHA-256)
Windows PowerShell 5.1
Downloads the exact V11 main script, checks its SHA-256, then streams it
to an elevated STA PowerShell process. The application is not written to disk.
#>
$ErrorActionPreference = 'Stop'
$mainUrl = 'https://raw.githubusercontent.com/3mr10aa/Tool-Pro/Master/AMR_WINDOWS_UTILITY_V11.ps1'

# SHA-256 confirmed from the currently published main script.
$expectedSha256 = '548C690F8B1C7642D1A13161F38B7FCD4502453F787ACAD7F6E8CAF6954AFA80'

$pipeName = 'AMR_' + [guid]::NewGuid().ToString('N')
$server = $null
$client = $null
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $client = New-Object Net.WebClient
    $client.Headers['User-Agent'] = 'AMR-Windows-Utility-IRM-Launcher/11'
    # Download raw bytes so UTF-8 text is not altered before hash validation.
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

    $utf8Strict = [System.Text.UTF8Encoding]::new($false, $true)
    try { $mainText = $utf8Strict.GetString($mainBytes) }
    catch { throw 'The downloaded application is not valid UTF-8.' }

    $server = New-Object IO.Pipes.NamedPipeServerStream(
        $pipeName,[IO.Pipes.PipeDirection]::Out,1,
       [IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::None
    )
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
    if (-not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) {
        throw 'Windows PowerShell 5.1 was not found.'
    }
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
    Start-Process @start | Out-Null
    $server.WaitForConnection()
    $server.Write($mainBytes,0,$mainBytes.Length)
    $server.Flush()
    $server.Dispose(); $server = $null
} catch {
    try { Write-Error ("AMR IRM Launcher Error: {0}" -f $_.Exception.Message) }
    catch { Write-Error $_ }
} finally {
    if ($client) { try { $client.Dispose() } catch {} }
    if ($server) { try { $server.Dispose() } catch {} }
}
