[CmdletBinding()]
param(
    [string]$RepositoryUrl = 'https://github.com/3mr10aa/Tool-Pro.git',
    [string]$Branch = 'main'
)

$ErrorActionPreference = 'Stop'

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$GitArgs)

    # Windows PowerShell 5.1 can turn native stderr output into a terminating
    # NativeCommandError when ErrorActionPreference is Stop. Temporarily use
    # Continue while Git runs, then validate its real process exit code.
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & git @GitArgs 2>&1
        $gitExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    foreach ($line in $output) {
        Write-Host ([string]$line)
    }

    if ($gitExitCode -ne 0) {
        throw "Git command failed (exit $gitExitCode): git $($GitArgs -join ' ')"
    }
}

if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
    throw 'Git for Windows is required. Install Git, reopen PowerShell, and run this script again.'
}

$sourceRoot = $PSScriptRoot
$workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('AMR_ToolPro_Publish_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
$repoPath = Join-Path $workRoot 'Tool-Pro'

try {
    Write-Host 'Cloning GitHub repository...' -ForegroundColor Cyan
    Invoke-Git -GitArgs @('clone', $RepositoryUrl, $repoPath)

    if (-not (Test-Path -LiteralPath (Join-Path $repoPath '.git'))) {
        throw 'The cloned directory is not a Git repository.'
    }

    # Prepare the requested publication branch without allowing native Git
    # stderr messages to terminate Windows PowerShell 5.1.
    Invoke-Git -GitArgs @('-C', $repoPath, 'checkout', '-B', $Branch)

    Write-Host 'Replacing repository contents with this release...' -ForegroundColor Yellow

    # Preserve the repository-owned Icons.zip archive. All other tracked and
    # untracked project content is replaced by the files in this release folder.
    Get-ChildItem -LiteralPath $repoPath -Force |
        Where-Object { $_.Name -ne '.git' -and $_.Name -ine 'Icons.zip' } |
        Remove-Item -Recurse -Force

    Get-ChildItem -LiteralPath $sourceRoot -Force |
        Where-Object { $_.Name -ne '.git' } |
        ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $repoPath -Recurse -Force
        }

    Invoke-Git -GitArgs @('-C', $repoPath, 'add', '--all')

    # git diff --quiet uses exit code 1 to mean that staged changes exist;
    # handle that expected result explicitly instead of treating it as an error.
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $null = & git -C $repoPath diff --cached --quiet 2>&1
        $diffExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($diffExitCode -eq 0) {
        Write-Host 'The repository already matches this release. Nothing to commit.' -ForegroundColor Green
    }
    elseif ($diffExitCode -eq 1) {
        Invoke-Git -GitArgs @('-C', $repoPath, 'commit', '-m', 'Replace repository with AMR V1 Driver Center Intelligence Update')
    }
    else {
        throw "Git could not inspect staged changes (exit $diffExitCode)."
    }

    Write-Host "Pushing branch '$Branch' to GitHub..." -ForegroundColor Cyan
    Invoke-Git -GitArgs @('-C', $repoPath, 'push', '--set-upstream', 'origin', $Branch)

    Write-Host 'SUCCESS: AMR release uploaded to https://github.com/3mr10aa/Tool-Pro' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $workRoot) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
