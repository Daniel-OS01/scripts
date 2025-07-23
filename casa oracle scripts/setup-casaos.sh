#!/bin/bash
# CasaOS Auto-Port Management Setup Script
# https://raw.githubusercontent.com/Daniel-OS01/scripts/refs/heads/main/setup-casaos.sh
# Version: 1.0

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Logging setup
LOG_DIR="/DATA/Documents"
LOG_FILE="$LOG_DIR/casaos-setup-$(date +%Y%m%d-%H%M%S).log"

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Error handling
error_exit() {
    log "ERROR" "$1"
    echo -e "${RED}ERROR: $1${NC}" >&2
    exit 1
}

# Success message
success() {
    log "INFO" "$1"
    echo -e "${GREEN}✓ $1${NC}"
}

# Warning message
warning() {
    log "WARN" "$1"
    echo -e "${YELLOW}⚠ $1${NC}"
}

# Info message
info() {
    log "INFO" "$1"
    echo -e "${BLUE}ℹ $1${NC}"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root. Use: sudo $0"
    fi
}

# Banner
show_banner() {
    echo -e "${BOLD}${BLUE}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════════╗
║                    CasaOS Setup & Management                  ║
║                   Auto-Port & OCI Integration                 ║
║                                                               ║
║  • Auto-open ports for CasaOS apps                          ║
║  • Oracle Cloud Infrastructure integration                   ║
║  • System optimization & diagnostics                        ║
║                                                               ║
║  Log Location: /DATA/Documents/                              ║
╚═══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# Download helper scripts
download_scripts() {
    local base_url="https://raw.githubusercontent.com/Daniel-OS01/scripts/refs/heads/main"
    local scripts=(
        "casaos-port-monitor.sh"
        "oci-manager.sh"
        "casaos-diagnostics.sh"
    )
    
    info "Downloading required scripts..."
    
    for script in "${scripts[@]}"; do
        if curl -fsSL "$base_url/$script" -o "/usr/local/bin/$script"; then
            chmod +x "/usr/local/bin/$script"
            success "Downloaded and installed $script"
        else
            error_exit "Failed to download $script"
        fi
    done
}

# Install required packages
install_requirements() {
    info "Installing required packages..."
    
    # Update package list
    apt update -qq
    
    # Install essential packages
    local packages=(
        "curl"
        "wget"
        "jq"
        "netcat-openbsd"
        "iptables-persistent"
        "systemd"
    )
    
    for package in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $package "; then
            info "Installing $package..."
            apt install -y "$package"
        else
            success "$package already installed"
        fi
    done
}

# Configure swap
configure_swap() {
    if ! swapon --show | grep -q "/swapfile"; then
        info "Creating 2GB swap file..."
        fallocate -l 2G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        success "Swap file created and enabled"
    else
        success "Swap already configured"
    fi
}

# Configure log rotation
configure_log_rotation() {
    info "Setting up log rotation for CasaOS..."
    
    cat > /etc/logrotate.d/casaos << 'EOF'
/var/log/casaos/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    su root root
}

/DATA/Documents/casaos-*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    su root root
}
EOF
    
    success "Log rotation configured"
}

# Open common CasaOS ports
open_casaos_ports() {
    info "Opening common CasaOS ports in iptables..."
    
    local ports=(
        22 80 443 3306 8000 8001 8080 8083 8123 8443
        9000 9001 9005 9081 9443 9993 10180 10300
        23000 23119 2375 3002 5678 6379 6380 42613
    )
    
    # Get current line number before REJECT rule
    local reject_line=$(iptables -L INPUT --line-numbers | grep "reject-with icmp-host-prohibited" | head -1 | awk '{print $1}')
    
    if [[ -n "$reject_line" ]]; then
        for port in "${ports[@]}"; do
            # Check if rule already exists
            if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
                iptables -I INPUT "$reject_line" -p tcp --dport "$port" -j ACCEPT
                info "Opened port $port"
            fi
        done
        
        # Save iptables rules
        netfilter-persistent save
        success "Firewall rules saved"
    else
        warning "Could not find REJECT rule in iptables. Ports may already be open."
    fi
}

# Main menu
show_menu() {
    echo -e "\n${BOLD}${BLUE}Select features to configure:${NC}\n"
    echo "1) Auto-Port Monitor (Monitor CasaOS apps and auto-open ports)"
    echo "2) Oracle Cloud Infrastructure Manager (OCI CLI + Security Lists)"
    echo "3) System Optimization (Swap, Log Rotation, etc.)"
    echo "4) Open Common CasaOS Ports (Manual firewall setup)"
    echo "5) Run Diagnostics (BigBear CasaOS Health Check)"
    echo "6) Install All Features"
    echo "7) Exit"
    echo ""
}

# Handle menu selection
handle_selection() {
    local choice="$1"
    
    case $choice in
        1)
            info "Setting up Auto-Port Monitor..."
            /usr/local/bin/casaos-port-monitor.sh --install
            ;;
        2)
            info "Setting up OCI Manager..."
            /usr/local/bin/oci-manager.sh --interactive
            ;;
        3)
            info "Applying system optimizations..."
            configure_swap
            configure_log_rotation
            success "System optimization complete"
            ;;
        4)
            info "Opening common CasaOS ports..."
            open_casaos_ports
            ;;
        5)
            info "Running diagnostics..."
            /usr/local/bin/casaos-diagnostics.sh
            ;;
        6)
            info "Installing all features..."
            configure_swap
            configure_log_rotation
            open_casaos_ports
            /usr/local/bin/casaos-port-monitor.sh --install
            /usr/local/bin/oci-manager.sh --interactive
            success "All features installed successfully!"
            ;;
        7)
            info "Exiting..."
            exit 0
            ;;
        *)
            warning "Invalid selection. Please try again."
            ;;
    esac
}

# Main execution
main() {
    show_banner
    check_root
    
    info "Starting CasaOS setup - Log: $LOG_FILE"
    
    # Install requirements and download scripts
    install_requirements
    download_scripts
    
    # Interactive menu loop
    while true; do
        show_menu
        echo -n "Enter your choice [1-7]: "
        read -r choice
        echo ""
        
        handle_selection "$choice"
        
        if [[ "$choice" != "7" ]]; then
            echo ""
            echo -e "${YELLOW}Press Enter to continue...${NC}"
            read -r
        fi
    done
}

# Trap errors and cleanup
trap 'error_exit "Script interrupted"' INT TERM

# Run main function
main "$@"
