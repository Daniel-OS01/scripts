#!/bin/bash
#
# oci-manager2.sh — Improved OCI Security List & iptables Sync for CasaOS & Docker
# Logs to /DATA/Documents/oci-manager2-<timestamp>.log
# Place in /usr/local/bin and chmod +x

set -euo pipefail
IFS=$'\n\t'

# Configuration
LOG_DIR="/DATA/Documents"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/oci-manager2-$(date +%Y%m%d-%H%M%S).log"
OCI_CLI_DEBUG="${OCI_CLI_DEBUG:-0}"
DEFAULT_SL_OCID="ocid1.securitylist.oc1.il-jerusalem-1.aaaaaaaalbopisjjx3i3z2pediruuus2pxyk4sfhjd4j7pqw4fpn7ugmym2q"
IPTABLES_CHAIN="CASAOS-OCI-PORTS"
AUTO_TIMER="oci-port-sync.timer"
AUTO_SERVICE="oci-port-sync.service"

# Helpers
_log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
info() { _log "INFO: $*"; echo -e "ℹ $*"; }
success() { _log "OK: $*"; echo -e "✓ $*"; }
error() { _log "ERROR: $*"; echo -e "✗ $*" >&2; }
run() {
  _log "COMMAND: $*"
  if ! output=$("$@" 2>&1); then
    error "Command failed: $*"
    _log "OUTPUT: $output"
    return 1
  fi
  _log "OUTPUT: $output"
  echo "$output"
}

# Ensure OCI CLI installed
ensure_oci() {
  if ! command -v oci &>/dev/null; then
    info "Installing OCI CLI"
    apt-get update -qq
    apt-get install -y python3-pip > /dev/null
    pip3 install oci-cli > /dev/null
    success "OCI CLI installed"
  fi
}

# Validate OCI auth
validate_oci() {
  info "Validating OCI CLI authentication"
  if ! run oci iam region list &>/dev/null; then
    error "OCI auth failed—please run 'oci setup config' or check ~/.oci/config"
    exit 1
  fi
  success "OCI CLI authenticated"
}

