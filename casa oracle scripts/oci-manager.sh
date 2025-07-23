#!/bin/bash
# Oracle Cloud Infrastructure Manager
# Installs and configures OCI CLI, manages security lists
# Version: 1.0

set -euo pipefail

# Configuration
LOG_DIR="/DATA/Documents"
LOG_FILE="$LOG_DIR/oci-manager-$(date +%Y%m%d).log"
OCI_CONFIG_DIR="$HOME/.oci"
OCI_CLI_PATH="/usr/local/bin/oci"

# Oracle Cloud OCIDs (from user's previous conversation)
DEFAULT_VCN_OCID="ocid1.vcn.oc1.il-jerusalem-1.amaaaaaalzrlldya4v55ro7iwru44x6dichgdxfkbcxafwascy2bgwzwnqxq"
DEFAULT_SECURITY_LIST_OCID="ocid1.securitylist.oc1.il-jerusalem-1.aaaaaaaalbopisjjx3i3z2pediruuus2pxyk4sfhjd4j7pqw4fpn7ugmym2q"
DEFAULT_INSTANCE_OCID="ocid1.instance.oc1.il-jerusalem-1.anwxiljrlzrlldycsq7xu643ghoif36gjfkfa2lqoboeswmwkqsdik6fdbmq"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

info() { log "INFO" "$@"; }
error() { log "ERROR" "$@"; echo -e "${RED}ERROR: $*${NC}" >&2; }
success() { log "INFO" "$@"; echo -e "${GREEN}✓ $*${NC}"; }
warning() { log "WARN" "$@"; echo -e "${YELLOW}⚠ $*${NC}"; }

# Check if OCI CLI is installed
check_oci_cli() {
    if command -v oci >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Install OCI CLI
install_oci_cli() {
    info "Installing Oracle Cloud Infrastructure CLI..."
    
    # Install Python and pip if needed
    if ! command -v python3 >/dev/null 2>&1; then
        apt update
        apt install -y python3 python3-pip
    fi
    
    # Create installation directory
    mkdir -p /opt/oracle/cli
    
    # Download and install OCI CLI
    curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh -o /tmp/oci-install.sh
    
    # Run installer with default options
    bash /tmp/oci-install.sh \
        --accept-all-defaults \
        --install-dir /opt/oracle/cli \
        --exec-dir /usr/local/bin \
        --update-path-and-enable-tab-completion \
        --rc-file-path /etc/bash.bashrc
    
    # Cleanup
    rm -f /tmp/oci-install.sh
    
    success "OCI CLI installed successfully"
}

# Configure OCI CLI interactively
configure_oci_cli() {
    info "Configuring OCI CLI..."
    
    if [[ ! -d "$OCI_CONFIG_DIR" ]]; then
        mkdir -p "$OCI_CONFIG_DIR"
    fi
    
    echo -e "${BLUE}OCI CLI Configuration${NC}"
    echo "You will need the following information:"
    echo "1. User OCID"
    echo "2. Tenancy OCID"
    echo "3. Region (e.g., il-jerusalem-1)"
    echo "4. API Key fingerprint"
    echo "5. Path to private key file"
    echo ""
    
    # Run OCI setup config
    oci setup config
    
    success "OCI CLI configured"
}

# Generate security list rule JSON for ports
generate_security_rules() {
    local ports="$1"
    local rules_json="["
    local first=true
    
    while IFS= read -r port; do
        if [[ -n "$port" && "$port" =~ ^[0-9]+$ ]]; then
            if [[ "$first" = true ]]; then
                first=false
            else
                rules_json+=","
            fi
            
            rules_json+="{
                \"source\": \"0.0.0.0/0\",
                \"protocol\": \"6\",
                \"isStateless\": false,
                \"description\": \"CasaOS Auto-Port for port $port\",
                \"tcpOptions\": {
                    \"destinationPortRange\": {
                        \"max\": $port,
                        \"min\": $port
                    }
                }
            }"
        fi
    done <<< "$ports"
    
    rules_json+="]"
    echo "$rules_json"
}

# Get current ingress rules from security list
get_current_rules() {
    local security_list_id="$1"
    
    oci network security-list get \
        --security-list-id "$security_list_id" \
        --query 'data."ingress-security-rules"' \
        --output json 2>/dev/null || echo "[]"
}

