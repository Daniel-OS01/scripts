#!/bin/bash
# CasaOS Diagnostics Runner
# Runs BigBear CasaOS Health Check and additional diagnostics
# Version: 1.0

set -euo pipefail

# Configuration
LOG_DIR="/DATA/Documents"
LOG_FILE="$LOG_DIR/casaos-diagnostics-$(date +%Y%m%d-%H%M%S).log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

# Logging
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

info() { log "INFO" "$@"; echo -e "${BLUE}ℹ $*${NC}"; }
error() { log "ERROR" "$@"; echo -e "${RED}ERROR: $*${NC}" >&2; }
success() { log "INFO" "$@"; echo -e "${GREEN}✓ $*${NC}"; }
warning() { log "WARN" "$@"; echo -e "${YELLOW}⚠ $*${NC}"; }

# Banner
show_banner() {
    echo -e "${BOLD}${BLUE}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════════╗
║                    CasaOS Diagnostics Suite                  ║
║                                                               ║
║  • BigBear CasaOS Health Check                              ║
║  • System Status & Performance                              ║
║  • Network & Port Analysis                                  ║
║  • Docker & Container Status                                ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# Run BigBear CasaOS Health Check
run_bigbear_healthcheck() {
    info "Running BigBear CasaOS Health Check..."
    echo -e "${BLUE}========================================${NC}"
    
    # Download and run the BigBear health check
    bash -c "$(wget -qLO - https://raw.githubusercontent.com/bigbeartechworld/big-bear-scripts/master/casaos-healthcheck/run.sh)" | tee -a "$LOG_FILE"
    
    success "BigBear health check completed"
}

# Additional system diagnostics
run_system_diagnostics() {
    info "Running additional system diagnostics..."
    echo -e "${BLUE}========================================${NC}"
    
    # System Information
    echo -e "\n${BOLD}System Information:${NC}"
    echo "Hostname: $(hostname)"
    echo "Uptime: $(uptime -p)"
    echo "Load Average: $(cat /proc/loadavg | awk '{print $1, $2, $3}')"
    echo "Memory Usage: $(free -h | grep '^Mem:' | awk '{print $3"/"$2" ("$3/$2*100"%)"}')"
    echo "Disk Usage: $(df -h / | tail -1 | awk '{print $3"/"$2" ("$5")"}')"
    
    # Network Information
    echo -e "\n${BOLD}Network Information:${NC}"
    local ip_addr=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' | head -1)
    echo "Primary IP: ${ip_addr:-"Unknown"}"
    echo "DNS Servers: $(grep nameserver /etc/resolv.conf | awk '{print $2}' | tr '\n' ' ')"
    
    # Check internet connectivity
    if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        success "Internet connectivity: OK"
    else
        error "Internet connectivity: FAILED"
    fi
    
    # Port Analysis
    echo -e "\n${BOLD}Open Ports Analysis:${NC}"
    local listening_ports
    listening_ports=$(ss -tlnp | grep LISTEN | awk '{print $4}' | cut -d: -f2 | sort -n | uniq | head -20)
    echo "Currently listening ports (first 20):"
    echo "$listening_ports" | sed 's/^/  /'
    
    # CasaOS Specific Checks
    echo -e "\n${BOLD}CasaOS Status:${NC}"
    
    # Check CasaOS services
    local casaos_services=(
        "casaos.service"
        "casaos-gateway.service"
        "casaos-user-service.service"
        "casaos-local-storage.service"
        "casaos-app-management.service"
        "casaos-message-bus.service"
    )
    
    for service in "${casaos_services[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            success "$service: Running"
        else
            error "$service: Not running"
        fi
    done
    
    # Check Docker status
    echo -e "\n${BOLD}Docker Status:${NC}"
    if command -v docker >/dev/null 2>&1; then
        if docker info >/dev/null 2>&1; then
            local container_count
            container_count=$(docker ps -q | wc -l)
            success "Docker: Running ($container_count containers)"
            
            if [[ $container_count -gt 0 ]]; then
                echo "Running containers:"
                docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | sed 's/^/  /'
            fi
        else
            error "Docker: Service not running"
        fi
    else
        warning "Docker: Not installed"
    fi
    
    # Auto-Port Monitor Status
    echo -e "\n${BOLD}Auto-Port Monitor:${NC}"
    if systemctl is-active --quiet casaos-port-monitor.service 2>/dev/null; then
        success "Auto-Port Monitor: Running"
        
        # Show current monitored ports
        local state_file="/var/run/casaos-port-monitor.state"
        if [[ -f "$state_file" ]]; then
            local monitored_ports
            monitored_ports=$(cat "$state_file" | tr '\n' ' ')
            echo "Monitored ports: $monitored_ports"
        fi
    else
        warning "Auto-Port Monitor: Not running"
    fi
    
    # OCI Integration Status
    echo -e "\n${BOLD}OCI Integration:${NC}"
    if command -v oci >/dev/null 2>&1; then
        success "OCI CLI: Installed"
        
        if [[ -f "$HOME/.oci/config" ]]; then
            success "OCI Configuration: Present"
        else
            warning "OCI Configuration: Missing"
        fi
        
        if systemctl is-active --quiet oci-port-sync.timer 2>/dev/null; then
            success "OCI Auto-sync: Enabled"
        else
            warning "OCI Auto-sync: Disabled"
        fi
    else
        warning "OCI CLI: Not installed"
    fi
    
    # Security Analysis
    echo -e "\n${BOLD}Security Analysis:${NC}"
    
    # Check for open ports to internet
    local dangerous_ports=("22" "3306" "6379" "2375")
    for port in "${dangerous_ports[@]}"; do
        if ss -tlnp | grep -q ":$port "; then
            if iptables -L INPUT -n | grep -q "tcp dpt:$port.*ACCEPT"; then
                warning "Port $port is open and accessible"
            else
                info "Port $port is listening but firewalled"
            fi
        fi
    done
    
    # Check SSH configuration
    if [[ -f "/etc/ssh/sshd_config" ]]; then
        local root_login
        root_login=$(grep -E "^PermitRootLogin" /etc/ssh/sshd_config | awk '{print $2}' || echo "unknown")
        local password_auth
        password_auth=$(grep -E "^PasswordAuthentication" /etc/ssh/sshd_config | awk '{print $2}' || echo "unknown")
        
        echo "SSH Root Login: $root_login"
        echo "SSH Password Auth: $password_auth"
        
        if [[ "$root_login" == "yes" ]]; then
            warning "SSH root login is enabled"
        fi
        
        if [[ "$password_auth" == "yes" ]]; then
            warning "SSH password authentication is enabled"
        fi
    fi
    
    success "Additional diagnostics completed"
}

# Generate summary report
generate_summary() {
    info "Generating diagnostic summary..."
    
    local summary_file="$LOG_DIR/casaos-diagnostic-summary-$(date +%Y%m%d-%H%M%S).txt"
    
    cat > "$summary_file" << EOF
CasaOS Diagnostic Summary
Generated: $(date)
Host: $(hostname)
IP: $(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' | head -1 || echo "Unknown")

=== Service Status ===
EOF
    
    # Check services and add to summary
    local services=(
        "casaos.service"
        "casaos-gateway.service"
        "docker.service"
        "casaos-port-monitor.service"
    )
    
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            echo "$service: ✓ Running" >> "$summary_file"
        else
            echo "$service: ✗ Stopped" >> "$summary_file"
        fi
    done
    
    cat >> "$summary_file" << EOF

=== Network Status ===
EOF
    
    # Network tests
    if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        echo "Internet Connectivity: ✓ OK" >> "$summary_file"
    else
        echo "Internet Connectivity: ✗ FAILED" >> "$summary_file"
    fi
    
    local open_ports
    open_ports=$(ss -tlnp | grep LISTEN | wc -l)
    echo "Listening Ports: $open_ports" >> "$summary_file"
    
    cat >> "$summary_file" << EOF

=== Integration Status ===
EOF
    
    # Check integrations
    if command -v oci >/dev/null 2>&1; then
        echo "OCI CLI: ✓ Installed" >> "$summary_file"
    else
        echo "OCI CLI: ✗ Not installed" >> "$summary_file"
    fi
    
    if [[ -f "/var/run/casaos-port-monitor.state" ]]; then
        local port_count
        port_count=$(cat /var/run/casaos-port-monitor.state | wc -l)
        echo "Auto-Port Monitor: ✓ Active ($port_count ports)" >> "$summary_file"
    else
        echo "Auto-Port Monitor: ✗ Inactive" >> "$summary_file"
    fi
    
    echo "" >> "$summary_file"
    echo "Full log: $LOG_FILE" >> "$summary_file"
    
    success "Summary saved to: $summary_file"
    
    # Display summary
    echo -e "\n${BOLD}Diagnostic Summary:${NC}"
    cat "$summary_file"
}

# Test connectivity to specific services
test_connectivity() {
    info "Testing service connectivity..."
    
    # Test CasaOS web interface
    local casaos_ip
    casaos_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' | head -1)
    
    if [[ -n "$casaos_ip" ]]; then
        if curl -s --connect-timeout 5 "http://$casaos_ip" >/dev/null; then
            success "CasaOS web interface: Accessible at http://$casaos_ip"
        else
            error "CasaOS web interface: Not accessible"
        fi
    fi
    
    # Test Docker API
    if command -v docker >/dev/null 2>&1; then
        if docker version >/dev/null 2>&1; then
            success "Docker API: Accessible"
        else
            error "Docker API: Not accessible"
        fi
    fi
    
    # Test CasaOS Gateway API
    local mgmt_port
    mgmt_port=$(netstat -tlnp 2>/dev/null | grep casaos-gateway | head -1 | sed -n 's/.*127.0.0.1:\([0-9]*\).*/\1/p' || echo "")
    if [[ -n "$mgmt_port" ]]; then
        if curl -s --connect-timeout 5 "http://127.0.0.1:$mgmt_port/v1/gateway/routes" >/dev/null; then
            success "CasaOS Gateway API: Accessible (port $mgmt_port)"
        else
            error "CasaOS Gateway API: Not responding"
        fi
    else
        warning "CasaOS Gateway API: Management port not found"
    fi
}

# Cleanup old logs
cleanup_logs() {
    info "Cleaning up old diagnostic logs..."
    
    # Remove logs older than 30 days
    find "$LOG_DIR" -name "casaos-diagnostics-*.log" -type f -mtime +30 -delete 2>/dev/null || true
    find "$LOG_DIR" -name "casaos-diagnostic-summary-*.txt" -type f -mtime +30 -delete 2>/dev/null || true
    
    success "Log cleanup completed"
}

# Usage information
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --full              Run full diagnostic suite (default)"
    echo "  --bigbear-only      Run only BigBear health check"
    echo "  --system-only       Run only additional system diagnostics"
    echo "  --connectivity      Test service connectivity"
    echo "  --summary           Generate summary report only"
    echo "  --cleanup           Clean up old diagnostic logs"
    echo "  --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                  # Run full diagnostics"
    echo "  $0 --bigbear-only   # Run BigBear check only"
    echo "  $0 --connectivity   # Test connectivity"
}

# Main function
main() {
    # Ensure log directory exists
    mkdir -p "$LOG_DIR"
    
    show_banner
    info "Starting CasaOS diagnostics - Log: $LOG_FILE"
    
    case "${1:---full}" in
        --full)
            run_bigbear_healthcheck
            echo ""
            run_system_diagnostics
            echo ""
            test_connectivity
            echo ""
            generate_summary
            cleanup_logs
            ;;
        --bigbear-only)
            run_bigbear_healthcheck
            ;;
        --system-only)
            run_system_diagnostics
            ;;
        --connectivity)
            test_connectivity
            ;;
        --summary)
            generate_summary
            ;;
        --cleanup)
            cleanup_logs
            ;;
        --help)
            show_usage
            ;;
        *)
            echo "Unknown option: ${1:-}"
            show_usage
            exit 1
            ;;
    esac
    
    echo ""
    success "All diagnostics completed. Log saved to: $LOG_FILE"
}

# Run main function with all arguments
main "$@"