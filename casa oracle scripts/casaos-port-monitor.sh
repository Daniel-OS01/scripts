#!/bin/bash
# CasaOS Auto-Port Monitor
# Monitors Docker containers and CasaOS Gateway for new applications
# Automatically opens iptables ports for new services
# Version: 1.0

set -euo pipefail

# Configuration
LOG_DIR="/DATA/Documents"
LOG_FILE="$LOG_DIR/casaos-port-monitor-$(date +%Y%m%d).log"
STATE_FILE="/var/run/casaos-port-monitor.state"
SERVICE_FILE="/etc/systemd/system/casaos-port-monitor.service"
CHAIN_NAME="CASAOS-AUTO-PORTS"

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

# Get CasaOS Gateway management port
get_casaos_management_port() {
    local mgmt_file="/var/run/casaos/management.url"
    if [[ -f "$mgmt_file" ]]; then
        cut -d: -f3 < "$mgmt_file" 2>/dev/null || echo ""
    else
        # Fallback: try to find from netstat
        netstat -tlnp 2>/dev/null | grep casaos-gateway | head -1 | sed -n 's/.*127.0.0.1:\([0-9]*\).*/\1/p' || echo ""
    fi
}

# Get registered routes from CasaOS Gateway
get_casaos_routes() {
    local mgmt_port=$(get_casaos_management_port)
    if [[ -n "$mgmt_port" ]]; then
        curl -s "http://127.0.0.1:${mgmt_port}/v1/gateway/routes" 2>/dev/null | \
            jq -r '.routes[]?.port // empty' 2>/dev/null | \
            grep -E '^[0-9]+$' | sort -n | uniq || true
    fi
}

# Get Docker container ports
get_docker_ports() {
    if command -v docker >/dev/null 2>&1; then
        docker ps --format "table {{.Ports}}" 2>/dev/null | \
            tail -n +2 | \
            grep -oE '0\.0\.0\.0:[0-9]+' | \
            cut -d: -f2 | \
            sort -n | uniq || true
    fi
}

# Get all active ports that should be opened
get_active_ports() {
    {
        get_casaos_routes
        get_docker_ports
        # Always include CasaOS gateway port
        echo "80"
        echo "443"
    } | grep -E '^[0-9]+$' | sort -n | uniq
}

# Initialize iptables chain
init_iptables_chain() {
    # Create custom chain if it doesn't exist
    if ! iptables -n -L "$CHAIN_NAME" >/dev/null 2>&1; then
        iptables -N "$CHAIN_NAME"
        info "Created iptables chain: $CHAIN_NAME"
    fi
    
    # Check if we have a jump rule to our chain in INPUT
    if ! iptables -C INPUT -j "$CHAIN_NAME" 2>/dev/null; then
        # Find the line number before the REJECT rule
        local reject_line=$(iptables -L INPUT --line-numbers | grep "reject-with icmp-host-prohibited" | head -1 | awk '{print $1}')
        if [[ -n "$reject_line" ]]; then
            iptables -I INPUT "$reject_line" -j "$CHAIN_NAME"
            info "Added jump rule to $CHAIN_NAME chain"
        else
            # No reject rule found, append at the end
            iptables -A INPUT -j "$CHAIN_NAME"
            info "Appended jump rule to $CHAIN_NAME chain"
        fi
    fi
}

# Update iptables rules
update_iptables() {
    local new_ports="$1"
    
    init_iptables_chain
    
    # Flush the custom chain
    iptables -F "$CHAIN_NAME"
    
    # Add rules for each port
    while IFS= read -r port; do
        if [[ -n "$port" && "$port" =~ ^[0-9]+$ ]]; then
            iptables -A "$CHAIN_NAME" -p tcp --dport "$port" -j ACCEPT
            info "Added iptables rule for port $port"
        fi
    done <<< "$new_ports"
    
    # Add return rule at the end
    iptables -A "$CHAIN_NAME" -j RETURN
    
    # Save iptables rules
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1
        info "Saved iptables rules"
    fi
}

# Read previous state
read_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    fi
}

# Write current state
write_state() {
    local ports="$1"
    echo "$ports" > "$STATE_FILE"
}

# Monitor and update ports
monitor_ports() {
    local current_ports
    current_ports=$(get_active_ports)
    local previous_ports
    previous_ports=$(read_state)
    
    if [[ "$current_ports" != "$previous_ports" ]]; then
        info "Port configuration changed, updating iptables..."
        info "New ports: $(echo "$current_ports" | tr '\n' ' ')"
        
        update_iptables "$current_ports"
        write_state "$current_ports"
        
        success "Port monitoring updated successfully"
    else
        info "No port changes detected"
    fi
}

