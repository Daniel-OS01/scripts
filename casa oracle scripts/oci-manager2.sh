#!/bin/bash
# OCI Ingress Manager with Enhanced Error Handling and Debugging
# Fixes the "Failed to update security list" issue

set -euo pipefail

LOG_DIR="/DATA/Documents"
LOG_FILE="$LOG_DIR/oci-manager-$(date +%Y%m%d-%H%M%S).log"
OCI_CONFIG="$HOME/.oci/config"

# Colors for output
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
info() { log "INFO: $*"; echo -e "${BLUE}ℹ $*${NC}"; }
success() { log "SUCCESS: $*"; echo -e "${GREEN}✓ $*${NC}"; }
error() { log "ERROR: $*"; echo -e "${RED}✗ $*${NC}" >&2; }
warn() { log "WARN: $*"; echo -e "${YELLOW}⚠ $*${NC}"; }

# Enhanced error capture function
run_oci_command() {
    local cmd="$*"
    local temp_stdout=$(mktemp)
    local temp_stderr=$(mktemp)
    local exit_code=0
    
    log "COMMAND: $cmd"
    
    # Set debug environment variables
    export OCI_GO_SDK_DEBUG=1
    export OCI_CLI_DEBUG=1
    
    # Run command and capture both stdout and stderr
    if ! eval "$cmd" >"$temp_stdout" 2>"$temp_stderr"; then
        exit_code=$?
        error "Command failed with exit code: $exit_code"
        error "STDOUT: $(cat "$temp_stdout")"
        error "STDERR: $(cat "$temp_stderr")"
        
        # Parse common error patterns
        if grep -q "NotAuthenticated" "$temp_stderr"; then
            error "Authentication failed - check OCI config file"
            diagnose_authentication
        elif grep -q "NotAuthorized" "$temp_stderr"; then
            error "Permission denied - user lacks required IAM permissions"
            diagnose_permissions
        elif grep -q "InvalidParameter" "$temp_stderr"; then
            error "Invalid parameter in request - check JSON format"
            diagnose_json_format
        elif grep -q "TooManyRequests" "$temp_stderr"; then
            error "Rate limit exceeded - retrying in 30 seconds"
            sleep 30
        fi
        
        rm -f "$temp_stdout" "$temp_stderr"
        return $exit_code
    fi
    
    success "Command executed successfully"
    cat "$temp_stdout"
    rm -f "$temp_stdout" "$temp_stderr"
    return 0
}

diagnose_authentication() {
    info "Diagnosing OCI authentication issues..."
    
    if [[ ! -f "$OCI_CONFIG" ]]; then
        error "OCI config file not found at $OCI_CONFIG"
        info "Run: oci setup config"
        return 1
    fi
    
    # Check config file format
    info "Checking OCI config file format..."
    
    local required_fields=("user" "fingerprint" "key_file" "tenancy" "region")
    for field in "${required_fields[@]}"; do
        if ! grep -q "^$field=" "$OCI_CONFIG"; then
            error "Missing required field in config: $field"
        else
            success "Found required field: $field"
        fi
    done
    
    # Check key file exists and has correct permissions
    local key_file
    key_file=$(grep "^key_file=" "$OCI_CONFIG" | cut -d'=' -f2 | tr -d ' ')
    
    if [[ ! -f "$key_file" ]]; then
        error "Private key file not found: $key_file"
    else
        local perms
        perms=$(stat -c "%a" "$key_file")
        if [[ "$perms" != "600" ]]; then
            warn "Key file permissions should be 600, currently: $perms"
            info "Fix with: chmod 600 $key_file"
        else
            success "Key file permissions are correct"
        fi
    fi
    
    # Test basic connectivity
    info "Testing basic OCI connectivity..."
    if run_oci_command "oci iam region list --limit 1"; then
        success "Basic OCI connectivity works"
    else
        error "Basic OCI connectivity failed"
    fi
}

diagnose_permissions() {
    info "Diagnosing OCI IAM permissions..."
    
    # Try to list compartments to test basic read permissions
    info "Testing compartment list permissions..."
    if run_oci_command "oci iam compartment list --limit 1"; then
        success "Can list compartments"
    else
        error "Cannot list compartments - check basic IAM permissions"
    fi
    
    # Try to get the specific security list
    info "Testing security list read permissions..."
    local sl_ocid="$1"
    if run_oci_command "oci network security-list get --security-list-id $sl_ocid"; then
        success "Can read security list"
    else
        error "Cannot read security list - check VCN permissions"
    fi
    
    info "Required IAM permissions for security list updates:"
    echo "  - inspect security-lists"
    echo "  - read security-lists" 
    echo "  - use security-lists"
    echo "  - manage security-lists"
}

