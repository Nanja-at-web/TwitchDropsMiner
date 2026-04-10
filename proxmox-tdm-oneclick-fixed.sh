#!/usr/bin/env bash
# Proxmox VE host-side one-click installer for Nanja-at-web/TwitchDropsMiner.
# Creates a Debian 12 unprivileged LXC with Docker and builds/runs
# Nanja-at-web/TwitchDropsMiner from this fork.
#
# Example:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Nanja-at-web/TwitchDropsMiner/main/proxmox-tdm-oneclick-fixed.sh)"
#
# Optional overrides via environment variables:
#   CTID=123 CT_HOSTNAME=tdm REPO_REF=main bash -c "$(curl -fsSL ...)"
#   CTID=123 USE_DHCP=0 IPV4_CIDR=192.168.1.50/24 GATEWAY4=192.168.1.1 bash -c "$(curl -fsSL ...)"
#
# Notes:
# - Uses CT_HOSTNAME instead of HOSTNAME to avoid inheriting the Proxmox host name.
# - Keeps output cleaner than a raw bootstrap while staying fully non-interactive.

set -Eeuo pipefail

### ===== Configurable defaults (override via environment variables) =====
CTID="${CTID:-123}"
CT_HOSTNAME="${CT_HOSTNAME:-tdm}"
PASSWORD="${PASSWORD:-}"              # optional root password inside CT
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
BRIDGE="${BRIDGE:-vmbr0}"
CORES="${CORES:-1}"
MEMORY="${MEMORY:-1024}"
SWAP="${SWAP:-512}"
DISK="${DISK:-8}"                     # in GB
ONBOOT="${ONBOOT:-1}"
UNPRIVILEGED="${UNPRIVILEGED:-1}"
TZ="${TZ:-Europe/Berlin}"
USE_DHCP="${USE_DHCP:-1}"
IPV4_CIDR="${IPV4_CIDR:-192.168.1.50/24}"
GATEWAY4="${GATEWAY4:-192.168.1.1}"
REPO_URL="${REPO_URL:-https://github.com/Nanja-at-web/TwitchDropsMiner.git}"
REPO_REF="${REPO_REF:-main}"
APP_NAME="Nanja-at-web/TwitchDropsMiner"
APP_DIR="${APP_DIR:-/opt/tdm}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
START_AFTER_INSTALL="${START_AFTER_INSTALL:-1}"
APT_QUIET="${APT_QUIET:-1}"

if [[ "$EUID" -ne 0 ]]; then
  echo "Bitte als root auf dem Proxmox-Host ausführen." >&2
  exit 1
fi

if ! command -v pct >/dev/null 2>&1; then
  echo "pct wurde nicht gefunden. Dieses Skript muss auf einem Proxmox-Host laufen." >&2
  exit 1
fi

log() {
  printf '\n[%s] %s\n' "$(date +'%F %T')" "$*"
}

fail() {
  echo "Fehler in ${APP_NAME}-Installer: $*" >&2
  exit 1
}

cleanup_on_error() {
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    echo >&2
    echo "Der Installer für ${APP_NAME} wurde mit Fehlercode $rc beendet." >&2
    echo "Prüfe ggf. den CT mit: pct status ${CTID}" >&2
  fi
}
trap cleanup_on_error EXIT

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Benötigtes Kommando fehlt: $1"
}

need_cmd pveam
need_cmd awk
need_cmd sed
need_cmd grep
need_cmd cut

run_ct() {
  pct exec "$CTID" -- bash -lc "$1"
}

log "Starte One-Click-Setup für ${APP_NAME}"
log "Prüfe Debian-12-Template"
pveam update >/dev/null
TEMPLATE_PATH="$(pveam available --section system | awk '/debian-12-standard/ {print $2}' | sort | tail -n1)"
[[ -n "$TEMPLATE_PATH" ]] || fail "Kein Debian-12-Template gefunden"
TEMPLATE_FILE="$(basename "$TEMPLATE_PATH")"

if ! pveam list "$TEMPLATE_STORAGE" | awk '{print $2}' | grep -qx "$TEMPLATE_FILE"; then
  log "Lade Debian-12-Template ${TEMPLATE_FILE} nach ${TEMPLATE_STORAGE}"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_PATH"
fi

FULL_TEMPLATE="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_FILE}"

if pct status "$CTID" >/dev/null 2>&1; then
  fail "CTID ${CTID} existiert bereits. Bitte andere CTID wählen oder Container löschen."
fi

