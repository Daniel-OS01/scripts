#!/bin/bash

# CasaOS Setup and Diagnostic Script
# URL: https://raw.githubusercontent.com/Daniel-OS01/scripts/refs/heads/main/setup-casaos.sh
# Run with: sudo bash -c "$(wget -qLO - https://raw.githubusercontent.com/Daniel-OS01/scripts/refs/heads/main/setup-casaos.sh)"

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Log configuration
LOG_DIR="/DATA/Documents"
LOG_FILE="${LOG_DIR}/casaos-setup-$(date +%Y%m%d-%H%M%S).log"

# Function to print colored output
print_color() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to log messages
log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    print_color "$CYAN" "[$level] $message"
}

# Function to create log directory
setup_logging() {
    if [[ ! -d "$LOG_DIR" ]]; then
        mkdir -p "$LOG_DIR" 2>/dev/null || {
            LOG_DIR="/tmp"
            LOG_FILE="${LOG_DIR}/casaos-setup-$(date +%Y%m%d-%H%M%S).log"
            print_color "$YELLOW" "Warning: Could not create /DATA/Documents, using /tmp for logs"
        }
    fi
    log_message "INFO" "CasaOS Setup Script Started"
    log_message "INFO" "Log file: $LOG_FILE"
}

# Function to check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_color "$RED" "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Function to display banner
show_banner() {
    print_color "$CYAN" "
╔══════════════════════════════════════════════════════════════╗
║                    CasaOS Setup & Diagnostic Script         ║
║                                                              ║
║  This script helps optimize and diagnose your CasaOS setup  ║
║  Logs are saved to: $LOG_FILE
╚══════════════════════════════════════════════════════════════╝
"
}

# Function to run CasaOS health check
run_healthcheck() {
    log_message "INFO" "Running CasaOS Health Check"
    print_color "$BLUE" "Running BigBearTechWorld CasaOS Health Check..."
    
    if command -v wget >/dev/null 2>&1; then
        bash -c "$(wget -qLO - https://raw.githubusercontent.com/bigbeartechworld/big-bear-scripts/master/casaos-healthcheck/run.sh)" 2>&1 | tee -a "$LOG_FILE"
    elif command -v curl >/dev/null 2>&1; then
        bash -c "$(curl -fsSL https://raw.githubusercontent.com/bigbeartechworld/big-bear-scripts/master/casaos-healthcheck/run.sh)" 2>&1 | tee -a "$LOG_FILE"
    else
        print_color "$RED" "Error: Neither wget nor curl is available"
        log_message "ERROR" "Neither wget nor curl is available for healthcheck"
        return 1
    fi
    
    log_message "INFO" "Health check completed"
    print_color "$GREEN" "Health check completed!"
}

# Function to set up swap
setup_swap() {
    log_message "INFO" "Setting up swap file"
    print_color "$BLUE" "Setting up 2GB swap file..."
    
    # Check if swap already exists
    if swapon --show | grep -q "/swapfile"; then
        print_color "$YELLOW" "Swap file already exists, skipping..."
        log_message "INFO" "Swap file already exists"
        return 0
    fi
    
    # Create swap file
    fallocate -l 2G /swapfile || {
        print_color "$RED" "Failed to create swap file"
        log_message "ERROR" "Failed to create swap file"
        return 1
    }
    
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    
    # Add to fstab if not already there
    if ! grep -q "/swapfile" /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    
    log_message "INFO" "Swap file created and enabled"
    print_color "$GREEN" "2GB swap file created successfully!"
}

