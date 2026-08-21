# Windows GitHub Actions Runner VM

`vm/windows-github-runner-vm.sh` creates a **Windows Server 2025** QEMU/KVM VM that
installs unattended and registers itself as a self-hosted GitHub Actions runner.

Windows cannot run in an LXC container, so unlike the Linux `github-runner`
container script this ships as a full VM.

## Requirements

- A Proxmox VE host (run the script as `root` on the host).
- A **Windows Server 2025 ISO** already uploaded to a storage with **ISO** content
  enabled. The script lists the ISOs it finds for you to pick — it does not
  download Windows (there is no stable public direct URL).
- A **runner registration token** from GitHub
  (repo/org → **Settings → Actions → Runners → New self-hosted runner**).
  Registration tokens are short-lived (~1 hour), so generate one just before running.
- Free space on the ISO storage for `virtio-win.iso` (~700 MB, downloaded
  automatically) plus a small generated unattend ISO.
- Outbound internet from the VM (used on first logon to download the runner).

## What the script does

1. Prompts for VM resources (ID, cores, RAM, disk, bridge, MAC/VLAN) and runner
   settings (GitHub URL, registration token, runner name, labels).
2. Lets you select the Windows Server 2025 ISO from your ISO storages.
3. Downloads the VirtIO drivers ISO (cached between runs).
4. Generates an `autounattend.xml` plus a first-logon `install-runner.ps1`, packed
   into a small unattend ISO.
5. Creates the VM (UEFI/OVMF, q35) and attaches the disk and installation media.
6. Starts the VM and auto-confirms the first-boot CD prompt.

### Driver-free install by design

To keep the unattended install from needing VirtIO drivers during Windows Setup,
the OS disk is **AHCI (`sata0`)** and the NIC is **E1000**, both of which have
in-box Windows drivers. The VirtIO ISO is still attached so you can switch the
disk/NIC to VirtIO and install the QEMU guest agent afterwards for better
performance.

### First-boot "Press any key to boot from CD"

The Windows ISO shows `Press any key to boot from CD or DVD...` on the first boot.
When the script starts the VM it auto-confirms this with `qm sendkey` for a short
(~30 s) window. That window ends well before Windows Setup reaches its first
reboot, so it only ever triggers this initial prompt — later reboots let the
prompt time out and fall through the boot order (`ide2;sata0`) to the now-bootable
disk with no keypress.

If you answer "no" to *Start VM when completed*, press a key at that prompt
yourself on the first boot only.

## Running it

```bash
bash vm/windows-github-runner-vm.sh
```

Choose **Default** for sensible defaults (4 cores, 8 GiB RAM, 60 GiB disk) or
**Advanced** to customise everything, including the WIM image index.

The generated **Administrator password** is printed once at the end — save it
immediately, it is not stored anywhere else.

## After it runs

- Windows installs unattended, then auto-logs-in as `Administrator` once.
- `install-runner.ps1` downloads the latest `actions/runner`, runs
  `config.cmd --unattended --runasservice`, and the runner comes up as a Windows
  service — it should appear **Online** under the repo/org runners.
- Progress/troubleshooting log inside the VM: `C:\actions-runner-install.log`.

## Image index

The install defaults to WIM image index **2** (Standard, Desktop Experience),
which is correct for a multi-edition retail ISO. An **evaluation** ISO may number
its editions differently — if Setup can't find the image, re-run with **Advanced**
and set the correct index.

## Updating the runner

VM scripts have no in-place `update_script`. To update the runner binary, open a
shell in the VM and let the service self-update, or re-register:

```powershell
Stop-Service actions.runner.*
C:\actions-runner\config.cmd remove --token <NEW_REGISTRATION_TOKEN>
# then re-run config.cmd with a fresh token, or re-create the VM
```

## Troubleshooting

| Symptom | Check |
| ------- | ----- |
| No ISOs listed | Upload a Windows Server 2025 ISO to a storage with **ISO** content enabled. |
| Setup can't find the Windows image | Wrong WIM index — re-run Advanced and change it. |
| Runner never appears online | Open `C:\actions-runner-install.log`; confirm the VM has network (E1000/DHCP) and the token was still valid. |
| First boot stuck at the CD prompt | On a slow host the ~30 s key window can miss — press a key on the console, or widen the `qm sendkey` loop in the script. |