if [[ "$USE_DHCP" == "1" ]]; then
  NET0="name=eth0,bridge=${BRIDGE},ip=dhcp"
else
  NET0="name=eth0,bridge=${BRIDGE},ip=${IPV4_CIDR},gw=${GATEWAY4}"
fi

log "Erstelle Proxmox-LXC ${CTID} (${CT_HOSTNAME}) für ${APP_NAME}"
pct create "$CTID" "$FULL_TEMPLATE" \
  --hostname "$CT_HOSTNAME" \
  --ostype debian \
  --unprivileged "$UNPRIVILEGED" \
  --features nesting=1,keyctl=1 \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --swap "$SWAP" \
  --rootfs "${STORAGE}:${DISK}" \
  --net0 "$NET0" \
  --onboot "$ONBOOT" \
  --start 1 >/dev/null

if [[ -n "$PASSWORD" ]]; then
  log "Setze root-Passwort im ${APP_NAME}-Container"
  pct set "$CTID" --password "$PASSWORD" >/dev/null
fi

log "Warte auf Start des ${APP_NAME}-Containers"
sleep 8

log "Installiere Grundpakete, Locale, Git und Docker im ${APP_NAME}-Container"
run_ct '
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
if [[ "${APT_QUIET:-1}" == "1" ]]; then
  Q="-qq"
else
  Q=""
fi
apt-get ${Q} update
apt-get ${Q} install -y ca-certificates curl git gnupg lsb-release locales >/dev/null
sed -i "s/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/" /etc/locale.gen
locale-gen en_US.UTF-8 >/dev/null
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 >/dev/null || true
printf "LANG=en_US.UTF-8\nLC_ALL=en_US.UTF-8\n" >/etc/default/locale
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
apt-get ${Q} update
apt-get ${Q} install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
systemctl enable docker >/dev/null 2>&1
systemctl start docker
'

log "Klonen von ${APP_NAME} (${REPO_URL} @ ${REPO_REF})"
run_ct "rm -rf '${APP_DIR}' && git clone --quiet '${REPO_URL}' '${APP_DIR}'"
run_ct "cd '${APP_DIR}' && git fetch --quiet --all --tags && git checkout '${REPO_REF}' >/dev/null 2>&1"

log "Prüfe Compose-Datei für ${APP_NAME}"
run_ct "test -f '${APP_DIR}/${COMPOSE_FILE}'" || fail "${COMPOSE_FILE} nicht im ${APP_NAME}-Repo gefunden"

log "Erstelle persistente Verzeichnisse für ${APP_NAME}"
run_ct "mkdir -p '${APP_DIR}/data' '${APP_DIR}/logs'"

if [[ "$START_AFTER_INSTALL" == "1" ]]; then
  log "Baue und starte Docker-Stack für ${APP_NAME}"
  run_ct "cd '${APP_DIR}' && docker compose -f '${COMPOSE_FILE}' up -d --build"
fi

IP_ADDR="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"

echo
cat <<SUMMARY_EOF
Fertig: ${APP_NAME} wurde installiert.

Container-ID:    ${CTID}
Hostname:        ${CT_HOSTNAME}
Bridge:          ${BRIDGE}
CPU / RAM:       ${CORES} vCPU / ${MEMORY} MB
Disk:            ${DISK} GB
Fork:            ${APP_NAME}
Repo:            ${REPO_URL}
Ref:             ${REPO_REF}
App-Verzeichnis: ${APP_DIR}
Compose-Datei:   ${COMPOSE_FILE}

Nützliche Befehle für ${APP_NAME}:
  pct console ${CTID}
  pct exec ${CTID} -- bash -lc 'cd ${APP_DIR} && docker compose logs -f'
  pct exec ${CTID} -- bash -lc 'cd ${APP_DIR} && git pull && docker compose up -d --build'
  pct exec ${CTID} -- bash -lc 'cd ${APP_DIR} && docker compose restart'
SUMMARY_EOF

if [[ -n "$IP_ADDR" ]]; then
  echo "${APP_NAME} Web UI: http://${IP_ADDR}:8080"
else
  echo "${APP_NAME} Web UI: http://<container-ip>:8080"
fi

if [[ "$USE_DHCP" == "1" ]]; then
  echo "Hinweis für ${APP_NAME}: DHCP ist aktiv. Für dauerhafte Erreichbarkeit kann eine feste IP sinnvoll sein."
else
  echo "Für ${APP_NAME} verwendete statische IP: ${IPV4_CIDR}"
fi
