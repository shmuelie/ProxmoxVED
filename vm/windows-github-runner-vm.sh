#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: shmuelie
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://github.com/actions/runner

# Windows Server 2025 self-hosted GitHub Actions runner.
# Windows cannot run in an LXC container, so this ships as a QEMU/KVM VM.
# The install is fully unattended (autounattend.xml). To stay driver-free during
# WinPE the OS disk is AHCI (sata) and the NIC is E1000E - both have in-box
# Windows drivers - so no VirtIO drivers are needed to complete setup. The
# VirtIO ISO is still attached so the disk/NIC can be switched to VirtIO and the
# guest agent installed afterwards for better performance.

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
        Windows Server 2025 Self-Hosted Runner
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
  # GitHub URL
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

  # Registration token
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

  # Runner name
  if RUNNER_NAME=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox \
    "Runner name" 8 58 "${HN}" --title "RUNNER NAME" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    [ -z "$RUNNER_NAME" ] && RUNNER_NAME="$HN"
    echo -e "${INFO}${BOLD}${DGN}Runner Name: ${BGN}${RUNNER_NAME}${CL}"
  else
    exit_script
  fi

  # Labels
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
  MACHINE=" -machine q35"
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
  IMAGE_INDEX="2"
  START_VM="yes"
  METHOD="default"

  echo -e "${CONTAINERID}${BOLD}${DGN}Virtual Machine ID: ${BGN}${VMID}${CL}"
  echo -e "${DISKSIZE}${BOLD}${DGN}Disk Size: ${BGN}${DISK_SIZE}${CL}"
  echo -e "${HOSTNAME}${BOLD}${DGN}Hostname: ${BGN}${HN}${CL}"
  echo -e "${CPUCORE}${BOLD}${DGN}CPU Cores: ${BGN}${CORE_COUNT}${CL}"
  echo -e "${RAMSIZE}${BOLD}${DGN}RAM Size: ${BGN}${RAM_SIZE}${CL}"
  echo -e "${BRIDGE}${BOLD}${DGN}Bridge: ${BGN}${BRG}${CL}"
  echo -e "${MACADDRESS}${BOLD}${DGN}MAC Address: ${BGN}${MAC}${CL}"
  echo -e "${INFO}${BOLD}${DGN}Windows Image Index: ${BGN}${IMAGE_INDEX} (Standard, Desktop Experience)${CL}"
  echo -e "${GATEWAY}${BOLD}${DGN}Start VM when completed: ${BGN}yes${CL}"
  runner_settings
  echo -e "${CREATING}${BOLD}${DGN}Creating a Windows GitHub Runner VM using the above settings${CL}"
}

