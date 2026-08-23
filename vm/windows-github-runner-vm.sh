#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: shmuelie
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://github.com/actions/runner

# Windows Server 2025 self-hosted GitHub Actions runner.
# Windows cannot run in an LXC container, so this ships as a QEMU/KVM VM.
#
# This uses Microsoft's pre-built Windows Server 2025 *evaluation VHD* instead of
# an ISO install: the disk is imported and boots straight to OOBE, so there is no
# Windows Setup, no "press any key to boot from CD", and no image-index guessing.
# The unattend answer file and the runner install script are injected into the
# VHD offline with virt-customize, so first boot runs OOBE unattended and the
# runner registers itself as a Windows service.
#
# The eval image is a Generation 2 VHDX (UEFI/GPT), so the VM uses OVMF/UEFI on
# q35 with a SATA boot disk and an E1000 NIC - all driver-free for the imported
# image. The VHDX is converted to qcow2 with qemu-img first. Switch to VirtIO +
# the guest agent afterwards for better performance if desired.

source /dev/stdin <<<$(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/api/api.func")
source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/pve/vm-core.func")
load_functions

function header_info {
  clear
  cat <<"EOF"
   ______ _ _   _   _       _       ______
  / ____ (_) | | | | |     | |     |  ____|
 | |  __  _| |_| |_| |_   _| |__   | |__ _   _ _ __  _ __   ___ _ __
 | | |_ | | __| __| | | | | '_ \  |  __| | | | '_ \| '_ \ / _ \ '__|
 | |__| | | |_| |_| | |_| | |_) | | |  | |_| | | | | | | |  __/ |
  \_____|_|\__|\__|_|\__,_|_.__/  |_|   \__,_|_| |_|_| |_|\___|_|
        Windows Server 2025 Self-Hosted Runner (VHD)
EOF
}
header_info
echo -e "\n Loading..."
GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
RANDOM_UUID="$(cat /proc/sys/kernel/random/uuid)"
METHOD=""
NSAPP="Windows GitHub Runner VM"
var_os="windows"
var_version="2025"