# Build list of published ports and protocols
gather_ports() {
  info "Gathering CasaOS & Docker ports"
  declare -A map
  # CasaOS Gateway
  if [[ -f /var/run/casaos/management.url ]]; then
    mgmt_port=$(grep -Po '(?<=:)\d+' /var/run/casaos/management.url)
    for p in $(curl -s "http://127.0.0.1:$mgmt_port/v1/gateway/routes" | jq -r '.routes[] | "\(.port)/\(.protocol)"'); do
      map["$p"]=1
    done
  fi
  # Docker published
  for line in $(docker ps --format '{{.Ports}}'); do
    # e.g. "0.0.0.0:8000->80/tcp"
    while [[ $line =~ ([0-9\.]+):([0-9]+)->([0-9]+)/([a-z]+) ]]; do
      publ="${BASH_REMATCH[2]}/${BASH_REMATCH[4]}"
      map["$publ"]=1
      line=${line#*${BASH_REMATCH[0]}}
    done
  done
  # Always include SSH/web
  map["22/tcp"]=1 map["80/tcp"]=1 map["443/tcp"]=1
  # Export arrays
  PORTS=()
  for k in "${!map[@]}"; do PORTS+=("$k"); done
}

# Generate JSON rules for both ingress and egress (mirrored)
gen_rules_json() {
  info "Generating OCI security-list rules JSON"
  ingress=()
  egress=()
  for entry in "${PORTS[@]}"; do
    port=${entry%/*}
    proto=${entry#*/}
    numproto=$([[ "$proto" == "tcp" ]] && echo 6 || echo 17)
    rule=$(cat <<EOF
{
  "source": "0.0.0.0/0",
  "protocol": "$numproto",
  "isStateless": false,
  "${proto}Options": {
    "destinationPortRange": { "min": $port, "max": $port }
  }
}
EOF
)
    ingress+=("$rule")
    # egress allow same port outbound
    ruleOut=$(cat <<EOF
{
  "destination": "0.0.0.0/0",
  "protocol": "$numproto",
  "isStateless": false,
  "${proto}Options": {
    "destinationPortRange": { "min": $port, "max": $port }
  }
}
EOF
)
    egress+=("$ruleOut")
  done
  # join
  ingress_json="[${ingress[*]}]"
  egress_json="[${egress[*]}]"
  _log "Ingress JSON: $ingress_json"
  _log "Egress  JSON: $egress_json"
}

# Update OCI security list
sync_oci() {
  local sl_ocid=$1
  gen_rules_json
  info "Updating OCI security list: $sl_ocid"
  tmpf=$(mktemp)
  cat >"$tmpf" <<EOF
{
  "ingressSecurityRules": $ingress_json,
  "egressSecurityRules": $egress_json
}
EOF
  run oci network security-list update \
    --security-list-id "$sl_ocid" \
    --force \
    --from-json file://"$tmpf"
  rm -f "$tmpf"
  success "OCI security list updated"
}

# Update iptables
sync_iptables() {
  info "Syncing iptables chain: $IPTABLES_CHAIN"
  iptables -nL "$IPTABLES_CHAIN" &>/dev/null || iptables -N "$IPTABLES_CHAIN"
  # hook chain
  if ! iptables -C INPUT -j "$IPTABLES_CHAIN" &>/dev/null; then
    pos=$(iptables -L INPUT --line-numbers | grep REJECT | head -1 | awk '{print $1}')
    iptables -I INPUT "$pos" -j "$IPTABLES_CHAIN"
  fi
  iptables -F "$IPTABLES_CHAIN"
  for entry in "${PORTS[@]}"; do
    port=${entry%/*}
    proto=${entry#*/}
    iptables -A "$IPTABLES_CHAIN" -p "$proto" --dport "$port" -j ACCEPT
  done
  iptables -A "$IPTABLES_CHAIN" -j RETURN
  netfilter-persistent save
  success "iptables updated"
}

# Setup systemd timer & service
setup_auto_sync() {
  info "Creating systemd service & timer for automatic sync"
  cat >/etc/systemd/system/oci-port-sync.service <<EOF
[Unit]
Description=OCI & iptables port-sync for CasaOS

[Service]
Type=oneshot
ExecStart=/usr/local/bin/oci-manager2.sh --sync-only \$SL_OCID
EOF

  cat >/etc/systemd/system/oci-port-sync.timer <<EOF
[Unit]
Description=Run OCI port-sync every 10 minutes

[Timer]
OnCalendar=*:0/10
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now oci-port-sync.timer
  success "Automatic sync enabled (every 10m)"
}

# Interactive menu
main() {
  ensure_oci
  validate_oci
  gather_ports

  echo; info "=== OCI Security List Manager ==="
  echo "1) Use default security list"
  echo "2) Enter custom security list OCID"
  echo "3) Skip OCI setup"
  read -rp "Choose [1-3]: " opt
  case $opt in
    1) SL_OCID=$DEFAULT_SL_OCID ;;
    2) read -rp "Enter Security List OCID: " SL_OCID ;;
    3) SL_OCID="" ;;
    *) error "Invalid"; exit 1 ;;
  esac

  echo; echo "Detected ports/protocols:"
  printf "  %s\n" "${PORTS[@]}"

  echo; echo "1) Sync now"
  echo "2) Enable automatic sync"
  echo "3) Both"
  read -rp "Choose [1-3]: " action

  [[ -n $SL_OCID ]] && {
    (( action==1 || action==3 )) && sync_oci "$SL_OCID"
  }

  sync_iptables

  (( action==2 || action==3 )) && {
    setup_auto_sync
  }

  success "All done! Logs: $LOG_FILE"
}

if [[ "${1:-}" == "--interactive" ]]; then
  main
elif [[ "${1:-}" == "--sync-only" ]]; then
  SL_OCID=$2
  gather_ports
  sync_oci "$SL_OCID"
  sync_iptables
else
  echo "Usage: $0 --interactive"
  exit 1
fi
