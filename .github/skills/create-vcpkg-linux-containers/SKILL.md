---
name: create-vcpkg-linux-containers
description: Create the Linux containers that vcpkg CI uses (x64-linux, arm64-linux, Android) in the vcpkg review VM with WSL containers (wslc). Use when a vcpkg maintainer asks to set up or refresh the Linux containers in that VM.
disable-model-invocation: true
---

## Goal

In the Windows Server VM that the `create-vcpkg-vm` skill creates, create one container per vcpkg CI Linux image, so ports can be built for Linux with the images CI uses:

| Container | Image in `vcpkgandroidwus.azurecr.io` | Smoke-test triplet |
|---|---|---|
| `vcpkg-x64-linux` | `vcpkg-linux` | x64-linux |
| `vcpkg-arm64-linux` | `vcpkg-arm64-linux` | arm64-linux |
| `vcpkg-android` | `vcpkg-android` | arm64-android |

The tags come from `scripts/azure-pipelines/azure-pipelines.yml` and `scripts/azure-pipelines/android/azure-pipelines.yml` in this checkout. Every container mounts the `vcpkg-linux` volume at `/vcpkg`, a bootstrapped clone of microsoft/vcpkg, so builds run on a case-sensitive Linux file system as in CI, not on the VM's NTFS checkout. Unlike CI, which runs builds as a non-root user, the containers run them as root.

## Prerequisites

- The Hyper-V host exposes virtualization extensions to the VM. `create-vcpkg-vm` turns this on for new VMs and describes how to turn it on for older ones.
- The user's account has AcrPull on the `vcpkgandroidwus` Azure Container Registry, and the host has the Azure CLI, signed in with `az login` as that account.

## Security

Untrusted PR code runs in this VM and can read anything in it. The only credential this skill uses is a registry token that the user creates on the host. It works only on `vcpkgandroidwus`, with the user's permissions there, and expires after about 3 hours. The user pastes it into the window that `Install-VcpkgLinuxImages.ps1` opens, which logs out of the registry when it finishes; logging out removes the token from the VM, but it stays valid until it expires. Never ask for the token in chat, never pass it on a command line, and never run `az login` in the VM.

## How to run

The scripts are in `scripts/` next to this file. Before each step, tell the user in one sentence what happens now. Do not ask for permission to continue, except before restarting the VM; stop only where the user must act or on a failure.

1. In an elevated terminal, run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <scripts>\Initialize-VcpkgLinuxContainers.ps1`. It skips finished steps, so run it again after each user action below.
2. Act on its exit code:
   - **3010** (`REBOOT-REQUIRED`): it enabled the WSL features. Ask the user whether to restart the VM now; if yes, run `Restart-Computer`. After signing in again, the user starts this skill again.
   - **2** (`IMAGES-MISSING`): in one message, ask the user to run this on the host, not in the VM, and to paste its output into the window that opens next:
     ```powershell
     az acr login --name vcpkgandroidwus --expose-token --query accessToken --output tsv
     ```
     Then, without waiting for a reply, open the window:
     ```powershell
     $p = Start-Process powershell.exe -Wait -PassThru -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File "<scripts>\Install-VcpkgLinuxImages.ps1"'; Get-Content "$env:TEMP\create-vcpkg-linux-containers.log"; "Exit code: $($p.ExitCode)"
     ```
     The command returns when the window closes. If the terminal call times out first, keep waiting for that command to finish; do not open the window again. When it exits with 0, go back to step 1. When it exits with 1, read the log: if the login failed, ask the user for a new token and open the window again; otherwise fix the cause (see Troubleshooting).
   - **1**: read the error, fix the cause (see Troubleshooting), and go back to step 1.
   - **0**: report the containers and give the user the next section.

## Using the containers

- After a VM restart, start a stopped container with `wslc start <container>`.
- Run commands with `wslc exec -w <directory> <container> <command>`, for example `wslc exec -w /vcpkg vcpkg-x64-linux ./vcpkg install zlib:x64-linux`. For shell syntax, wrap the command in `bash -c '<command>'`; do not use a login shell (`bash -l`), which can reset the image's `PATH`.
- `VCPKG_DOWNLOADS` is `/vcpkg/downloads` in every container, so all three share downloads.
- vcpkg commands that share a vcpkg root wait for each other's lock. To build a pull request, or to build in parallel, use a separate worktree with its own copy of the tool:
  ```powershell
  wslc exec -w /vcpkg vcpkg-x64-linux bash -c 'git fetch origin pull/<number>/head && git worktree add --detach .worktrees/pr-<number> FETCH_HEAD && cp vcpkg .worktrees/pr-<number>/'
  wslc exec -w /vcpkg/.worktrees/pr-<number> vcpkg-x64-linux ./vcpkg install <port>:x64-linux
  ```
- The clone and the vcpkg tool in the volume are not updated automatically. Update them with `wslc exec -w /vcpkg vcpkg-x64-linux bash -c 'git pull --ff-only && ./bootstrap-vcpkg.sh -disableMetrics'`.
- Containers hold no state; everything is in the volume. When `git pull` in this checkout changes a CI image tag, run this skill again: it pulls the new image and recreates the container. The old image stays on disk until you remove it with `wslc rmi <image>`.
- Do not run `scripts/azure-pipelines/test-modified-ports.ps1`: with `-BuildReason PullRequest` it reverts and hard-resets the checkout, and otherwise it builds the whole catalog.

## Troubleshooting

- `wslc` cannot start its session and the error mentions virtualization or Hyper-V: the host does not expose virtualization extensions to this VM. Point the user to the `create-vcpkg-vm` skill.
- `wslc.exe` is still missing after `wsl --install`: restart the VM and run the skill again.
- `wslc login` fails: the token expired or the account lacks AcrPull. Create a new token on the host.
- A clone or bootstrap was interrupted: remove the containers and the volume, which deletes everything in it, with `wslc remove -f vcpkg-x64-linux vcpkg-arm64-linux vcpkg-android` and `wslc volume remove vcpkg-linux`, then run the skill again.