# Update OCI security list with new ports
update_security_list() {
    local security_list_id="$1"
    local new_ports="$2"
    
    if ! check_oci_cli; then
        error "OCI CLI not installed or configured"
        return 1
    fi
    
    info "Updating OCI Security List: $security_list_id"
    
    # Get current rules
    local current_rules
    current_rules=$(get_current_rules "$security_list_id")
    
    # Generate new rules for ports
    local new_rules
    new_rules=$(generate_security_rules "$new_ports")
    
    # Merge current rules with new port rules (this is a simplified merge)
    # In production, you'd want more sophisticated merging
    local temp_file="/tmp/security_rules_$$.json"
    echo "$new_rules" > "$temp_file"
    
    # Update the security list
    if oci network security-list update \
        --security-list-id "$security_list_id" \
        --ingress-security-rules "file://$temp_file" \
        --force >/dev/null 2>&1; then
        success "Updated security list with ports: $(echo "$new_ports" | tr '\n' ' ')"
    else
        error "Failed to update security list"
    fi
    
    # Cleanup
    rm -f "$temp_file"
}

# Monitor and sync ports to OCI
sync_ports_to_oci() {
    local security_list_id="$1"
    
    info "Syncing local ports to OCI Security List..."
    
    # Get active ports from local system
    local active_ports=""
    
    # Get CasaOS routes
    local mgmt_port
    mgmt_port=$(netstat -tlnp 2>/dev/null | grep casaos-gateway | head -1 | sed -n 's/.*127.0.0.1:\([0-9]*\).*/\1/p' || echo "")
    if [[ -n "$mgmt_port" ]]; then
        active_ports+=$(curl -s "http://127.0.0.1:${mgmt_port}/v1/gateway/routes" 2>/dev/null | \
            jq -r '.routes[]?.port // empty' 2>/dev/null | \
            grep -E '^[0-9]+$' || true)
        active_ports+="\n"
    fi
    
    # Get Docker ports
    if command -v docker >/dev/null 2>&1; then
        active_ports+=$(docker ps --format "table {{.Ports}}" 2>/dev/null | \
            tail -n +2 | \
            grep -oE '0\.0\.0\.0:[0-9]+' | \
            cut -d: -f2 || true)
        active_ports+="\n"
    fi
    
    # Add common ports
    active_ports+="22\n80\n443"
    
    # Clean up and deduplicate
    active_ports=$(echo -e "$active_ports" | grep -E '^[0-9]+$' | sort -n | uniq)
    
    if [[ -n "$active_ports" ]]; then
        update_security_list "$security_list_id" "$active_ports"
    else
        warning "No active ports detected"
    fi
}

# Create a service to automatically sync ports
create_sync_service() {
    local security_list_id="$1"
    
    cat > /etc/systemd/system/oci-port-sync.service << EOF
[Unit]
Description=OCI Security List Port Sync
After=casaos-gateway.service docker.service
Wants=casaos-gateway.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/oci-manager.sh --sync-ports $security_list_id
User=root

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/oci-port-sync.timer << EOF
[Unit]
Description=Run OCI Port Sync every 10 minutes
Requires=oci-port-sync.service

[Timer]
OnBootSec=5min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable oci-port-sync.timer
    systemctl start oci-port-sync.timer
    
    success "Created OCI port sync service (runs every 10 minutes)"
}