function advanced_settings() {
  METHOD="advanced"
  [ -z "${VMID:-}" ] && VMID=$(get_valid_nextid)
  MACHINE=" -machine q35"
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

  if IMAGE_INDEX=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox \
    "WIM image index to install\n2 = Standard (Desktop Experience)\n4 = Datacenter (Desktop Experience)" \
    10 58 "2" --title "IMAGE INDEX" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    [[ "$IMAGE_INDEX" =~ ^[0-9]+$ ]] || IMAGE_INDEX="2"
    echo -e "${INFO}${BOLD}${DGN}Windows Image Index: ${BGN}$IMAGE_INDEX${CL}"
  else
    exit_script
  fi

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

if ! whiptail --backtitle "Proxmox VE Helper Scripts" --title "Windows GitHub Runner VM" --yesno "This will create a New Windows Server 2025 GitHub Runner VM. Proceed?" 10 58; then
  header_info && echo -e "${CROSS}${RD}User exited script${CL}\n" && exit
fi

start_script
post_to_api_vm

# ==============================================================================
# STORAGE SELECTION (for the VM disk)
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
# WINDOWS ISO SELECTION (must already be uploaded to an ISO-content storage)
# ==============================================================================
msg_info "Scanning for a Windows Server 2025 ISO"
WIN_ISO_MENU=()
while read -r isostore; do
  while read -r vol; do
    [ -z "$vol" ] && continue
    WIN_ISO_MENU+=("$vol" "$(basename "$vol")" "OFF")
  done < <(pvesm list "$isostore" --content iso 2>/dev/null | awk 'NR>1 {print $1}')
done < <(pvesm status -content iso | awk 'NR>1 {print $1}')

if [ ${#WIN_ISO_MENU[@]} -eq 0 ]; then
  msg_error "No ISO images found. Upload a Windows Server 2025 ISO to a storage (content: ISO) and re-run."
  exit 1
fi
msg_ok "Found $((${#WIN_ISO_MENU[@]} / 3)) ISO image(s)"

WIN_ISO_REF=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "WINDOWS ISO" --radiolist \
  "Select the Windows Server 2025 installation ISO" 20 78 10 \
  "${WIN_ISO_MENU[@]}" 3>&1 1>&2 2>&3) || exit_script
[ -z "$WIN_ISO_REF" ] && {
  msg_error "No Windows ISO selected."
  exit 1
}
ISO_STORAGE="${WIN_ISO_REF%%:*}"
ISO_DIR="$(dirname "$(pvesm path "$WIN_ISO_REF")")"
msg_ok "Using Windows ISO ${CL}${BL}${WIN_ISO_REF}${CL}"

# ==============================================================================
# PREREQUISITES (host tooling to build the unattend ISO)
# ==============================================================================
if command -v genisoimage &>/dev/null; then
  MKISO="genisoimage"
elif command -v xorriso &>/dev/null; then
  MKISO="xorriso -as mkisofs"
else
  msg_info "Installing genisoimage"
  apt-get -qq update >/dev/null
  apt-get -qq install genisoimage -y >/dev/null
  MKISO="genisoimage"
  msg_ok "Installed genisoimage"
fi

# ==============================================================================
# VIRTIO ISO (optional, attached so drivers/guest-agent can be installed later)
# ==============================================================================
VIRTIO_FILE="$ISO_DIR/virtio-win.iso"
if [[ ! -s "$VIRTIO_FILE" ]]; then
  msg_info "Downloading VirtIO drivers ISO"
  curl -f#SL -o "$VIRTIO_FILE" "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
  echo -en "\e[1A\e[0K"
  msg_ok "Downloaded VirtIO drivers ISO"
else
  msg_ok "Using cached VirtIO drivers ISO"
fi

# ==============================================================================
# BUILD UNATTEND ISO (autounattend.xml + install-runner.ps1)
# ==============================================================================
msg_info "Generating unattended install media"
WINHN=$(echo "$HN" | tr -cd 'A-Za-z0-9-' | cut -c1-15)
ADMIN_PASS="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | cut -c1-14)Aa1!"
UNATTEND_DIR=$(mktemp -d)
mkdir -p "$UNATTEND_DIR/scripts"

cat <<'AUTOUNATTEND' >"$UNATTEND_DIR/autounattend.xml"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage>
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <DiskConfiguration>
        <Disk wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>260</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
              <Key>/IMAGE/INDEX</Key>
              <Value>__IMAGEINDEX__</Value>
            </MetaData>
          </InstallFrom>
          <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
        </OSImage>
      </ImageInstall>
      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>Administrator</FullName>
        <Organization>community-scripts</Organization>
      </UserData>
    </component>
  </settings>
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
          <CommandLine>powershell -ExecutionPolicy Bypass -NoProfile -Command "$p=(Get-PSDrive -PSProvider FileSystem|%{Join-Path $_.Root 'scripts\install-runner.ps1'}|?{Test-Path $_}|Select-Object -First 1);if($p){. $p}"</CommandLine>
          <RequiresUserInput>false</RequiresUserInput>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
AUTOUNATTEND

cat <<'RUNNERPS1' >"$UNATTEND_DIR/scripts/install-runner.ps1"
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$dir = 'C:\actions-runner'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Set-Location $dir
Start-Transcript -Path 'C:\actions-runner-install.log' -Append

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

# Substitute values (use # as delimiter; values contain no #)
sed -i "s#__IMAGEINDEX__#${IMAGE_INDEX}#g; s#__COMPUTERNAME__#${WINHN}#g; s#__ADMINPASS__#${ADMIN_PASS}#g" "$UNATTEND_DIR/autounattend.xml"
sed -i "s#__URL__#${RUNNER_URL}#g; s#__TOKEN__#${RUNNER_TOKEN}#g; s#__NAME__#${RUNNER_NAME}#g; s#__LABELS__#${RUNNER_LABELS}#g" "$UNATTEND_DIR/scripts/install-runner.ps1"

UNATTEND_ISO="$ISO_DIR/${VMID}-github-runner-unattend.iso"
$MKISO -quiet -J -r -V UNATTEND -o "$UNATTEND_ISO" "$UNATTEND_DIR" >/dev/null 2>&1
rm -rf "$UNATTEND_DIR"
msg_ok "Generated unattended install media"

# ==============================================================================
# VM CREATION
# ==============================================================================
msg_info "Creating Windows VM shell"
DISK_GB="${DISK_SIZE%G}"

qm create $VMID -agent enabled=1${MACHINE}${CPU_TYPE} -cores $CORE_COUNT -memory $RAM_SIZE \
  -name $HN -tags community-script,ci -ostype win11 -bios ovmf -vga std -scsihw virtio-scsi-pci \
  -net0 e1000,bridge=$BRG,macaddr=$MAC$VLAN$MTU -onboot 1 >/dev/null
msg_ok "Created VM shell"

msg_info "Attaching disks and installation media"
qm set $VMID \
  --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=0" \
  --sata0 "${STORAGE}:${DISK_GB},${DISK_CACHE}ssd=1" \
  --ide2 "${WIN_ISO_REF},media=cdrom" \
  --ide0 "${ISO_STORAGE}:iso/$(basename "$UNATTEND_ISO"),media=cdrom" \
  --ide1 "${ISO_STORAGE}:iso/virtio-win.iso,media=cdrom" \
  --boot "order=ide2;sata0" >/dev/null
msg_ok "Attached disks and installation media"

set_description

# ==============================================================================
# START
# ==============================================================================
if [ "$START_VM" == "yes" ]; then
  msg_info "Starting Windows GitHub Runner VM"
  qm start $VMID >/dev/null 2>&1
  msg_ok "Started Windows GitHub Runner VM"

  # The Windows ISO shows "Press any key to boot from CD or DVD..." on the first
  # boot. Auto-confirm it with qm sendkey instead of asking the user to watch the
  # console. The window is deliberately short (~30s): it only needs to catch this
  # first prompt, and it finishes long before Setup reaches its first reboot - so
  # it can never re-trigger the (disk-wiping) installer. On later reboots the CD
  # prompt simply times out and the boot order (ide2;sata0) falls through to the
  # now-bootable disk, so no keypress is needed there.
  msg_info "Confirming boot from installation media"
  for _ in $(seq 1 15); do
    qm sendkey "$VMID" ret >/dev/null 2>&1 || true
    sleep 2
  done
  msg_ok "Unattended installation started"
fi

# ==============================================================================
# FINAL OUTPUT
# ==============================================================================
echo -e "\n${INFO}${BOLD}${GN}Windows GitHub Runner VM Configuration Summary:${CL}"
echo -e "${TAB}${DGN}VM ID: ${BGN}${VMID}${CL}"
echo -e "${TAB}${DGN}Hostname: ${BGN}${HN}${CL}"
echo -e "${TAB}${DGN}OS: ${BGN}Windows Server 2025${CL}"
echo -e "${TAB}${DGN}Runner URL: ${BGN}${RUNNER_URL}${CL}"
echo -e "${TAB}${DGN}Runner Name: ${BGN}${RUNNER_NAME}${CL}"
echo -e "${TAB}${DGN}Runner Labels: ${BGN}${RUNNER_LABELS}${CL}"
echo -e "${TAB}${DGN}Administrator Password: ${BGN}${ADMIN_PASS}${CL}"
echo -e "${TAB}${YW}Save the Administrator password now - it is not stored anywhere else.${CL}"
if [ "$START_VM" == "yes" ]; then
  echo -e "${TAB}${GN}Boot from installation media was auto-confirmed - setup is running unattended.${CL}"
else
  echo -e "${TAB}${YW}When you start the VM, press a key at 'Press any key to boot from CD...' (first boot only).${CL}"
fi
echo -e "${TAB}${YW}Setup runs unattended; the runner registers automatically on first logon (log: C:\\actions-runner-install.log).${CL}"

post_update_to_api "done" "none"
msg_ok "Completed successfully!\n"
