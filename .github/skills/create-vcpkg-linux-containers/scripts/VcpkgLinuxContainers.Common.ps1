# Shared helpers for the create-vcpkg-linux-containers scripts. Dot-source; do not run directly.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$VcpkgLinuxRegistry = 'vcpkgandroidwus.azurecr.io'
$Wslc = Join-Path $env:ProgramFiles 'WSL\wslc.exe'

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }

function Assert-Elevated {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script elevated (Run as administrator).'
    }
}

function Find-VcpkgLinuxImage([string]$Yaml, [string]$Repository) {
    $pattern = [regex]::Escape("$VcpkgLinuxRegistry/${Repository}:") + '[A-Za-z0-9._-]+'
    $refs = @([regex]::Matches($Yaml, $pattern) | ForEach-Object { $_.Value } | Select-Object -Unique)
    if ($refs.Count -ne 1) {
        throw "Expected one $VcpkgLinuxRegistry/$Repository image in the pipeline YAML, found $($refs.Count)."
    }
    $refs[0]
}

function Get-VcpkgLinuxContainerSpec([string]$VcpkgRoot) {
    # The tags come from the checkout's CI pipelines, so a git pull keeps them in sync with CI.
    $pipelines = Join-Path $VcpkgRoot 'scripts\azure-pipelines'
    $linux = Get-Content -LiteralPath (Join-Path $pipelines 'azure-pipelines.yml') -Raw
    $android = Get-Content -LiteralPath (Join-Path $pipelines 'android\azure-pipelines.yml') -Raw
    [pscustomobject]@{ Name = 'vcpkg-x64-linux'; Triplet = 'x64-linux'; Image = Find-VcpkgLinuxImage $linux 'vcpkg-linux' }
    [pscustomobject]@{ Name = 'vcpkg-arm64-linux'; Triplet = 'arm64-linux'; Image = Find-VcpkgLinuxImage $linux 'vcpkg-arm64-linux' }
    [pscustomobject]@{ Name = 'vcpkg-android'; Triplet = 'arm64-android'; Image = Find-VcpkgLinuxImage $android 'vcpkg-android' }
}

function Invoke-WslcQuiet {
    # Windows PowerShell turns redirected native stderr into terminating errors under 'Stop'.
    $ErrorActionPreference = 'Continue'
    & $Wslc @args *> $null
    $LASTEXITCODE
}

function Invoke-WslcChecked {
    & $Wslc @args
    if ($LASTEXITCODE -ne 0) { throw "wslc $($args -join ' ') failed with exit code $LASTEXITCODE." }
}

function Test-WslcObject([ValidateSet('image', 'volume', 'container')][string]$Kind, [string]$Name) {
    (Invoke-WslcQuiet $Kind inspect $Name) -eq 0
}

function Get-WslcContainer([string]$Name) {
    $ErrorActionPreference = 'Continue'
    $json = & $Wslc container inspect -f json $Name 2> $null
    if ($LASTEXITCODE -ne 0) { return $null }
    # Windows PowerShell emits the parsed JSON array as one object; flatten it.
    ($json -join "`n") | ConvertFrom-Json | ForEach-Object { $_ } | Select-Object -First 1
}
