#!/usr/bin/env bash
# Community-style Proxmox VE installer for Nanja-at-web/TwitchDropsMiner
#
# One-click:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Nanja-at-web/TwitchDropsMiner/main/proxmox-tdm-community.sh)"
#
# This script creates a Debian 12 unprivileged LXC with Docker,
# clones Nanja-at-web/TwitchDropsMiner, and runs docker compose.

set -Eeuo pipefail

APP_NAME="Nanja-at-web/TwitchDropsMiner"
APP_SLUG="twitchdropsminer"
REPO_URL="https://github.com/Nanja-at-web/TwitchDropsMiner.git"
REPO_REF="main"
APP_DIR="/opt/tdm"
COMPOSE_FILE="docker-compose.yml"
USER_DEFAULTS_FILE="/usr/local/community-scripts/default.vars"
APP_DEFAULTS_FILE="/usr/local/community-scripts/defaults/${APP_SLUG}.vars"
LOG_FILE="/tmp/${APP_SLUG}-installer.log"

# Built-in defaults
CTID="123"
HOSTNAME="TwitchDropsMiner"
CORES="1"
MEMORY="1024"
SWAP="512"
DISK="8"
BRIDGE="vmbr0"
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"
UNPRIVILEGED="1"
ONBOOT="1"
USE_DHCP="1"
IPV4_CIDR="192.168.1.50/24"
GATEWAY4="192.168.1.1"
TZ="Europe/Berlin"
PASSWORD=""
START_AFTER_INSTALL="1"

if [[ $EUID -ne 0 ]]; then
  echo "Please run this script as root on the Proxmox host."
  exit 1
fi
command -v pct >/dev/null 2>&1 || { echo "pct not found. Run on a Proxmox host."; exit 1; }
command -v pveam >/dev/null 2>&1 || { echo "pveam not found. Run on a Proxmox host."; exit 1; }

RED='\033[1;31m'
GRN='\033[1;32m'
YLW='\033[1;33m'
BLU='\033[1;34m'
CYN='\033[1;36m'
RST='\033[0m'

msg()  { printf "${CYN}➜${RST} %s\n" "$*"; }
ok()   { printf "${GRN}✓${RST} %s\n" "$*"; }
warn() { printf "${YLW}•${RST} %s\n" "$*"; }
err()  { printf "${RED}✗${RST} %s\n" "$*" >&2; }

cleanup_on_error() {
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    err "Installer failed. Review log: ${LOG_FILE}"
  fi
}
trap cleanup_on_error EXIT

has_whiptail() { command -v whiptail >/dev/null 2>&1; }

pause_box() {
  local text="$1"
  if has_whiptail; then
    whiptail --title "$APP_NAME" --msgbox "$text" 16 78
  else
    echo
    echo "$text"
    echo
  fi
}

input_box() {
  local title="$1" prompt="$2" default="$3"
  if has_whiptail; then
    whiptail --title "$title" --inputbox "$prompt" 10 78 "$default" 3>&1 1>&2 2>&3
  else
    read -r -p "$prompt [$default]: " value
    echo "${value:-$default}"
  fi
}

yesno_box() {
  local title="$1" prompt="$2"
  if has_whiptail; then
    whiptail --title "$title" --yesno "$prompt" 10 78
  else
    read -r -p "$prompt [y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]]
  fi
}

menu_box() {
  if has_whiptail; then
    whiptail --title "$APP_NAME" --menu "Choose installation mode" 18 78 8 \
      "default" "Built-in defaults" \
      "advanced" "Customize CTID, hostname, network, RAM, disk, bridge and storage" \
      "user_defaults" "Load global defaults from ${USER_DEFAULTS_FILE}" \
      "app_defaults" "Load app defaults from ${APP_DEFAULTS_FILE}" \
      3>&1 1>&2 2>&3
  else
    echo "1) default"
    echo "2) advanced"
    echo "3) user_defaults"
    echo "4) app_defaults"
    read -r -p "Mode [1-4]: " choice
    case "$choice" in
      1) echo "default" ;;
      2) echo "advanced" ;;
      3) echo "user_defaults" ;;
      4) echo "app_defaults" ;;
      *) echo "default" ;;
    esac
  fi
}

save_app_defaults() {
  mkdir -p "$(dirname "$APP_DEFAULTS_FILE")"
  cat > "$APP_DEFAULTS_FILE" <<EOF_DEFAULTS
CTID="$CTID"
HOSTNAME="$HOSTNAME"
CORES="$CORES"
MEMORY="$MEMORY"
SWAP="$SWAP"
DISK="$DISK"
BRIDGE="$BRIDGE"
STORAGE="$STORAGE"
TEMPLATE_STORAGE="$TEMPLATE_STORAGE"
UNPRIVILEGED="$UNPRIVILEGED"
ONBOOT="$ONBOOT"
USE_DHCP="$USE_DHCP"
IPV4_CIDR="$IPV4_CIDR"
GATEWAY4="$GATEWAY4"
TZ="$TZ"
EOF_DEFAULTS
  ok "Saved app defaults to ${APP_DEFAULTS_FILE}"
}

