#!/bin/bash
# Enhanced OCI Ingress Manager for CasaOS ports with better error handling

set -euo pipefail

LOG"
LOG_FILE="$LOG_DIR/oci-manager-$(date +%Y%m%d-%H%M%S).log"
OCI_CONFIG="$HOME/.oci/config"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log(){
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

info(){
    log "INFO: $*"
    echo -e "${BLUE}ℹ $*${NC}"
}

success(){
    log "OK: $*"
    echo -e "${GREEN}✓ $*${NC}"
}

error(){
    log "ERROR: $*"
    echo -e "${RED}✗ $*${NC}" >&2
}

warning(){
    log "WARNING: $*"
    echo -e "${YELLOW}⚠ $*${NC}"
}

# Function to run OCI commands with proper error handling
run_oci_command(){
    local cmd="$*"
    local output
    local exit_code
    
    info "Running: oci $cmd"
    log "COMMAND: oci $cmd"
    
    # Capture both stdout and stderr, and get exit code
    output=$(oci $cmd --debug 2>&1) || exit_code=$?
    
    if [[ ${exit_code:-0} -eq 0 ]]; then
        success "Command completed successfully"
        log "OUTPUT: $output"
        echo "$output"
        return 0
    else
        error "Command failed with exit code: ${exit_code:-0}"
        log "FAILED OUTPUT: $output"
        
        # Try to extract meaningful error from the output
        if echo "$output" | grep -q "ServiceError"; then
            local error_msg
            error_msg=$(echo "$output" | grep -A 10 "ServiceError" | grep '"message"' | sed 's/.*"message": "\([^"]*\)".*/\1/')
            if [[ -n "$error_msg" ]]; then
                error "Service Error: $error_msg"
            fi
        fi
        
        if echo "$output" | grep -q "NotAuthenticated\|NotAuthorized"; then
            error "Authentication/Authorization issue detected"
            warning "Please check your OCI CLI configuration and permissions"
        fi
        
        echo "$output" >&2
        return ${exit_code:-1}
    fi
}

update_security_list(){
    local sl_ocid="$1"
    local ports="$2"
    
    info "Updating OCI Security List: $sl_ocid"
    log "Ports to configure: $ports"
    
    # Build the ingress rules JSON
    local ingress_rules
    ingress_rules=$(build_ingress_rules "$ports")
    
    # Create temporary file for the rules
    local temp_file
    temp_file=$(mktemp)
    echo "$ingress_rules" > "$temp_file"
    
    log "Ingress rules JSON written to: $temp_file"
    log "Rules content: $(cat "$temp_file")"
    
    # First, get existing egress rules to preserve them
    info "Getting existing security list configuration..."
    local existing_config
    if ! existing_config=$(run_oci_command "network security-list get --security-list-id \"$sl_ocid\""); then
        error "Failed to get existing security list configuration"
        rm -f "$temp_file"
        return 1
    fi
    
    # Extract existing egress rules
    local egress_rules
    egress_rules=$(echo "$existing_config" | jq '.data."egress-security-rules"' 2>/dev/null || echo '[]')
    
    # Create egress rules file
    local egress_file
    egress_file=$(mktemp)
    echo "$egress_rules" > "$egress_file"
    
    log "Existing egress rules preserved in: $egress_file"
    
    # Update the security list with both ingress and egress rules
    if run_oci_command "network security-list update --security-list-id \"$sl_ocid\" --ingress-security-rules file://\"$temp_file\" --egress-security-rules file://\"$egress_file\" --force"; then
        success "Security list updated successfully"
        rm -f "$temp_file" "$egress_file"
        return 0
    else
        error "Failed to update security list"
        error "Ingress rules file: $temp_file (preserved for debugging)"
        error "Egress rules file: $egress_file (preserved for debugging)"
        log "Failed ingress rules content: $(cat "$temp_file")"
        log "Failed egress rules content: $(cat "$egress_file")"
        return 1
    fi
}