diagnose_json_format() {
    info "Diagnosing JSON format issues..."
    
    # Generate sample JSON to show correct format
    info "Generating sample security rules JSON format..."
    
    cat <<EOF | tee "$LOG_DIR/sample-security-rules.json"
[
  {
    "source": "0.0.0.0/0",
    "protocol": "6",
    "isStateless": false,
    "tcpOptions": {
      "destinationPortRange": {
        "min": 80,
        "max": 80
      }
    }
  },
  {
    "source": "0.0.0.0/0", 
    "protocol": "6",
    "isStateless": false,
    "tcpOptions": {
      "destinationPortRange": {
        "min": 443,
        "max": 443
      }
    }
  }
]
EOF
    
    info "Sample JSON saved to: $LOG_DIR/sample-security-rules.json"
}

check_cli() {
    if ! command -v oci &>/dev/null; then
        return 1
    fi
    return 0
}

install_cli() {
    info "Installing OCI CLI..."
    if command -v apt &>/dev/null; then
        apt update -qq
        apt install -y python3-pip
    elif command -v yum &>/dev/null; then
        yum install -y python3-pip
    fi
    
    pip3 install oci-cli
    success "OCI CLI installed successfully"
}

configure_cli() {
    info "Configuring OCI CLI..."
    if [[ -f "$OCI_CONFIG" ]]; then
        warn "OCI config file already exists at $OCI_CONFIG"
        read -p "Do you want to reconfigure? (y/N): " -r reconfigure
        if [[ ! $reconfigure =~ ^[Yy]$ ]]; then
            info "Using existing configuration"
            return 0
        fi
    fi
    
    oci setup config
    success "OCI CLI configured"
}

get_current_ports() {
    info "Getting current port list from CasaOS and Docker..."
    
    local ports=""
    
    # Get CasaOS gateway ports if available
    if [[ -f "/var/run/casaos/management.url" ]]; then
        local mgmt_port
        mgmt_port=$(cat /var/run/casaos/management.url | cut -d: -f2)
        if command -v curl &>/dev/null; then
            local casaos_ports
            casaos_ports=$(curl -s "http://127.0.0.1:$mgmt_port/v1/gateway/routes" | jq -r '.routes[].port' 2>/dev/null || echo "")
            if [[ -n "$casaos_ports" ]]; then
                ports="$ports $casaos_ports"
            fi
        fi
    fi
    
    # Get Docker published ports
    if command -v docker &>/dev/null; then
        local docker_ports
        docker_ports=$(docker ps --format '{{.Ports}}' 2>/dev/null | grep -oP '(?<=0\.0\.0\.0:)\d+' | sort -n | uniq || echo "")
        if [[ -n "$docker_ports" ]]; then
            ports="$ports $docker_ports"
        fi
    fi
    
    # Add standard ports
    ports="$ports 22 80 443"
    
    # Remove duplicates and sort
    echo "$ports" | tr ' ' '\n' | sort -n | uniq | tr '\n' ' '
}

create_security_rules_json() {
    local ports="$1"
    local json_file="$2"
    
    info "Creating security rules JSON for ports: $ports"
    
    echo "[" > "$json_file"
    
    local first=true
    for port in $ports; do
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        
        if [[ $first == true ]]; then
            first=false
        else
            echo "," >> "$json_file"
        fi
        
        cat << EOF >> "$json_file"
  {
    "source": "0.0.0.0/0",
    "protocol": "6",
    "isStateless": false,
    "tcpOptions": {
      "destinationPortRange": {
        "min": $port,
        "max": $port
      }
    }
  }
EOF
    done
    
    echo "]" >> "$json_file"
    
    # Validate JSON format
    if command -v jq &>/dev/null; then
        if ! jq empty "$json_file" 2>/dev/null; then
            error "Generated JSON is invalid"
            return 1
        fi
        success "Generated valid security rules JSON"
    fi
}

update_security_list() {
    local sl_ocid="$1"
    local ports="$2"
    
    info "Updating OCI Security List: $sl_ocid"
    
    # Create temporary JSON file
    local json_file
    json_file=$(mktemp --suffix=.json)
    
    if ! create_security_rules_json "$ports" "$json_file"; then
        rm -f "$json_file"
        return 1
    fi
    
    info "Security rules JSON content:"
    cat "$json_file" | tee -a "$LOG_FILE"
    
    # Get current security list to preserve egress rules
    info "Getting current security list configuration..."
    local current_config
    current_config=$(mktemp)
    
    if ! run_oci_command "oci network security-list get --security-list-id $sl_ocid" > "$current_config"; then
        error "Failed to get current security list"
        rm -f "$json_file" "$current_config"
        return 1
    fi
    
    # Extract current egress rules
    local egress_rules
    egress_rules=$(jq '.data."egress-security-rules"' "$current_config" 2>/dev/null || echo "[]")
    
    # Update security list with new ingress rules and preserve egress rules
    info "Updating security list with new rules..."
    if run_oci_command "oci network security-list update --security-list-id $sl_ocid --ingress-security-rules file://$json_file --egress-security-rules '$egress_rules' --force"; then
        success "Security list updated successfully"
        rm -f "$json_file" "$current_config"
        return 0
    else
        error "Failed to update security list"
        rm -f "$json_file" "$current_config"
        return 1
    fi
}