load_defaults_file() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  # shellcheck disable=SC1090
  source "$file"

  [[ -n "${var_cpu:-}" ]] && CORES="$var_cpu"
  [[ -n "${var_ram:-}" ]] && MEMORY="$var_ram"
  [[ -n "${var_swap:-}" ]] && SWAP="$var_swap"
  [[ -n "${var_disk:-}" ]] && DISK="$var_disk"
  [[ -n "${var_brg:-}" ]] && BRIDGE="$var_brg"
  [[ -n "${var_container_storage:-}" ]] && STORAGE="$var_container_storage"
  [[ -n "${var_template_storage:-}" ]] && TEMPLATE_STORAGE="$var_template_storage"
  [[ -n "${var_unprivileged:-}" ]] && UNPRIVILEGED="$var_unprivileged"
  [[ -n "${var_hostname:-}" ]] && HOSTNAME="$var_hostname"
  [[ -n "${var_dhcp:-}" ]] && USE_DHCP="$var_dhcp"
  [[ -n "${var_ip:-}" ]] && IPV4_CIDR="$var_ip"
  [[ -n "${var_gateway:-}" ]] && GATEWAY4="$var_gateway"

  [[ -n "${CTID:-}" ]] && :
  return 0
}

advanced_prompts() {
  CTID="$(input_box "$APP_NAME" "Container ID" "$CTID")"
  HOSTNAME="$(input_box "$APP_NAME" "Container hostname" "$HOSTNAME")"
  CORES="$(input_box "$APP_NAME" "vCPU count" "$CORES")"
  MEMORY="$(input_box "$APP_NAME" "RAM in MB" "$MEMORY")"
  SWAP="$(input_box "$APP_NAME" "Swap in MB" "$SWAP")"
  DISK="$(input_box "$APP_NAME" "Disk size in GB" "$DISK")"
  BRIDGE="$(input_box "$APP_NAME" "Network bridge" "$BRIDGE")"
  STORAGE="$(input_box "$APP_NAME" "Container storage" "$STORAGE")"
  TEMPLATE_STORAGE="$(input_box "$APP_NAME" "Template storage" "$TEMPLATE_STORAGE")"

  if yesno_box "$APP_NAME" "Use DHCP?"; then
    USE_DHCP="1"
  else
    USE_DHCP="0"
    IPV4_CIDR="$(input_box "$APP_NAME" "Static IPv4 CIDR" "$IPV4_CIDR")"
    GATEWAY4="$(input_box "$APP_NAME" "Gateway IPv4" "$GATEWAY4")"
  fi

  if yesno_box "$APP_NAME" "Save these values as app defaults for later runs?"; then
    save_app_defaults
  fi
}

show_summary_and_confirm() {
  local net_line
  if [[ "$USE_DHCP" == "1" ]]; then
    net_line="DHCP via ${BRIDGE}"
  else
    net_line="${IPV4_CIDR} via ${BRIDGE} gw ${GATEWAY4}"
  fi

  local text="Install ${APP_NAME} with these values?\n\nCTID: ${CTID}\nHostname: ${HOSTNAME}\nCPU: ${CORES}\nRAM: ${MEMORY} MB\nSwap: ${SWAP} MB\nDisk: ${DISK} GB\nStorage: ${STORAGE}\nTemplate Storage: ${TEMPLATE_STORAGE}\nNetwork: ${net_line}\nUnprivileged: ${UNPRIVILEGED}\nOnboot: ${ONBOOT}\nRepo: ${REPO_URL}\nRef: ${REPO_REF}"

  if has_whiptail; then
    whiptail --title "$APP_NAME" --yesno "$text" 20 82
  else
    echo "$text"
    read -r -p "Continue? [y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]]
  fi
}

run_ct() {
  pct exec "$CTID" -- bash -lc "$1"
}