# Function to set up log rotation for CasaOS
setup_log_rotation() {
    log_message "INFO" "Setting up CasaOS log rotation"
    print_color "$BLUE" "Setting up CasaOS log rotation..."
    
    cat > /etc/logrotate.d/casaos << 'EOF'
/var/log/casaos/*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
EOF
    
    log_message "INFO" "CasaOS log rotation configured"
    print_color "$GREEN" "Log rotation configured!"
}

# Function to optimize system limits
optimize_system_limits() {
    log_message "INFO" "Optimizing system limits"
    print_color "$BLUE" "Optimizing system resource limits..."
    
    # Increase file descriptor limits
    cat >> /etc/security/limits.conf << 'EOF'

# CasaOS optimizations
* soft nofile 65535
* hard nofile 65535
* soft nproc 65535
* hard nproc 65535
EOF
    
    # Update systemd limits
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/casaos-limits.conf << 'EOF'
[Manager]
DefaultLimitNOFILE=65535
DefaultLimitNPROC=65535
EOF
    
    log_message "INFO" "System limits optimized"
    print_color "$GREEN" "System limits optimized!"
}

# Function to install essential packages
install_essentials() {
    log_message "INFO" "Installing essential packages"
    print_color "$BLUE" "Installing essential packages..."
    
    # Update package list
    apt update >> "$LOG_FILE" 2>&1
    
    # Install essential packages
    local packages=(
        "curl"
        "wget"
        "nano"
        "vim"
        "htop"
        "netcat-openbsd"
        "telnet"
        "traceroute"
        "iptables-persistent"
        "ufw"
        "jq"
        "lm-sensors"
    )
    
    for package in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $package "; then
            print_color "$CYAN" "Installing $package..."
            apt install -y "$package" >> "$LOG_FILE" 2>&1 || {
                print_color "$YELLOW" "Warning: Failed to install $package"
                log_message "WARN" "Failed to install $package"
            }
        else
            print_color "$GREEN" "$package is already installed"
        fi
    done
    
    log_message "INFO" "Essential packages installation completed"
    print_color "$GREEN" "Essential packages installed!"
}

# Function to configure Docker optimization
optimize_docker() {
    log_message "INFO" "Optimizing Docker configuration"
    print_color "$BLUE" "Optimizing Docker configuration..."
    
    # Create Docker daemon configuration
    mkdir -p /etc/docker
    
    cat > /etc/docker/daemon.json << 'EOF'
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    },
    "storage-driver": "overlay2",
    "live-restore": true
}
EOF
    
    # Restart Docker service
    systemctl restart docker || {
        print_color "$YELLOW" "Warning: Failed to restart Docker"
        log_message "WARN" "Failed to restart Docker service"
    }
    
    log_message "INFO" "Docker optimization completed"
    print_color "$GREEN" "Docker optimized!"
}

# Function to configure time synchronization
setup_ntp() {
    log_message "INFO" "Configuring time synchronization"
    print_color "$BLUE" "Setting up NTP synchronization for Israel timezone..."
    
    # Configure systemd-timesyncd for Israel
    sed -i 's|#NTP=|NTP=0.il.pool.ntp.org 1.il.pool.ntp.org 2.il.pool.ntp.org 3.il.pool.ntp.org|' /etc/systemd/timesyncd.conf
    
    # Set timezone to Israel
    timedatectl set-timezone Asia/Jerusalem
    
    # Enable and restart timesyncd
    systemctl enable systemd-timesyncd
    systemctl restart systemd-timesyncd
    
    log_message "INFO" "NTP synchronization configured for Israel"
    print_color "$GREEN" "Time synchronization configured!"
}

# Function to show firewall information
show_firewall_info() {
    print_color "$BLUE" "Current Firewall Status:"
    print_color "$CYAN" "========================"
    
    # Show UFW status
    print_color "$YELLOW" "UFW Status:"
    ufw status verbose
    
    print_color "$YELLOW" "\nIPTables INPUT Chain:"
    iptables -L INPUT -n --line-numbers
    
    print_color "$YELLOW" "\nCasaOS Gateway Listening Ports:"
    ss -tlnp | grep casaos-gateway
    
    print_color "$CYAN" "\nNote: The following ports are commonly used by CasaOS apps:"
    echo "22, 25, 80, 143, 443, 465, 587, 993, 995, 3306, 6379, 6380"
    echo "8000-8010, 8070, 8071, 8080, 8083, 8123, 8443, 8800-8889"
    echo "9000-9010, 9081, 9440-9460, 9443, 9993, 10180, 10300"
    echo "23000, 23119, 2375, 3200-3220, 42613, 5678"
    echo ""
    echo "Consider opening these ports manually based on your needs:"
    echo "sudo iptables -I INPUT 5 -p tcp --dport PORT_NUMBER -j ACCEPT"
    echo "sudo netfilter-persistent save"
}

# Function to create system info summary
create_system_summary() {
    log_message "INFO" "Creating system summary"
    local summary_file="${LOG_DIR}/system-summary-$(date +%Y%m%d-%H%M%S).txt"
    
    {
        echo "CasaOS System Summary - $(date)"
        echo "================================"
        echo ""
        echo "System Information:"
        echo "-------------------"
        lsb_release -a 2>/dev/null || echo "OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'=' -f2 | tr -d '\"')"
        echo "Kernel: $(uname -r)"
        echo "Uptime: $(uptime -p)"
        echo "Memory: $(free -h | grep Mem: | awk '{print $2" total, "$3" used, "$7" available"}')"
        echo "Disk Usage: $(df -h / | tail -1 | awk '{print $5" used of "$2}')"
        echo ""
        echo "CasaOS Services:"
        echo "----------------"
        systemctl is-active casaos casaos-gateway casaos-user-service casaos-local-storage casaos-app-management 2>/dev/null || echo "Some services may not be available"
        echo ""
        echo "Network Configuration:"
        echo "----------------------"
        echo "IP Address: $(hostname -I | awk '{print $1}')"
        echo "Listening on port 80: $(ss -tlnp | grep :80 | grep -q casaos && echo "Yes" || echo "No")"
        echo ""
        echo "Docker Status:"
        echo "--------------"
        docker --version 2>/dev/null || echo "Docker not available"
        echo "Running containers: $(docker ps --format "table {{.Names}}" 2>/dev/null | tail -n +2 | wc -l || echo "0")"
    } > "$summary_file"
    
    print_color "$GREEN" "System summary saved to: $summary_file"
}

# Main menu
show_menu() {
    while true; do
        clear
        show_banner
        print_color "$BLUE" "Please select an option:"
        echo ""
        echo "1) Run CasaOS Health Check (Diagnostic)"
        echo "2) Install Essential Packages"
        echo "3) Setup Swap File (2GB)"
        echo "4) Configure Log Rotation"
        echo "5) Optimize System Limits"
        echo "6) Optimize Docker Configuration"
        echo "7) Setup NTP for Israel Timezone"
        echo "8) Show Firewall Information"
        echo "9) Create System Summary"
        echo "10) Run All Optimizations (2-7)"
        echo "0) Exit"
        echo ""
        read -p "Enter your choice [0-10]: " choice
        
        case $choice in
            1)
                run_healthcheck
                read -p "Press Enter to continue..."
                ;;
            2)
                install_essentials
                read -p "Press Enter to continue..."
                ;;
            3)
                setup_swap
                read -p "Press Enter to continue..."
                ;;
            4)
                setup_log_rotation
                read -p "Press Enter to continue..."
                ;;
            5)
                optimize_system_limits
                read -p "Press Enter to continue..."
                ;;
            6)
                optimize_docker
                read -p "Press Enter to continue..."
                ;;
            7)
                setup_ntp
                read -p "Press Enter to continue..."
                ;;
            8)
                show_firewall_info
                read -p "Press Enter to continue..."
                ;;
            9)
                create_system_summary
                read -p "Press Enter to continue..."
                ;;
            10)
                print_color "$BLUE" "Running all optimizations..."
                install_essentials
                setup_swap
                setup_log_rotation
                optimize_system_limits
                optimize_docker
                setup_ntp
                print_color "$GREEN" "All optimizations completed!"
                read -p "Press Enter to continue..."
                ;;
            0)
                log_message "INFO" "Script execution completed"
                print_color "$GREEN" "Script completed. Logs saved to: $LOG_FILE"
                exit 0
                ;;
            *)
                print_color "$RED" "Invalid option. Please try again."
                sleep 2
                ;;
        esac
    done
}

# Main execution
main() {
    check_root
    setup_logging
    show_menu
}

# Trap to log script exit
trap 'log_message "INFO" "Script terminated"' EXIT

# Run main function
main "$@"
