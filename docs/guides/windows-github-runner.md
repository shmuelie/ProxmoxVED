# Windows GitHub Actions Runner VM

`vm/windows-github-runner-vm.sh` creates a **Windows Server 2025** QEMU/KVM VM
from Microsoft's pre-built **evaluation VHD** and registers it as a self-hosted
GitHub Actions runner.

Windows cannot run in an LXC container, so unlike the Linux `github-runner`
container script this ships as a full VM. Using the VHD skips Windows Setup
entirely — the disk boots straight to OOBE — so there is **no install ISO, no
"press any key to boot from CD", and no image-index guessing**.

## Requirements

- A Proxmox VE host (run the script as `root` on the host).
- The **Windows Server 2025 evaluation VHDX** (or VHD), downloaded from the
  [Microsoft Evaluation Center](https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025)
  and placed in **`/var/lib/vz/template/iso/`**. The script lists every `.vhd`/
  `.vhdx` in that directory for you to pick. It is not downloaded for you (the
  eval download is gated, with no stable direct URL).
- A **runner registration token** from GitHub
  (repo/org → **Settings → Actions → Runners → New self-hosted runner**).
  Registration tokens are short-lived (~1 hour), so generate one just before running.
- Free space on the target storage for the imported disk, plus temporary space
  for a working copy of the disk image.
- Outbound internet from the VM (used on first logon to download the runner).

## What the script does

1. Prompts for VM resources (ID, cores, RAM, disk, bridge, MAC/VLAN) and runner
   settings (GitHub URL, registration token, runner name, labels).
2. Lists the `.vhd`/`.vhdx` images in `/var/lib/vz/template/iso/` and lets you
   select one.
3. Copies the disk to a qcow2 working file (`qemu-img convert`, handles VHDX/VHD)
   and injects, offline with `virt-customize`:
   - an `unattend.xml` answer file into `\Windows\Panther\` (and the Sysprep dir),
   - an `install-runner.ps1` into `C:\`.
4. Creates the VM, imports the disk as the boot disk, and (optionally) starts it.
5. First boot runs OOBE unattended, auto-logs-in as `Administrator` once, and the
   first-logon command installs and registers the runner as a Windows service.

### Why Gen2 / OVMF / SATA

The Microsoft evaluation VHDX is a **Generation 2** image (UEFI/GPT), so the VM
is created with **OVMF/UEFI** on **q35**, an **EFI vars disk**, a **SATA** boot
disk, and an **E1000** NIC. The SATA disk and E1000 NIC have in-box Windows
drivers, so the imported image boots and gets on the network with no driver
injection. The VHDX is converted to qcow2 with `qemu-img` before injection and
import. For better performance, install the VirtIO drivers and the QEMU guest
agent inside the VM afterwards and switch the disk/NIC to VirtIO.

## Running it

```bash
bash vm/windows-github-runner-vm.sh
```

Choose **Default** for sensible defaults (4 cores, 8 GiB RAM, 64 GiB disk) or
**Advanced** to customise everything.

The generated **Administrator password** is printed once at the end — save it
immediately, it is not stored anywhere else.

## Saving user defaults (`.vars`)

Reusable settings can be persisted so you don't re-enter them each time, following
the community-scripts defaults pattern. Two files are consulted, the app file
overriding the shared global one:

- **global** `/usr/local/community-scripts/default.vars` — shared by all
  community-scripts (also searched at `~/.config/community-scripts/default.vars`
  and `./default.vars`). Only the keys this script understands are read; anything
  else (e.g. container-only keys) is ignored.
- **app** `/usr/local/community-scripts/defaults/windows-github-runner-vm.vars` —
  specific to this script.

Behaviour:

- After you complete **Advanced** settings, the script offers to save them to the
  **app** file. If it already exists and differs, you get an Update / Keep / View
  Diff / Cancel menu.
- On the next run those values seed the prompts (both Default and Advanced).
- Precedence is **environment `var_*` > app `.vars` > global `default.vars` >
  built-in defaults**, so you can export a value (e.g. `var_cpu=8`) for a one-off
  override, keep host-wide settings like `var_brg` in the global file, and
  per-runner settings in the app file.
- Saved (app) keys: `var_cpu`, `var_ram`, `var_disk`, `var_hostname`, `var_brg`,
  `var_vlan`, `var_runner_url`, `var_runner_labels`. The **registration token is a
  secret and single-use, so it is never saved** — you are always prompted for it.

You can also create or edit either `.vars` file by hand (one `var_key=value` per
line, `#` for comments).

## After it runs

- The VM boots to OOBE, applies the answer file, and auto-logs-in once.
- `install-runner.ps1` extends `C:` to fill the disk, installs **Git for Windows**
  and the **GitHub CLI** (mirroring the Linux runner's `git`/`gh` deps, needed by
  `actions/checkout` and most workflows), downloads the latest `actions/runner`,
  runs `config.cmd --unattended --replace --runasservice`, and the runner comes up
  as a Windows service — it should appear **Online** under the repo/org runners.
- Progress/troubleshooting log inside the VM: `C:\actions-runner-install.log`.

## Evaluation edition

The prebuilt VHD is **Windows Server 2025 Evaluation** (180 days). If you need a
licensed/retail edition or your own media, an ISO-based install would be required
instead; this script is intentionally VHD-only for speed and determinism.

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
| "Failed to inject configuration" | The selected file isn't a valid Windows disk image, or `libguestfs-tools` couldn't mount it. Check the referenced `/tmp/win-runner-virt-customize-<vmid>.log`. |
| VM won't boot / INACCESSIBLE_BOOT_DEVICE | The Gen2 image needs UEFI + AHCI — confirm the VM is OVMF with the disk on `sata0` (the script sets this). |
| OOBE asks for input instead of running unattended | The answer file wasn't picked up; confirm the VHD is a generalized (sysprep/OOBE) image and re-run. |
| Runner never appears online | Open `C:\actions-runner-install.log`; confirm the VM has network (E1000/DHCP) and the token was still valid. |