install_container() {
  : > "$LOG_FILE"
  msg "Checking Debian 12 template"
  pveam update >>"$LOG_FILE" 2>&1
  local template_path template_file full_template net0 ip_addr
  template_path="$(pveam available --section system | awk '/debian-12-standard/ {print $2}' | sort | tail -n1)"
  [[ -n "$template_path" ]] || { err "No Debian 12 template found"; exit 1; }
  template_file="$(basename "$template_path")"

  if ! pveam list "$TEMPLATE_STORAGE" | awk '{print $2}' | grep -qx "$template_file"; then
    msg "Downloading Debian 12 template"
    pveam download "$TEMPLATE_STORAGE" "$template_path" >>"$LOG_FILE" 2>&1
  else
    ok "Template already present"
  fi

  full_template="${TEMPLATE_STORAGE}:vztmpl/${template_file}"

  if pct status "$CTID" >/dev/null 2>&1; then
    err "CTID ${CTID} already exists"
    exit 1
  fi

  if [[ "$USE_DHCP" == "1" ]]; then
    net0="name=eth0,bridge=${BRIDGE},ip=dhcp"
  else
    net0="name=eth0,bridge=${BRIDGE},ip=${IPV4_CIDR},gw=${GATEWAY4}"
  fi

  msg "Creating LXC ${CTID} (${HOSTNAME})"
  pct create "$CTID" "$full_template" \
    --hostname "$HOSTNAME" \
    --ostype debian \
    --unprivileged "$UNPRIVILEGED" \
    --features nesting=1,keyctl=1 \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --swap "$SWAP" \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "$net0" \
    --onboot "$ONBOOT" \
    --start 1 >>"$LOG_FILE" 2>&1
  ok "Container created"

  if [[ -n "$PASSWORD" ]]; then
    pct set "$CTID" --password "$PASSWORD" >>"$LOG_FILE" 2>&1
  fi

  msg "Waiting for container boot"
  sleep 8

  msg "Installing base packages, locale and Docker"
  run_ct '
    set -Eeuo pipefail
    export DEBIAN_FRONTEND=noninteractive
    export APT_LISTCHANGES_FRONTEND=none
    export LANG=C.UTF-8
    export LC_ALL=C.UTF-8
    apt-get -qq update
    apt-get -qq install -y ca-certificates curl git gnupg lsb-release locales >/dev/null 2>&1
    sed -i "s/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/" /etc/locale.gen
    locale-gen en_US.UTF-8 >/dev/null 2>&1
    update-locale LANG=en_US.UTF-8 >/dev/null 2>&1 || true
    printf "LANG=en_US.UTF-8\n" >/etc/default/locale
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    ARCH=$(dpkg --print-architecture)
    cat >/etc/apt/sources.list.d/docker.sources <<EOF_DOCKER
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: bookworm
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF_DOCKER
    apt-get -qq update
    apt-get -qq install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1
    systemctl enable docker >/dev/null 2>&1
    systemctl start docker
  ' >>"$LOG_FILE" 2>&1
  ok "Docker installed"

  msg "Cloning ${APP_NAME}"
  run_ct "rm -rf '${APP_DIR}' && git clone --quiet '${REPO_URL}' '${APP_DIR}' && cd '${APP_DIR}' && git fetch --quiet --all --tags && git checkout '${REPO_REF}' >/dev/null 2>&1" >>"$LOG_FILE" 2>&1
  ok "Repository cloned"

  msg "Preparing persistent directories"
  run_ct "test -f '${APP_DIR}/${COMPOSE_FILE}' && mkdir -p '${APP_DIR}/data' '${APP_DIR}/logs'" >>"$LOG_FILE" 2>&1
  ok "Directories ready"

  if [[ "$START_AFTER_INSTALL" == "1" ]]; then
    msg "Building and starting Docker stack"
    run_ct "cd '${APP_DIR}' && docker compose -f '${COMPOSE_FILE}' up -d --build" 2>&1
    ok "Application started"
  fi

  ip_addr="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"

  local done_text="Installation finished.\n\nContainer ID: ${CTID}\nHostname: ${HOSTNAME}\nCPU / RAM: ${CORES} vCPU / ${MEMORY} MB\nDisk: ${DISK} GB\nRepo: ${REPO_URL}\nRef: ${REPO_REF}\n\nWeb UI: http://${ip_addr:-<container-ip>}:8080\n\nUseful commands:\npct console ${CTID}\npct exec ${CTID} -- bash -lc 'cd ${APP_DIR} && docker compose logs -f'\n\nLog file: ${LOG_FILE}"
  pause_box "$done_text"
}

mode="$(menu_box)"
case "$mode" in
  default)
    ;;
  advanced)
    advanced_prompts
    ;;
  user_defaults)
    if load_defaults_file "$USER_DEFAULTS_FILE"; then
      ok "Loaded user defaults from ${USER_DEFAULTS_FILE}"
      if yesno_box "$APP_NAME" "Edit the loaded values before install?"; then
        advanced_prompts
      fi
    else
      warn "User defaults file not found: ${USER_DEFAULTS_FILE}"
      advanced_prompts
    fi
    ;;
  app_defaults)
    if load_defaults_file "$APP_DEFAULTS_FILE"; then
      ok "Loaded app defaults from ${APP_DEFAULTS_FILE}"
      if yesno_box "$APP_NAME" "Edit the loaded values before install?"; then
        advanced_prompts
      fi
    else
      warn "App defaults file not found: ${APP_DEFAULTS_FILE}"
      advanced_prompts
    fi
    ;;
  *)
    ;;
esac

show_summary_and_confirm || { warn "Installation cancelled"; exit 0; }
install_container