# ==============================================================================
# RUNNER SETTINGS
# ==============================================================================
function runner_settings() {
  while true; do
    if RUNNER_URL=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox \
      "GitHub URL to register the runner against\n(e.g. https://github.com/OWNER/REPO or https://github.com/ORG)" \
      10 68 "${RUNNER_URL:-https://github.com/}" --title "GITHUB URL" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
      if [[ "$RUNNER_URL" =~ ^https://github\.com/.+ ]]; then
        echo -e "${INFO}${BOLD}${DGN}GitHub URL: ${BGN}${RUNNER_URL}${CL}"
        break
      fi
      whiptail --backtitle "Proxmox VE Helper Scripts" --title "INVALID INPUT" \
        --msgbox "URL must look like https://github.com/OWNER/REPO or https://github.com/ORG" 8 68
    else
      exit_script
    fi
  done

  while true; do
    if RUNNER_TOKEN=$(whiptail --backtitle "Proxmox VE Helper Scripts" --passwordbox \
      "Runner registration token\n(Settings -> Actions -> Runners -> New self-hosted runner)" \
      10 68 --title "REGISTRATION TOKEN" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
      if [[ -n "$RUNNER_TOKEN" ]]; then
        echo -e "${INFO}${BOLD}${DGN}Registration Token: ${BGN}********${CL}"
        break
      fi
      whiptail --backtitle "Proxmox VE Helper Scripts" --title "INVALID INPUT" \
        --msgbox "A registration token is required." 8 58
    else
      exit_script
    fi
  done

  if RUNNER_NAME=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox \
    "Runner name" 8 58 "${HN}" --title "RUNNER NAME" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    [ -z "$RUNNER_NAME" ] && RUNNER_NAME="$HN"
    echo -e "${INFO}${BOLD}${DGN}Runner Name: ${BGN}${RUNNER_NAME}${CL}"
  else
    exit_script
  fi

  if RUNNER_LABELS=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox \
    "Additional runner labels (comma-separated)" 8 68 "self-hosted,windows,x64,windows-2025" \
    --title "RUNNER LABELS" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    [ -z "$RUNNER_LABELS" ] && RUNNER_LABELS="self-hosted,windows,x64,windows-2025"
    echo -e "${INFO}${BOLD}${DGN}Runner Labels: ${BGN}${RUNNER_LABELS}${CL}"
  else
    exit_script
  fi
}

# ==============================================================================
# SETTINGS FUNCTIONS
# ==============================================================================
function default_settings() {
  VMID=$(get_valid_nextid)
  DISK_CACHE=""
  DISK_SIZE="60G"
  HN="win-runner"
  CPU_TYPE=" -cpu host"
  CORE_COUNT="4"
  RAM_SIZE="8192"
  BRG="vmbr0"
  MAC="$GEN_MAC"
  VLAN=""
  MTU=""
  START_VM="yes"
  METHOD="default"

  echo -e "${CONTAINERID}${BOLD}${DGN}Virtual Machine ID: ${BGN}${VMID}${CL}"
  echo -e "${DISKSIZE}${BOLD}${DGN}Disk Size: ${BGN}${DISK_SIZE}${CL}"
  echo -e "${HOSTNAME}${BOLD}${DGN}Hostname: ${BGN}${HN}${CL}"
  echo -e "${CPUCORE}${BOLD}${DGN}CPU Cores: ${BGN}${CORE_COUNT}${CL}"
  echo -e "${RAMSIZE}${BOLD}${DGN}RAM Size: ${BGN}${RAM_SIZE}${CL}"
  echo -e "${BRIDGE}${BOLD}${DGN}Bridge: ${BGN}${BRG}${CL}"
  echo -e "${MACADDRESS}${BOLD}${DGN}MAC Address: ${BGN}${MAC}${CL}"
  echo -e "${GATEWAY}${BOLD}${DGN}Start VM when completed: ${BGN}yes${CL}"
  runner_settings
  echo -e "${CREATING}${BOLD}${DGN}Creating a Windows GitHub Runner VM using the above settings${CL}"
}

function advanced_settings() {
  METHOD="advanced"
  [ -z "${VMID:-}" ] && VMID=$(get_valid_nextid)
  CPU_TYPE=" -cpu host"
  DISK_CACHE=""

  while true; do
    if VMID=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Virtual Machine ID" 8 58 $VMID --title "VIRTUAL MACHINE ID" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
      [ -z "$VMID" ] && VMID=$(get_valid_nextid)
      if qm status "$VMID" &>/dev/null || pct status "$VMID" &>/dev/null; then
        echo -e "${CROSS}${RD} ID $VMID is already in use${CL}"
        sleep 2
        continue
      fi
      echo -e "${CONTAINERID}${BOLD}${DGN}Virtual Machine ID: ${BGN}$VMID${CL}"
      break
    else
      exit_script
    fi
  done

  if DISK_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Disk Size in GiB (min 40)" 8 58 "60" --title "DISK SIZE" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    DISK_SIZE=$(echo "$DISK_SIZE" | tr -d ' G')
    if [[ "$DISK_SIZE" =~ ^[0-9]+$ ]] && [ "$DISK_SIZE" -ge 40 ]; then
      DISK_SIZE="${DISK_SIZE}G"
      echo -e "${DISKSIZE}${BOLD}${DGN}Disk Size: ${BGN}$DISK_SIZE${CL}"
    else
      echo -e "${DISKSIZE}${BOLD}${RD}Disk Size must be a number >= 40.${CL}"
      exit_script
    fi
  else
    exit_script
  fi

  if VM_NAME=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Hostname" 8 58 win-runner --title "HOSTNAME" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z "$VM_NAME" ]; then
      HN="win-runner"
    else
      HN=$(echo "${VM_NAME,,}" | tr -cs 'a-z0-9-' '-' | sed 's/^-//;s/-$//')
    fi
    echo -e "${HOSTNAME}${BOLD}${DGN}Hostname: ${BGN}$HN${CL}"
  else
    exit_script
  fi

  while true; do
    if CORE_COUNT=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Allocate CPU Cores" 8 58 4 --title "CORE COUNT" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
      [ -z "$CORE_COUNT" ] && CORE_COUNT="4"
      if [[ "$CORE_COUNT" =~ ^[1-9][0-9]*$ ]]; then
        echo -e "${CPUCORE}${BOLD}${DGN}CPU Cores: ${BGN}$CORE_COUNT${CL}"
        break
      fi
      whiptail --backtitle "Proxmox VE Helper Scripts" --title "INVALID INPUT" --msgbox "CPU Cores must be a positive integer." 8 58
    else
      exit_script
    fi
  done

  while true; do
    if RAM_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Allocate RAM in MiB (min 4096)" 8 58 8192 --title "RAM" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
      [ -z "$RAM_SIZE" ] && RAM_SIZE="8192"
      if [[ "$RAM_SIZE" =~ ^[1-9][0-9]*$ ]] && [ "$RAM_SIZE" -ge 4096 ]; then
        echo -e "${RAMSIZE}${BOLD}${DGN}RAM Size: ${BGN}$RAM_SIZE${CL}"
        break
      fi
      whiptail --backtitle "Proxmox VE Helper Scripts" --title "INVALID INPUT" --msgbox "RAM must be a positive integer >= 4096 (MiB)." 8 58
    else
      exit_script
    fi
  done

  if BRG=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a Bridge" 8 58 vmbr0 --title "BRIDGE" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    [ -z "$BRG" ] && BRG="vmbr0"
    echo -e "${BRIDGE}${BOLD}${DGN}Bridge: ${BGN}$BRG${CL}"
  else
    exit_script
  fi

  while true; do
    if MAC1=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a MAC Address" 8 58 $GEN_MAC --title "MAC ADDRESS" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
      if [ -z "$MAC1" ]; then
        MAC="$GEN_MAC"
        echo -e "${MACADDRESS}${BOLD}${DGN}MAC Address: ${BGN}$MAC${CL}"
        break
      fi
      if [[ "$MAC1" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
        MAC="$MAC1"
        echo -e "${MACADDRESS}${BOLD}${DGN}MAC Address: ${BGN}$MAC${CL}"
        break
      fi
      whiptail --backtitle "Proxmox VE Helper Scripts" --title "INVALID INPUT" --msgbox "Invalid MAC address format." 8 58
    else
      exit_script
    fi
  done

  if VLAN1=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a Vlan (leave blank for default)" 8 58 --title "VLAN" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [ -z "$VLAN1" ]; then VLAN=""; else VLAN=",tag=$VLAN1"; fi
    echo -e "${VLANTAG}${BOLD}${DGN}VLAN: ${BGN}${VLAN1:-Default}${CL}"
  else
    exit_script
  fi
  MTU=""

  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "START VIRTUAL MACHINE" --yesno "Start VM when completed?" 10 58); then
    START_VM="yes"
  else
    START_VM="no"
  fi
  echo -e "${GATEWAY}${BOLD}${DGN}Start VM when completed: ${BGN}${START_VM}${CL}"

  runner_settings

  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "ADVANCED SETTINGS COMPLETE" --yesno "Ready to create a Windows GitHub Runner VM?" --no-button Do-Over 10 58); then
    echo -e "${CREATING}${BOLD}${DGN}Creating a Windows GitHub Runner VM using the above advanced settings${CL}"
  else
    header_info
    echo -e "${ADVANCED}${BOLD}${RD}Using Advanced Settings${CL}"
    advanced_settings
  fi
}

function start_script() {
  if (whiptail --backtitle "Proxmox VE Helper Scripts" --title "SETTINGS" --yesno "Use Default Settings?" --no-button Advanced 10 58); then
    header_info
    echo -e "${DEFAULT}${BOLD}${BL}Using Default Settings${CL}"
    default_settings
  else
    header_info
    echo -e "${ADVANCED}${BOLD}${RD}Using Advanced Settings${CL}"
    advanced_settings
  fi
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================
header_info

check_root
arch_check
pve_check

if ! whiptail --backtitle "Proxmox VE Helper Scripts" --title "Windows GitHub Runner VM" --yesno "This will create a New Windows Server 2025 GitHub Runner VM from an evaluation VHD. Proceed?" 10 68; then
  header_info && echo -e "${CROSS}${RD}User exited script${CL}\n" && exit
fi

start_script
post_to_api_vm

# ==============================================================================
# STORAGE SELECTION (for the imported VM disk)
# ==============================================================================
msg_info "Validating Storage"
while read -r line; do
  TAG=$(echo $line | awk '{print $1}')
  TYPE=$(echo $line | awk '{printf "%-10s", $2}')
  FREE=$(echo $line | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf( "%9sB", $6)}')
  ITEM="  Type: $TYPE Free: $FREE "
  OFFSET=2
  if [[ $((${#ITEM} + $OFFSET)) -gt ${MSG_MAX_LENGTH:-} ]]; then
    MSG_MAX_LENGTH=$((${#ITEM} + $OFFSET))
  fi
  STORAGE_MENU+=("$TAG" "$ITEM" "OFF")
done < <(pvesm status -content images | awk 'NR>1')

VALID=$(pvesm status -content images | awk 'NR>1')
if [ -z "$VALID" ]; then
  msg_error "Unable to detect a valid storage location."
  exit
elif [ $((${#STORAGE_MENU[@]} / 3)) -eq 1 ]; then
  STORAGE=${STORAGE_MENU[0]}
else
  if [ -n "$SPINNER_PID" ] && ps -p $SPINNER_PID >/dev/null; then kill $SPINNER_PID >/dev/null; fi
  printf "\e[?25h"
  while [ -z "${STORAGE:+x}" ]; do
    STORAGE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Storage Pools" --radiolist \
      "Which storage pool would you like to use for ${HN}?\nTo make a selection, use the Spacebar.\n" \
      16 $(($MSG_MAX_LENGTH + 23)) 6 \
      "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3)
  done
fi
msg_ok "Using ${CL}${BL}$STORAGE${CL} ${GN}for Storage Location."
msg_ok "Virtual Machine ID is ${CL}${BL}$VMID${CL}."

# ==============================================================================
# VHD SOURCE (local path or https URL to the Server 2025 evaluation VHD)
# ==============================================================================
if VHD_SRC=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox \
  "Path or https:// URL to the Windows Server 2025 evaluation VHD.\n\nDownload it from the Microsoft Evaluation Center and either place it on this host or host it at a URL reachable from here." \
  12 78 "" --title "WINDOWS SERVER 2025 VHD" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
  [ -z "$VHD_SRC" ] && {
    msg_error "A VHD path or URL is required."
    exit 1
  }
else
  exit_script
fi

# ==============================================================================
# PREREQUISITES
# ==============================================================================
if ! command -v virt-customize &>/dev/null; then
  msg_info "Installing libguestfs-tools"
  apt-get -qq update >/dev/null
  apt-get -qq install libguestfs-tools -y >/dev/null
  msg_ok "Installed libguestfs-tools"
fi

if ! command -v qemu-img &>/dev/null; then
  msg_info "Installing qemu-utils"
  apt-get -qq update >/dev/null
  apt-get -qq install qemu-utils -y >/dev/null
  msg_ok "Installed qemu-utils"
fi

# ==============================================================================
# OBTAIN VHD
# ==============================================================================
CACHE_DIR="/var/lib/vz/template/cache"
mkdir -p "$CACHE_DIR"
if [[ "$VHD_SRC" =~ ^https?:// ]]; then
  CACHE_FILE="$CACHE_DIR/$(basename "${VHD_SRC%%\?*}")"
  if [[ ! -s "$CACHE_FILE" ]]; then
    msg_info "Downloading Windows Server 2025 VHD (this is large)"
    curl -f#SL -o "$CACHE_FILE" "$VHD_SRC"
    echo -en "\e[1A\e[0K"
    msg_ok "Downloaded ${CL}${BL}$(basename "$CACHE_FILE")${CL}"
  else
    msg_ok "Using cached VHD ${CL}${BL}$(basename "$CACHE_FILE")${CL}"
  fi
  SRC_FILE="$CACHE_FILE"
else
  if [[ ! -s "$VHD_SRC" ]]; then
    msg_error "VHD not found at: $VHD_SRC"
    exit 1
  fi
  SRC_FILE="$VHD_SRC"
  msg_ok "Using local VHD ${CL}${BL}${SRC_FILE}${CL}"
fi

# Convert the source disk to qcow2 so virt-customize and the import operate on a
# native format. qemu-img reads both VHDX (Gen2 eval image) and VHD; detect the
# input format from the extension so probing is never ambiguous.
msg_info "Converting source disk to qcow2"
case "${SRC_FILE,,}" in
*.vhdx) SRC_FMT="vhdx" ;;
*.vhd) SRC_FMT="vpc" ;;
*.qcow2) SRC_FMT="qcow2" ;;
*.raw | *.img) SRC_FMT="raw" ;;
*) SRC_FMT="" ;;
esac
WORK_FILE=$(mktemp --suffix=.qcow2)
if [[ -n "$SRC_FMT" ]]; then
  qemu-img convert -p -f "$SRC_FMT" -O qcow2 "$SRC_FILE" "$WORK_FILE"
else
  qemu-img convert -p -O qcow2 "$SRC_FILE" "$WORK_FILE"
fi
msg_ok "Converted source disk to qcow2"

# ==============================================================================
# GENERATE ANSWER FILE + RUNNER SCRIPT AND INJECT INTO THE VHD
# ==============================================================================
msg_info "Generating unattended configuration"
WINHN=$(echo "$HN" | tr -cd 'A-Za-z0-9-' | cut -c1-15)
ADMIN_PASS="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | cut -c1-14)Aa1!"
INJECT_DIR=$(mktemp -d)

cat <<'UNATTEND' >"$INJECT_DIR/unattend.xml"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>__COMPUTERNAME__</ComputerName>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
        <NetworkLocation>Work</NetworkLocation>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>__ADMINPASS__</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>Administrator</Username>
        <LogonCount>1</LogonCount>
        <Password><Value>__ADMINPASS__</Value><PlainText>true</PlainText></Password>
      </AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>1</Order>
          <Description>Install GitHub Actions runner</Description>
          <CommandLine>powershell -ExecutionPolicy Bypass -NoProfile -File C:\actions-runner-install.ps1</CommandLine>
          <RequiresUserInput>false</RequiresUserInput>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
UNATTEND

cat <<'RUNNERPS1' >"$INJECT_DIR/install-runner.ps1"
$ErrorActionPreference = 'Stop'
Start-Transcript -Path 'C:\actions-runner-install.log' -Append

# The imported disk may be larger than the VHD's virtual size; grow C: into it.
"select volume c`r`nextend" | diskpart | Out-Null

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$dir = 'C:\actions-runner'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Set-Location $dir

$rel = $null
for ($i = 0; $i -lt 30; $i++) {
  try {
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/actions/runner/releases/latest' -Headers @{ 'User-Agent' = 'proxmox-runner' }
    break
  } catch { Start-Sleep -Seconds 10 }
}
if (-not $rel) { throw 'Unable to reach GitHub to resolve the latest runner release.' }

$asset = $rel.assets | Where-Object { $_.name -match 'actions-runner-win-x64-.*\.zip' } | Select-Object -First 1
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile "$dir\runner.zip"
Expand-Archive -Path "$dir\runner.zip" -DestinationPath $dir -Force
Remove-Item "$dir\runner.zip" -Force

& "$dir\config.cmd" --unattended --url '__URL__' --token '__TOKEN__' --name '__NAME__' --labels '__LABELS__' --runasservice
Stop-Transcript
RUNNERPS1

# Literal placeholder substitution (safe for user input with & # or \)
_subst_file() {
  local file="$1"
  shift
  local content
  content="$(cat "$file")"
  while [ "$#" -ge 2 ]; do
    content="${content//"$1"/"$2"}"
    shift 2
  done
  printf '%s\n' "$content" >"$file"
}
_subst_file "$INJECT_DIR/unattend.xml" \
  "__COMPUTERNAME__" "$WINHN" \
  "__ADMINPASS__" "$ADMIN_PASS"
_subst_file "$INJECT_DIR/install-runner.ps1" \
  "__URL__" "$RUNNER_URL" \
  "__TOKEN__" "$RUNNER_TOKEN" \
  "__NAME__" "$RUNNER_NAME" \
  "__LABELS__" "$RUNNER_LABELS"
msg_ok "Generated unattended configuration"

msg_info "Injecting configuration into the disk image"
export LIBGUESTFS_BACKEND=direct
VIRT_LOG="/tmp/win-runner-virt-customize-${VMID}.log"
# Windows reads the answer file from %WINDIR%\Panther during specialize/OOBE.
# Upload to both Panther and the Sysprep dir for reliability, plus the runner
# script to the root of C:.
if ! virt-customize -a "$WORK_FILE" \
  --mkdir "/Windows/Panther" \
  --mkdir "/Windows/System32/Sysprep" \
  --upload "$INJECT_DIR/unattend.xml:/Windows/Panther/unattend.xml" \
  --upload "$INJECT_DIR/unattend.xml:/Windows/System32/Sysprep/unattend.xml" \
  --upload "$INJECT_DIR/install-runner.ps1:/actions-runner-install.ps1" >"$VIRT_LOG" 2>&1; then
  msg_error "Failed to inject configuration into the disk image (see $VIRT_LOG)."
  tail -n 20 "$VIRT_LOG"
  rm -f "$WORK_FILE"
  rm -rf "$INJECT_DIR"
  exit 1
fi
rm -rf "$INJECT_DIR"
msg_ok "Injected configuration into the disk image"

# ==============================================================================
# VM CREATION (Gen2: OVMF/UEFI, q35, SATA boot disk - all driver-free for the
# imported image; E1000 NIC has an in-box Windows driver)
# ==============================================================================
msg_info "Creating Windows VM shell"
qm create $VMID -agent enabled=1${CPU_TYPE} -cores $CORE_COUNT -memory $RAM_SIZE \
  -name $HN -tags community-script,ci -ostype win11 -bios ovmf -machine q35 -vga std -scsihw virtio-scsi-pci \
  -net0 e1000,bridge=$BRG,macaddr=$MAC$VLAN$MTU -onboot 1 >/dev/null
msg_ok "Created VM shell"

# ==============================================================================
# DISK IMPORT
# ==============================================================================
msg_info "Importing VHD into storage ($STORAGE)"
STORAGE_TYPE=$(pvesm status -storage "$STORAGE" | awk 'NR>1 {print $2}')
case $STORAGE_TYPE in
nfs | dir) DISK_IMPORT="--format qcow2" ;;
btrfs) DISK_IMPORT="--format raw" ;;
*) DISK_IMPORT="--format raw" ;;
esac

if qm disk import --help >/dev/null 2>&1; then
  IMPORT_CMD=(qm disk import)
else
  IMPORT_CMD=(qm importdisk)
fi

IMPORT_OUT="$("${IMPORT_CMD[@]}" "$VMID" "$WORK_FILE" "$STORAGE" ${DISK_IMPORT:-} 2>&1 || true)"
DISK_REF="$(printf '%s\n' "$IMPORT_OUT" | sed -n "s/.*successfully imported disk '\([^']\+\)'.*/\1/p" | tr -d "\r\"'")"
[[ -z "$DISK_REF" ]] && DISK_REF="$(pvesm list "$STORAGE" | awk -v id="$VMID" '$5 ~ ("vm-"id"-disk-") {print $1":"$5}' | sort | tail -n1)"
rm -f "$WORK_FILE"
[[ -z "$DISK_REF" ]] && {
  msg_error "Unable to determine imported disk reference."
  echo "$IMPORT_OUT"
  exit 1
}
msg_ok "Imported disk (${CL}${BL}${DISK_REF}${CL})"

# ==============================================================================
# VM CONFIGURATION
# ==============================================================================
msg_info "Attaching disk"
# The Gen2 image boots via UEFI, so add an EFI vars disk and put the imported
# disk on SATA (in-box Windows AHCI driver). pre-enrolled-keys=0 keeps Secure
# Boot from blocking a generic image.
qm set "$VMID" \
  --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=0" \
  --sata0 "${DISK_REF},${DISK_CACHE}" \
  --boot "order=sata0" >/dev/null

# Grow the imported disk to the requested size (only ever expands)
DISK_GB="${DISK_SIZE%G}"
qm disk resize "$VMID" sata0 "${DISK_GB}G" >/dev/null 2>&1 || true
msg_ok "Attached disk"

set_description

# ==============================================================================
# START
# ==============================================================================
if [ "$START_VM" == "yes" ]; then
  msg_info "Starting Windows GitHub Runner VM"
  qm start $VMID >/dev/null 2>&1
  msg_ok "Started Windows GitHub Runner VM"
fi

# ==============================================================================
# FINAL OUTPUT
# ==============================================================================
echo -e "\n${INFO}${BOLD}${GN}Windows GitHub Runner VM Configuration Summary:${CL}"
echo -e "${TAB}${DGN}VM ID: ${BGN}${VMID}${CL}"
echo -e "${TAB}${DGN}Hostname: ${BGN}${HN}${CL}"
echo -e "${TAB}${DGN}OS: ${BGN}Windows Server 2025 (Evaluation VHDX)${CL}"
echo -e "${TAB}${DGN}Runner URL: ${BGN}${RUNNER_URL}${CL}"
echo -e "${TAB}${DGN}Runner Name: ${BGN}${RUNNER_NAME}${CL}"
echo -e "${TAB}${DGN}Runner Labels: ${BGN}${RUNNER_LABELS}${CL}"
echo -e "${TAB}${DGN}Administrator Password: ${BGN}${ADMIN_PASS}${CL}"
echo -e "${TAB}${YW}Save the Administrator password now - it is not stored anywhere else.${CL}"
echo -e "${TAB}${YW}First boot runs OOBE unattended, then the runner registers automatically (log: C:\\actions-runner-install.log).${CL}"

post_update_to_api "done" "none"
msg_ok "Completed successfully!\n"
