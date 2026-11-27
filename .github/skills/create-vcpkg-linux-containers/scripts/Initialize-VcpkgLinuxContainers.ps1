<#
.SYNOPSIS
Creates the Linux containers that vcpkg CI uses in this VM, with WSL containers (wslc).

.DESCRIPTION
Run it elevated in the vcpkg review VM. It skips finished steps, so run it
again after each action it asks for.

1. Enables the WSL and Virtual Machine Platform features, then prints
   REBOOT-REQUIRED and exits with 3010: restart the VM and run it again.
2. Installs WSL, which includes wslc, if wslc.exe is missing.
3. Checks that wslc can start its session. That needs the Hyper-V host to
   expose virtualization extensions to this VM.
4. Reads the CI image tags from this checkout's pipeline YAML. If an image is
   missing, prints IMAGES-MISSING with the images and exits with 2: run
   Install-VcpkgLinuxImages.ps1, then run this script again.
5. Creates the vcpkg-linux volume with a bootstrapped clone of microsoft/vcpkg
   at /vcpkg.
6. Creates the containers vcpkg-x64-linux, vcpkg-arm64-linux and
   vcpkg-android, which mount the volume at /vcpkg and share
   VCPKG_DOWNLOADS=/vcpkg/downloads. A container whose image differs from the
   checkout's tag is recreated; all state is in the volume.
7. Builds zlib in each container with temporary roots and no binary cache.

Exits with 0 when the containers are ready, and with 1 on an error.

.PARAMETER VcpkgRoot
vcpkg checkout whose pipeline YAML has the image tags. Defaults to the
checkout that contains this script.
#>
param([string]$VcpkgRoot = (Resolve-Path -LiteralPath "$PSScriptRoot\..\..\..\..").Path)

. "$PSScriptRoot\VcpkgLinuxContainers.Common.ps1"
Assert-Elevated

Write-Step 'Checking the WSL and Virtual Machine Platform features'
$features = 'Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform'
$disabled = @($features | Where-Object { "$((Get-WindowsOptionalFeature -Online -FeatureName $_).State)" -notin 'Enabled', 'EnablePending' })
if ($disabled) {
    Enable-WindowsOptionalFeature -Online -FeatureName $disabled -All -NoRestart | Out-Null
}
if (@($features | Where-Object { "$((Get-WindowsOptionalFeature -Online -FeatureName $_).State)" -ne 'Enabled' }).Count) {
    'REBOOT-REQUIRED'
    exit 3010
}

Write-Step 'Checking WSL containers (wslc)'
if (-not (Test-Path -LiteralPath $Wslc)) {
    $env:WSL_UTF8 = '1'
    & wsl.exe --install --no-distribution --web-download
    if (-not (Test-Path -LiteralPath $Wslc)) {
        throw "$Wslc is still missing after 'wsl --install' (exit code $LASTEXITCODE). Restart the VM and run this script again."
    }
}
& $Wslc list --all
if ($LASTEXITCODE -ne 0) {
    throw "wslc cannot start its session (exit code $LASTEXITCODE). If the error above mentions virtualization or Hyper-V, the Hyper-V host must expose virtualization extensions to this VM; see the create-vcpkg-vm skill."
}

Write-Step 'Reading the CI image tags'
$specs = @(Get-VcpkgLinuxContainerSpec $VcpkgRoot)
$missing = @($specs | Where-Object { -not (Test-WslcObject image $_.Image) })
if ($missing) {
    'IMAGES-MISSING'
    $missing | ForEach-Object { "  $($_.Image)" }
    exit 2
}

$volumeName = 'vcpkg-linux'
$volume = "${volumeName}:/vcpkg"
$toolImage = $specs[0].Image
Write-Step "Preparing the $volumeName volume"
if (-not (Test-WslcObject volume $volumeName)) {
    Invoke-WslcChecked volume create $volumeName
}
if ((Invoke-WslcQuiet run --rm -v $volume $toolImage test -d /vcpkg/.git) -ne 0) {
    Write-Step 'Cloning microsoft/vcpkg into the volume'
    Invoke-WslcChecked run --rm -v $volume $toolImage git clone https://github.com/microsoft/vcpkg.git /vcpkg
}
if ((Invoke-WslcQuiet run --rm -v $volume $toolImage test -x /vcpkg/vcpkg) -ne 0) {
    Write-Step 'Bootstrapping vcpkg in the volume'
    Invoke-WslcChecked run --rm -v $volume -w /vcpkg $toolImage ./bootstrap-vcpkg.sh -disableMetrics
}
Invoke-WslcChecked run --rm -v $volume $toolImage mkdir -p /vcpkg/downloads

foreach ($spec in $specs) {
    $container = Get-WslcContainer $spec.Name
    if ($container -and $container.Config.Image -ne $spec.Image) {
        Write-Step "Removing $($spec.Name), which uses $($container.Config.Image)"
        Invoke-WslcChecked remove -f $spec.Name
        $container = $null
    }
    if (-not $container) {
        Write-Step "Creating $($spec.Name) from $($spec.Image)"
        Invoke-WslcChecked run -d --name $spec.Name -v $volume -w /vcpkg -e VCPKG_DOWNLOADS=/vcpkg/downloads $spec.Image sleep infinity
    } elseif (-not $container.State.Running) {
        Write-Step "Starting $($spec.Name)"
        Invoke-WslcChecked start $spec.Name
    }
}

foreach ($spec in $specs) {
    Write-Step "Smoke test: building zlib:$($spec.Triplet) in $($spec.Name)"
    & $Wslc exec -w /vcpkg $spec.Name ./vcpkg install "zlib:$($spec.Triplet)" --x-buildtrees-root=/tmp/vcpkg-smoke/buildtrees --x-install-root=/tmp/vcpkg-smoke/installed --x-packages-root=/tmp/vcpkg-smoke/packages --binarysource=clear
    $code = $LASTEXITCODE
    Invoke-WslcQuiet exec $spec.Name rm -rf /tmp/vcpkg-smoke | Out-Null
    if ($code -ne 0) { throw "The smoke test in $($spec.Name) failed with exit code $code." }
}

Write-Step 'The Linux containers are ready'
$specs | Format-Table Name, Triplet, Image -AutoSize | Out-Host
exit 0