# Main functions
setup_oci_cli() {
    check_cli || install_cli
    [[ -f "$OCI_CONFIG" ]] || configure_cli
    
    # Test authentication
    if ! run_oci_command "oci iam region list --limit 1"; then
        error "OCI CLI authentication test failed"
        diagnose_authentication
        return 1
    fi
    
    success "OCI CLI is properly configured and authenticated"
}

interactive_setup() {
    info "=== OCI Security List Manager ==="
    
    # Setup OCI CLI
    setup_oci_cli || return 1
    
    # Get security list OCID
    echo
    info "Security List Management:"
    echo "1. Use default security list OCID (from your Oracle instance)"
    echo "2. Enter custom security list OCID"
    echo "3. Skip security list setup"
    read -p "Choose option [1-3]: " -r choice
    
    local sl_ocid=""
    case $choice in
        1)
            sl_ocid="ocid1.securitylist.oc1.il-jerusalem-1.aaaaaaaalbopisjjx3i3z2pediruuus2pxyk4sfhjd4j7pqw4fpn7ugmym2q"
            info "Using default security list: $sl_ocid"
            ;;
        2)
            read -p "Enter security list OCID: " -r sl_ocid
            ;;
        3)
            info "Skipping security list setup"
            return 0
            ;;
        *)
            error "Invalid choice"
            return 1
            ;;
    esac
    
    # Test security list access
    if ! run_oci_command "oci network security-list get --security-list-id $sl_ocid"; then
        error "Cannot access security list: $sl_ocid"
        diagnose_permissions "$sl_ocid"
        return 1
    fi
    
    success "Security list access verified"
    
    # Get current ports
    local ports
    ports=$(get_current_ports)
    info "Detected ports: $ports"
    
    echo
    echo "Would you like to:"
    echo "1. Sync current ports to OCI security list now"
    echo "2. Set up automatic port syncing (every 10 minutes)"
    echo "3. Both"
    read -p "Choose option [1-3]: " -r sync_choice
    
    case $sync_choice in
        1|3)
            info "Syncing local ports to OCI Security List..."
            if update_security_list "$sl_ocid" "$ports"; then
                success "Ports synced successfully"
            else
                error "Failed to sync ports"
                return 1
            fi
            ;;
    esac
    
    case $sync_choice in
        2|3)
            info "Setting up automatic port syncing..."
            create_sync_service "$sl_ocid"
            ;;
    esac
    
    success "OCI setup completed"
}

create_sync_service() {
    local sl_ocid="$1"
    
    # Create sync script
    cat > /usr/local/bin/oci-port-sync.sh << EOF
#!/bin/bash
# Automatic OCI Security List Port Sync
LOG_FILE="$LOG_DIR/oci-port-sync-\$(date +%Y%m%d).log"
echo "[\$(date)] Starting OCI port sync..." >> "\$LOG_FILE"

# Source the main script functions
source /usr/local/bin/oci-manager-fixed.sh

# Get current ports
PORTS=\$(get_current_ports)
echo "[\$(date)] Detected ports: \$PORTS" >> "\$LOG_FILE"

# Update security list
if update_security_list "$sl_ocid" "\$PORTS"; then
    echo "[\$(date)] Port sync completed successfully" >> "\$LOG_FILE"
else
    echo "[\$(date)] Port sync failed" >> "\$LOG_FILE"
fi
EOF
    
    chmod +x /usr/local/bin/oci-port-sync.sh
    
    # Create systemd service
    cat > /etc/systemd/system/oci-port-sync.service << EOF
[Unit]
Description=OCI Security List Port Sync
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/oci-port-sync.sh
EOF
    
    # Create systemd timer
    cat > /etc/systemd/system/oci-port-sync.timer << EOF
[Unit]
Description=OCI Security List Port Sync Timer
Requires=oci-port-sync.service

[Timer]
OnCalendar=*:0/10
Persistent=true

[Install]
WantedBy=timers.target
EOF
    
    systemctl daemon-reload
    systemctl enable --now oci-port-sync.timer
    
    success "Created OCI port sync service (runs every 10 minutes)"
}

# Main execution
main() {
    mkdir -p "$LOG_DIR"
    
    case "${1:-}" in
        --interactive)
            interactive_setup
            ;;
        --test-auth)
            diagnose_authentication
            ;;
        --test-permissions)
            diagnose_permissions "${2:-}"
            ;;
        --update-security-list)
            local sl_ocid="$2"
            local ports
            ports=$(get_current_ports)
            update_security_list "$sl_ocid" "$ports"
            ;;
        *)
            echo "Usage: $0 [--interactive|--test-auth|--test-permissions OCID|--update-security-list OCID]"
            echo
            echo "This script fixes OCI CLI security list update issues by:"
            echo "  • Enhanced error reporting and debugging"
            echo "  • Proper authentication diagnosis"
            echo "  • JSON format validation"
            echo "  • Permission checking"
            echo "  • Verbose logging"
            ;;
    esac
}

main "$@"
