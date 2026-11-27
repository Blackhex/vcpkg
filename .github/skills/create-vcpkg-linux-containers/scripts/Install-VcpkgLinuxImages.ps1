<#
.SYNOPSIS
Pulls the missing vcpkg CI Linux images with a short-lived registry token. Run it in its own window.

.DESCRIPTION
Asks for a token for the vcpkgandroidwus registry, which the user creates on
the Hyper-V host, never in this VM:

    az acr login --name vcpkgandroidwus --expose-token --query accessToken --output tsv

The token works only on that registry, with the user's permissions there,
and expires after about 3 hours. The script logs in to the registry with it,
pulls the images that Initialize-VcpkgLinuxContainers.ps1 reported missing,
and always logs out, which removes the token from this VM; it stays valid
until it expires. The token is never shown, recorded in the transcript or
passed on a command line. The transcript is
%TEMP%\create-vcpkg-linux-containers.log. On a failure the window stays open
until the user presses Enter.

Exits with 0 when all images are present, and with 1 on an error.

.PARAMETER VcpkgRoot
vcpkg checkout whose pipeline YAML has the image tags. Defaults to the
checkout that contains this script.
#>
param([string]$VcpkgRoot = (Resolve-Path -LiteralPath "$PSScriptRoot\..\..\..\..").Path)

. "$PSScriptRoot\VcpkgLinuxContainers.Common.ps1"
Start-Transcript -LiteralPath (Join-Path $env:TEMP 'create-vcpkg-linux-containers.log') -Force | Out-Null
try {
    $missing = @(Get-VcpkgLinuxContainerSpec $VcpkgRoot | Where-Object { -not (Test-WslcObject image $_.Image) })
    if ($missing) {
        Write-Host 'Missing images:'
        $missing | ForEach-Object { Write-Host "  $($_.Image)" }
        Write-Host ''
        Write-Host 'On the Hyper-V host, not in this VM, run this and copy its output:'
        Write-Host '  az acr login --name vcpkgandroidwus --expose-token --query accessToken --output tsv'
        $token = [Net.NetworkCredential]::new('', (Read-Host 'Paste the token and press Enter' -AsSecureString)).Password
        if (-not $token) { throw 'No token was entered.' }
        try {
            $login = New-Object Diagnostics.ProcessStartInfo $Wslc
            $login.Arguments = "login $VcpkgLinuxRegistry --username 00000000-0000-0000-0000-000000000000 --password-stdin"
            $login.UseShellExecute = $false
            $login.RedirectStandardInput = $true
            $process = [Diagnostics.Process]::Start($login)
            # No trailing newline: it would become part of the password.
            $process.StandardInput.Write($token)
            $process.StandardInput.Close()
            $process.WaitForExit()
            if ($process.ExitCode -ne 0) {
                throw 'wslc login failed. The token may have expired, or your account may lack AcrPull on vcpkgandroidwus.'
            }
            foreach ($spec in $missing) {
                Write-Host "Pulling $($spec.Image)"
                Invoke-WslcChecked pull $spec.Image
            }
        } finally {
            $token = $null
            Invoke-WslcQuiet logout $VcpkgLinuxRegistry | Out-Null
        }
    }
    Write-Host 'All images are present.'
} catch {
    Write-Host ($_ | Out-String) -ForegroundColor Red
    Read-Host 'Press Enter to close this window' | Out-Null
    throw
} finally {
    Stop-Transcript | Out-Null
}