# Create systemd service
create_service() {
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=CasaOS Auto-Port Monitor
After=casaos-gateway.service docker.service
Wants=casaos-gateway.service

[Service]
Type=simple
ExecStart=/usr/local/bin/casaos-port-monitor.sh --daemon
Restart=always
RestartSec=30
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    success "Created systemd service"
}

# Install the monitoring service
install_service() {
    info "Installing CasaOS Auto-Port Monitor service..."
    
    # Ensure log directory exists
    mkdir -p "$LOG_DIR"
    
    # Create the service
    create_service
    
    # Enable and start the service
    systemctl enable casaos-port-monitor.service
    systemctl start casaos-port-monitor.service
    
    success "Auto-Port Monitor service installed and started"
    info "View logs with: journalctl -u casaos-port-monitor.service -f"
    info "View port monitoring log: tail -f $LOG_FILE"
}

# Daemon mode
run_daemon() {
    info "Starting CasaOS Auto-Port Monitor daemon..."
    
    # Initial port setup
    monitor_ports
    
    # Monitor loop
    while true; do
        sleep 60  # Check every minute
        monitor_ports
    done
}

# Show current status
show_status() {
    echo -e "${BLUE}CasaOS Auto-Port Monitor Status${NC}"
    echo "================================"
    
    # Service status
    if systemctl is-active --quiet casaos-port-monitor.service 2>/dev/null; then
        echo -e "Service Status: ${GREEN}Running${NC}"
    else
        echo -e "Service Status: ${RED}Stopped${NC}"
    fi
    
    # Current ports
    local current_ports
    current_ports=$(get_active_ports)
    echo "Currently monitored ports:"
    echo "$current_ports" | sed 's/^/  /'
    
    # CasaOS Gateway status
    local mgmt_port
    mgmt_port=$(get_casaos_management_port)
    if [[ -n "$mgmt_port" ]]; then
        echo -e "CasaOS Gateway: ${GREEN}Running${NC} (management port: $mgmt_port)"
    else
        echo -e "CasaOS Gateway: ${YELLOW}Not detected${NC}"
    fi
    
    # Docker status
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        local docker_containers
        docker_containers=$(docker ps -q | wc -l)
        echo -e "Docker: ${GREEN}Running${NC} ($docker_containers containers)"
    else
        echo -e "Docker: ${YELLOW}Not running${NC}"
    fi
    
    # Iptables chain status
    if iptables -n -L "$CHAIN_NAME" >/dev/null 2>&1; then
        local rules_count
        rules_count=$(iptables -n -L "$CHAIN_NAME" | grep -c "tcp dpt:" || echo "0")
        echo -e "Iptables Chain: ${GREEN}Configured${NC} ($rules_count port rules)"
    else
        echo -e "Iptables Chain: ${RED}Not configured${NC}"
    fi
}

# Remove the service
uninstall_service() {
    info "Uninstalling CasaOS Auto-Port Monitor..."
    
    if systemctl is-active --quiet casaos-port-monitor.service 2>/dev/null; then
        systemctl stop casaos-port-monitor.service
    fi
    
    if systemctl is-enabled --quiet casaos-port-monitor.service 2>/dev/null; then
        systemctl disable casaos-port-monitor.service
    fi
    
    if [[ -f "$SERVICE_FILE" ]]; then
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
    fi
    
    # Clean up iptables chain
    if iptables -n -L "$CHAIN_NAME" >/dev/null 2>&1; then
        # Remove jump rule from INPUT chain
        iptables -D INPUT -j "$CHAIN_NAME" 2>/dev/null || true
        # Flush and delete the custom chain
        iptables -F "$CHAIN_NAME" 2>/dev/null || true
        iptables -X "$CHAIN_NAME" 2>/dev/null || true
    fi
    
    # Remove state file
    rm -f "$STATE_FILE"
    
    success "Auto-Port Monitor service uninstalled"
}

# Usage information
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --install       Install and start the auto-port monitoring service"
    echo "  --uninstall     Remove the auto-port monitoring service"
    echo "  --daemon        Run in daemon mode (used by systemd service)"
    echo "  --status        Show current monitoring status"
    echo "  --monitor       Run port monitoring once and exit"
    echo "  --help          Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --install    # Install the monitoring service"
    echo "  $0 --status     # Check current status"
    echo "  $0 --monitor    # Run monitoring once"
}

# Main function
main() {
    case "${1:-}" in
        --install)
            install_service
            ;;
        --uninstall)
            uninstall_service
            ;;
        --daemon)
            run_daemon
            ;;
        --status)
            show_status
            ;;
        --monitor)
            monitor_ports
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

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Run main function with all arguments
main "$@"