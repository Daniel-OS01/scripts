#!/usr/bin/env bash
#
# oci-manager2.sh
# Enhanced OCI Security List & iptables sync for CasaOS + Docker ports
#
set -euo pipefail

LOG_DIR="/DATA/Documents"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="$LOG_DIR/oci-manager2-$TIMESTAMP.log"
CHAIN="CASAOS-OCI-PORTS"
OCI_CLI="${OCI_CLI:-oci}"
OCI_DEBUG_FLAGS="--debug"

# Helper: log with timestamp
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# Ensure OCI CLI installed
ensure_oci_cli() {
  if ! command -v $OCI_CLI &>/dev/null; then
    log "INFO: Installing OCI CLI..."
    apt-get update -qq
    apt-get install -y python3-pip jq &>>"$LOG_FILE"
    pip3 install oci-cli &>>"$LOG_FILE"
    log "INFO: OCI CLI installed"
  fi
}

# Validate OCI config & auth
validate_oci() {
  log "INFO: Validating OCI CLI authentication..."
  if ! $OCI_CLI iam region list $OCI_DEBUG_FLAGS &>>"$LOG_FILE"; then
    log "ERROR: OCI CLI authentication failed"; exit 1
  fi
  log "INFO: OCI CLI authenticated"
}

# Read security-list OCID
choose_security_list() {
  echo
  log "INFO: Security List Management"
  echo "1) Use default security list OCID (from instance metadata)"
  echo "2) Enter custom security list OCID"
  echo "3) Skip OCI sync"
  read -rp "Choose option [1-3]: " opt
  case $opt in
    1)
      DEFAULT_SL=$($OCI_CLI compute instance list --availability-domain "$(curl -s http://169.254.169.254/opc/v2/instance/ | jq -r .data.\"availability-domain\")" \
        --query 'data[0].metadata."securityListIds"[0]' --raw-output)
      SL_OCID=${SL_OCID:-$DEFAULT_SL}
      ;;
    2)
      read -rp "Enter Security List OCID: " SL_OCID
      ;;
    3)
      log "INFO: Skipping OCI sync per user choice"
      SKIP_OCI=true
      ;;
    *)
      log "ERROR: Invalid option"; exit 1
      ;;
  esac
  log "INFO: Using Security List: $SL_OCID"
}

# Gather ports & protocols (ingress)
gather_ports() {
  log "INFO: Gathering CasaOS Gateway ports..."
  ports=$(curl -s http://127.0.0.1:$(grep -Po '(?<=management.url ).*' /var/run/casaos/management.url | cut -d: -f2)/v1/gateway/routes \
           | jq -r '.routes[] | "\(.port)/\(.protocol|ascii_upcase)"')
  log "INFO: Gathering Docker published ports..."
  docker_ports=$(docker ps --format '{{.Ports}}' | grep -oP '(?<=0\.0\.0\.0:)\d+/(tcp|udp)' || true)
  all_ports=$(printf "%s\n%s\nTCP/Ingress\nUDP/Ingress\n" "$ports" "$docker_ports" | sort -u)
  echo "$all_ports"
}

# Setup iptables chain
setup_iptables_chain() {
  if ! iptables -nL "$CHAIN" &>/dev/null; then
    iptables -N "$CHAIN"
    iptables -I INPUT -m conntrack --ctstate NEW -j "$CHAIN"
    log "INFO: Created iptables chain $CHAIN"
  fi
  iptables -F "$CHAIN"
}

# Apply iptables rules
apply_iptables() {
  setup_iptables_chain
  while read -r entry; do
    [[ -z $entry ]] && continue
    port=${entry%/*}; proto=${entry#*/}
    iptables -A "$CHAIN" -p "${proto,,}" --dport "$port" -j ACCEPT
    log "INFO: iptables allow $proto port $port"
  done <<<"$1"
  netfilter-persistent save &>>"$LOG_FILE"
}

# Build OCI JSON rules
build_oci_json() {
  ports_json="["
  first=true
  while read -r entry; do
    [[ -z $entry ]] && continue
    port=${entry%/*}
    proto=${entry#*/}
    [[ $first == true ]] && first=false || ports_json+=","
    ports_json+=$(
      jq -n --arg p "$port" --arg pro "$([[ $proto == TCP ]] && echo 6 || echo 17)" \
        '{ source:"0.0.0.0/0", protocol:$pro, isStateless:false,
           tcpOptions:(if $pro=="6" then { destinationPortRange:{min:($p|tonumber),max:($p|tonumber)} } else null end),
           udpOptions:(if $pro=="17" then { destinationPortRange:{min:($p|tonumber),max:($p|tonumber)} } else null end)
        }'
    )
  done <<<"$1"
  ports_json+="]"
  echo "$ports_json"
}

# Sync to OCI
sync_to_oci() {
  if [[ "${SKIP_OCI:-false}" == true ]]; then return; fi
  log "INFO: Fetching existing security list..."
  existing=$($OCI_CLI network security-list get --security-list-id "$SL_OCID" $OCI_DEBUG_FLAGS &>>"$LOG_FILE")
  rules_json=$(build_oci_json "$1")
  tmp=$(mktemp)
  echo "$rules_json" >"$tmp"
  log "INFO: Updating OCI Security List ($SL_OCID)..."
  if ! $OCI_CLI network security-list update \
        --security-list-id "$SL_OCID" \
        --ingress-security-rules file://"$tmp" \
        --egress-security-rules '[]' \
        --force $OCI_DEBUG_FLAGS &>>"$LOG_FILE"; then
    log "ERROR: OCI update failed; see log for details"; exit 1
  fi
  rm -f "$tmp"
  log "INFO: OCI Security List updated"
}

# Install systemd service & timer
install_service() {
  cat >/etc/systemd/system/oci-manager2.service <<EOF
[Unit]
Description=OCI Security List Sync for CasaOS Ports
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/oci-manager2.sh --sync

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/oci-manager2.timer <<EOF
[Unit]
Description=Timer for OCI Security List Sync

[Timer]
OnCalendar=*:0/10
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now oci-manager2.timer
  log "INFO: Installed systemd timer for automatic sync every 10 minutes"
}

# Main interactive flow
main() {
  ensure_oci_cli
  validate_oci
  choose_security_list

  echo; log "INFO: Getting current port/protocol list..."
  entries=$(gather_ports)
  echo "$entries" | tee -a "$LOG_FILE"

  apply_iptables "$entries"
  sync_to_oci "$entries"

  echo
  echo "1) Sync now"
  echo "2) Install auto-sync timer (every 10 min)"
  echo "3) Both"
  read -rp "Choose option [1-3]: " choice
  case $choice in
    1) ;;
    2) install_service ;;
    3) install_service ;;
    *) log "ERROR: Invalid choice"; exit 1 ;;
  esac

  log "INFO: oci-manager2 completed successfully"
}

# CLI switches
case "${1:-}" in
  --interactive) main ;;
  --sync)
    entries=$(gather_ports)
    apply_iptables "$entries"
    sync_to_oci "$entries"
    ;;
  *)
    echo "Usage: $0 --interactive | --sync"
    exit 1
    ;;
esac