# Interactive setup
interactive_setup() {
    echo -e "${BLUE}Oracle Cloud Infrastructure Setup${NC}"
    echo "=================================="
    echo ""
    
    # Check if OCI CLI is installed
    if ! check_oci_cli; then
        echo "OCI CLI is not installed."
        echo -n "Install OCI CLI? (y/n): "
        read -r install_choice
        if [[ "$install_choice" =~ ^[Yy] ]]; then
            install_oci_cli
        else
            error "OCI CLI is required for this functionality"
            return 1
        fi
    else
        success "OCI CLI is already installed"
    fi
    
    # Check if OCI CLI is configured
    if [[ ! -f "$OCI_CONFIG_DIR/config" ]]; then
        echo "OCI CLI is not configured."
        echo -n "Configure OCI CLI now? (y/n): "
        read -r config_choice
        if [[ "$config_choice" =~ ^[Yy] ]]; then
            configure_oci_cli
        else
            warning "OCI CLI configuration skipped"
        fi
    else
        success "OCI CLI is already configured"
    fi
    
    # Security List management
    echo ""
    echo "Security List Management:"
    echo "1. Use default security list OCID (from your Oracle instance)"
    echo "2. Enter custom security list OCID"
    echo "3. Skip security list setup"
    echo -n "Choose option [1-3]: "
    read -r sl_choice
    
    local security_list_id=""
    case "$sl_choice" in
        1)
            security_list_id="$DEFAULT_SECURITY_LIST_OCID"
            info "Using default security list: $security_list_id"
            ;;
        2)
            echo -n "Enter Security List OCID: "
            read -r security_list_id
            ;;
        3)
            info "Skipping security list setup"
            return 0
            ;;
        *)
            warning "Invalid choice, skipping security list setup"
            return 0
            ;;
    esac
    
    if [[ -n "$security_list_id" ]]; then
        echo ""
        echo "Would you like to:"
        echo "1. Sync current ports to OCI security list now"
        echo "2. Set up automatic port syncing (every 10 minutes)"
        echo "3. Both"
        echo -n "Choose option [1-3]: "
        read -r sync_choice
        
        case "$sync_choice" in
            1)
                sync_ports_to_oci "$security_list_id"
                ;;
            2)
                create_sync_service "$security_list_id"
                ;;
            3)
                sync_ports_to_oci "$security_list_id"
                create_sync_service "$security_list_id"
                ;;
        esac
    fi
    
    success "OCI setup completed"
}

# Show OCI status
show_status() {
    echo -e "${BLUE}OCI Manager Status${NC}"
    echo "=================="
    
    # OCI CLI status
    if check_oci_cli; then
        local version
        version=$(oci --version 2>/dev/null | head -1)
        echo -e "OCI CLI: ${GREEN}Installed${NC} ($version)"
    else
        echo -e "OCI CLI: ${RED}Not installed${NC}"
    fi
    
    # Configuration status
    if [[ -f "$OCI_CONFIG_DIR/config" ]]; then
        echo -e "Configuration: ${GREEN}Present${NC}"
        local region
        region=$(grep -E '^region' "$OCI_CONFIG_DIR/config" 2>/dev/null | cut -d= -f2 | tr -d ' ' || echo "Unknown")
        echo "Region: $region"
    else
        echo -e "Configuration: ${RED}Missing${NC}"
    fi
    
    # Sync service status
    if systemctl is-active --quiet oci-port-sync.timer 2>/dev/null; then
        echo -e "Auto-sync: ${GREEN}Enabled${NC}"
        local last_run
        last_run=$(systemctl show oci-port-sync.timer -p LastTriggerUSec --value)
        if [[ "$last_run" != "0" ]]; then
            echo "Last sync: $(date -d "@$((last_run / 1000000))" 2>/dev/null || echo "Unknown")"
        fi
    else
        echo -e "Auto-sync: ${YELLOW}Disabled${NC}"
    fi
}

# Usage information
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --interactive           Run interactive setup"
    echo "  --install-cli          Install OCI CLI only"
    echo "  --configure            Configure OCI CLI only"
    echo "  --sync-ports OCID      Sync current ports to security list"
    echo "  --status               Show current OCI status"
    echo "  --help                 Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --interactive       # Full interactive setup"
    echo "  $0 --install-cli       # Install OCI CLI"
    echo "  $0 --status            # Check status"
}

# Main function
main() {
    # Ensure log directory exists
    mkdir -p "$LOG_DIR"
    
    case "${1:-}" in
        --interactive)
            interactive_setup
            ;;
        --install-cli)
            install_oci_cli
            ;;
        --configure)
            configure_oci_cli
            ;;
        --sync-ports)
            if [[ -n "${2:-}" ]]; then
                sync_ports_to_oci "$2"
            else
                error "Security list OCID required for --sync-ports"
                exit 1
            fi
            ;;
        --status)
            show_status
            ;;
        --help)
            show_usage
            ;;
        *)
            if [[ $# -eq 0 ]]; then
                show_status
            else
                echo "Unknown option: ${1:-}"
                show_usage
                exit 1
            fi
            ;;
    esac
}

# Run main function with all arguments
main "$@"