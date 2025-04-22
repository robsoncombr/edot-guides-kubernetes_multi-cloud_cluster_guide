#!/bin/bash

# ============================================================================
# diagnosis.sh - Comprehensive Diagnosis Script for Kubernetes Multi-Cloud Cluster
# ============================================================================
# 
# DESCRIPTION:
#   This script performs comprehensive diagnostics on a Kubernetes multi-cloud
#   cluster, including network connectivity, SSH access, VPN status, Kubernetes
#   services, DNS resolution, and overall cluster health.
#
# USAGE:
#   ./diagnosis.sh [--verbose] [--report] [--mode=full|basic|network|services]
#
# OPTIONS:
#   --verbose        Show detailed output for all checks
#   --report         Generate an HTML report of all diagnostics
#   --mode=MODE      Run specific diagnostic mode:
#                      full     - Run all diagnostics (default)
#                      basic    - Run only essential checks
#                      network  - Focus on network connectivity
#                      services - Focus on Kubernetes services
#
# ============================================================================

set -e

# Script base directory
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

# Import environment configuration
source "${SCRIPT_DIR}/0100-Chapter_1/001-Environment_Config.sh" > /dev/null 2>&1 || {
    echo "Error: Environment configuration not found or contains errors"
    exit 1
}

# Default configuration
VERBOSE=false
GENERATE_REPORT=false
DIAGNOSTIC_MODE="full"
LOG_DIR="${SCRIPT_DIR}/logs"
REPORT_FILE="${LOG_DIR}/diagnosis-report-$(date +%Y%m%d-%H%M%S).html"
TEMP_LOG_FILE="/tmp/k8s-diagnosis-$$.log"
TIMEOUT_SECONDS=5
EMAIL_ALERTS=false
EMAIL_RECIPIENT=""

# Parse arguments
for arg in "$@"; do
    case $arg in
        --verbose)
            VERBOSE=true
            shift
            ;;
        --report)
            GENERATE_REPORT=true
            shift
            ;;
        --mode=*)
            DIAGNOSTIC_MODE="${arg#*=}"
            shift
            ;;
        --email=*)
            EMAIL_ALERTS=true
            EMAIL_RECIPIENT="${arg#*=}"
            shift
            ;;
        --help)
            echo "Usage: $0 [--verbose] [--report] [--mode=full|basic|network|services] [--email=recipient@example.com]"
            echo ""
            echo "Options:"
            echo "  --verbose                 Show detailed output for all checks"
            echo "  --report                  Generate an HTML report of all diagnostics"
            echo "  --mode=MODE               Run specific diagnostic mode:"
            echo "                              full     - Run all diagnostics (default)"
            echo "                              basic    - Run only essential checks"
            echo "                              network  - Focus on network connectivity and VPN interfaces"
            echo "                              services - Focus on Kubernetes services"
            echo "  --email=EMAIL             Send report to specified email"
            echo ""
            echo "Network diagnostics include VPN and WireGuard interface checks, which are critical"
            echo "for multi-cloud Kubernetes deployments using VPN for inter-node communication."
            echo ""
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# Print banner
clear
echo "======================================================================"
echo "               KUBERNETES MULTI-CLOUD CLUSTER DIAGNOSIS                "
echo "======================================================================"
echo ""
echo "Running diagnostic mode: $DIAGNOSTIC_MODE"
echo "Verbose mode: $(if $VERBOSE; then echo "Enabled"; else echo "Disabled"; fi)"
echo "Report generation: $(if $GENERATE_REPORT; then echo "Enabled (${REPORT_FILE})"; else echo "Disabled"; fi)"
echo ""

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Log function
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    case "$level" in
        "INFO")
            local color="\e[32m" # Green
            ;;
        "WARNING")
            local color="\e[33m" # Yellow
            ;;
        "ERROR")
            local color="\e[31m" # Red
            ;;
        "SUCCESS")
            local color="\e[32;1m" # Bright Green
            ;;
        *)
            local color="\e[0m" # Default
            ;;
    esac
    
    if [[ "$VERBOSE" == "true" || "$level" != "INFO" || "$message" == *"SUMMARY"* ]]; then
        echo -e "${color}[${timestamp}] [${level}] ${message}\e[0m"
    fi
    
    # Log to temp file for report generation
    echo "[${timestamp}] [${level}] ${message}" >> "$TEMP_LOG_FILE"
}

# Section header
section_header() {
    local title="$1"
    echo ""
    echo "======================================================================"
    echo "  $title"
    echo "======================================================================"
    log "INFO" "SECTION: $title"
}

# Check result function
check_result() {
    local name="$1"
    local result="$2"
    local details="$3"
    
    if [[ "$result" == "PASS" ]]; then
        log "SUCCESS" "✅ $name: $result"
        if [[ -n "$details" && "$VERBOSE" == "true" ]]; then
            echo "   $details"
        fi
    elif [[ "$result" == "WARNING" ]]; then
        log "WARNING" "⚠️ $name: $result - $details"
    else
        log "ERROR" "❌ $name: $result - $details"
    fi
}

# Function to execute remote commands with timeout
remote_command() {
    local host="$1"
    local command="$2"
    local timeout="$TIMEOUT_SECONDS"
    
    log "INFO" "Executing on $host: $command"
    
    # Run command with timeout
    timeout "$timeout" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 \
        -o BatchMode=yes -o LogLevel=quiet "$host" "$command" 2>/dev/null
    
    return $?
}

# Function to check if required tools are installed
check_required_tools() {
    section_header "REQUIRED TOOLS CHECK"
    
    log "INFO" "Checking for required diagnostic tools on all cluster nodes..."
    
    # Required tools to check for
    local tools_list=("kubectl" "ssh" "ping" "nc" "ip" "nslookup" "dig" "netstat" "ss" "curl" "jq" "timeout" "strace" "bc")
    local nodes_with_missing_tools=()
    local all_missing_tools=()
    local missing_tools_by_node=()
    
    # Get the current hostname
    local current_hostname=$(hostname)
    log "INFO" "Current hostname: $current_hostname"
    
    # Check local machine first
    log "INFO" "Checking for required tools on local machine..."
    local local_missing_tools=()
    
    for tool in "${tools_list[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            local_missing_tools+=("$tool")
            all_missing_tools+=("$tool")
            
            # Log the missing tool
            log "WARNING" "Missing required tool on local machine: $tool"
        fi
    done
    
    if [[ ${#local_missing_tools[@]} -gt 0 ]]; then
        missing_tools_by_node+=("local:${local_missing_tools[*]}")
        nodes_with_missing_tools+=("local")
    else
        log "SUCCESS" "All required diagnostic tools are available on local machine"
    fi
    
    # Check each node in the cluster if we have the node list
    if [[ -n "${ALL_NODES[*]}" ]]; then
        for NODE_CONFIG in "${ALL_NODES[@]}"; do
            local NODE_NAME=$(get_node_property "$NODE_CONFIG" 0)
            local NODE_IP=$(get_node_property "$NODE_CONFIG" 1)
            
            # Skip if this is the local machine (already checked)
            if [[ "$NODE_NAME" == "$current_hostname" ]]; then
                log "INFO" "Skipping $NODE_NAME as it's the local machine (already checked)"
                continue
            fi
            
            log "INFO" "Checking for required tools on $NODE_NAME ($NODE_IP)..."
            local node_missing_tools=()
            
            # Skip if we can't SSH to the node
            if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -o BatchMode=yes -o LogLevel=quiet \
                "$NODE_IP" "echo SSH connection successful" &>/dev/null; then
                log "ERROR" "Cannot SSH to $NODE_NAME ($NODE_IP) - skipping tool check"
                continue
            fi
            
            # Check for each required tool
            for tool in "${tools_list[@]}"; do
                if ! remote_command "$NODE_IP" "command -v $tool" &>/dev/null; then
                    node_missing_tools+=("$tool")
                    
                    # Add to all_missing_tools if not already there
                    if [[ ! " ${all_missing_tools[*]} " =~ " ${tool} " ]]; then
                        all_missing_tools+=("$tool")
                    fi
                    
                    # Log the missing tool
                    log "WARNING" "Missing required tool on $NODE_NAME: $tool"
                fi
            done
            
            if [[ ${#node_missing_tools[@]} -gt 0 ]]; then
                missing_tools_by_node+=("$NODE_NAME:${node_missing_tools[*]}")
                nodes_with_missing_tools+=("$NODE_NAME")
            else
                log "SUCCESS" "All required diagnostic tools are available on $NODE_NAME"
            fi
        done
    fi
    
    # If any tools are missing anywhere, offer to install them
    if [[ ${#all_missing_tools[@]} -gt 0 ]]; then
        log "WARNING" "Found missing required tools across the cluster: ${all_missing_tools[*]}"
        
        # Display a summary of which tools are missing on which nodes
        echo "Summary of missing tools by node:"
        for node_info in "${missing_tools_by_node[@]}"; do
            echo " - $node_info"
        done
        
        # Ask for confirmation before installing
        read -p "Would you like to install the missing tools on all nodes? (y/n): " -r confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            log "INFO" "Proceeding with installation of missing tools..."
            
            # Get the current hostname
            local current_hostname=$(hostname)
            
            # Install locally if needed and if hostname matches required target
            if [[ " ${nodes_with_missing_tools[*]} " =~ " local " ]]; then
                # Check if the current hostname matches any of the node names requiring installation
                local should_install_local=false
                for NODE_CONFIG in "${ALL_NODES[@]}"; do
                    local NODE_NAME=$(get_node_property "$NODE_CONFIG" 0)
                    if [[ "$NODE_NAME" == "$current_hostname" ]]; then
                        should_install_local=true
                        break
                    fi
                done
                
                if [[ "$should_install_local" == "true" ]]; then
                    log "INFO" "Installing missing tools on local machine (hostname: $current_hostname)..."
                    
                    # Get local OS type
                    local os_type
                    os_type=$(cat /etc/os-release | grep -E '^ID=' | cut -d'=' -f2 | tr -d '"')
                    
                    if [[ "$os_type" == "ubuntu" || "$os_type" == "debian" ]]; then
                        log "INFO" "Detected Debian/Ubuntu - using apt-get..."
                        apt-get update -qq
                        apt-get install -y -qq dnsutils net-tools curl iputils-ping netcat-openbsd iproute2 jq procps strace bc
                    elif [[ "$os_type" == "centos" || "$os_type" == "rhel" || "$os_type" == "fedora" ]]; then
                        log "INFO" "Detected RHEL/CentOS/Fedora - using yum..."
                        yum install -y bind-utils net-tools curl iputils nc iproute jq procps-ng strace bc
                    else
                        log "WARNING" "Unknown OS type: $os_type. Attempting to use apt-get..."
                        apt-get update -qq
                        apt-get install -y -qq dnsutils net-tools curl iputils-ping netcat-openbsd iproute2 jq procps strace bc
                    fi
                    
                    # Check again
                    local still_missing=()
                    for tool in "${local_missing_tools[@]}"; do
                        if ! command -v "$tool" &>/dev/null; then
                            still_missing+=("$tool")
                        fi
                    done
                    
                    if [[ ${#still_missing[@]} -gt 0 ]]; then
                        log "ERROR" "Could not install on local machine: ${still_missing[*]}"
                    else
                        log "SUCCESS" "Successfully installed all missing tools on local machine"
                    fi
                fi
            fi
            
            # Install on remote nodes
            for node in "${nodes_with_missing_tools[@]}"; do
                # Skip local machine (already handled)
                if [[ "$node" == "local" ]]; then
                    continue
                fi
                
                # Find the IP for this node
                local node_ip=""
                for NODE_CONFIG in "${ALL_NODES[@]}"; do
                    local NODE_NAME=$(get_node_property "$NODE_CONFIG" 0)
                    if [[ "$NODE_NAME" == "$node" ]]; then
                        node_ip=$(get_node_property "$NODE_CONFIG" 1)
                        break
                    fi
                done
                
                # Skip if we couldn't find the IP
                if [[ -z "$node_ip" ]]; then
                    log "ERROR" "Could not find IP for node $node - skipping tool installation"
                    continue
                fi
                
                # Skip if we can't SSH to the node
                if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -o BatchMode=yes -o LogLevel=quiet \
                    "$node_ip" "echo SSH connection successful" &>/dev/null; then
                    log "ERROR" "Cannot SSH to $node ($node_ip) - skipping tool installation"
                    continue
                fi
                
                log "INFO" "Installing missing tools on $node..."
                
                # Try to detect OS and use appropriate package manager
                local os_type
                os_type=$(remote_command "$node_ip" "cat /etc/os-release | grep -E '^ID=' | cut -d'=' -f2 | tr -d '\"'" 2>/dev/null)
                
                if [[ "$os_type" == "ubuntu" || "$os_type" == "debian" ]]; then
                    log "INFO" "Detected Debian/Ubuntu on $node - using apt-get..."
                    remote_command "$node_ip" "apt-get update -qq && apt-get install -y -qq dnsutils net-tools curl iputils-ping netcat-openbsd iproute2 jq procps strace bc" 2>/dev/null
                elif [[ "$os_type" == "centos" || "$os_type" == "rhel" || "$os_type" == "fedora" ]]; then
                    log "INFO" "Detected RHEL/CentOS/Fedora on $node - using yum..."
                    remote_command "$node_ip" "yum install -y bind-utils net-tools curl iputils nc iproute jq procps-ng strace bc" 2>/dev/null
                else
                    log "WARNING" "Unknown OS on $node: $os_type. Attempting to use apt-get..."
                    remote_command "$node_ip" "apt-get update -qq && apt-get install -y -qq dnsutils net-tools curl iputils-ping netcat-openbsd iproute2 jq procps strace bc" 2>/dev/null
                fi
                
                # Get the list of missing tools for this node
                local node_tools=""
                for node_info in "${missing_tools_by_node[@]}"; do
                    if [[ "$node_info" == "$node:"* ]]; then
                        node_tools="${node_info#*:}"
                        break
                    fi
                done
                
                # Verify installation
                local node_still_missing=()
                IFS=' ' read -ra node_missing_array <<< "$node_tools"
                
                for tool in "${node_missing_array[@]}"; do
                    if ! remote_command "$node_ip" "command -v $tool" &>/dev/null; then
                        node_still_missing+=("$tool")
                    fi
                done
                
                if [[ ${#node_still_missing[@]} -gt 0 ]]; then
                    log "ERROR" "Could not install on $node: ${node_still_missing[*]}"
                else
                    log "SUCCESS" "Successfully installed all missing tools on $node"
                fi
            done
        else
            log "WARNING" "Skipping installation of missing tools. Some diagnostics may not function correctly."
            # List explicitly which tools will be missing for which functions
            if [[ " ${all_missing_tools[*]} " =~ " strace " ]]; then
                log "WARNING" "Missing 'strace' will prevent detailed process debugging and syscall analysis"
            fi
            if [[ " ${all_missing_tools[*]} " =~ " curl " ]]; then
                log "WARNING" "Missing 'curl' will prevent API endpoint testing and HTTP diagnostics"
            fi
            if [[ " ${all_missing_tools[*]} " =~ " dig " || " ${all_missing_tools[*]} " =~ " nslookup " ]]; then
                log "WARNING" "Missing DNS tools will prevent thorough DNS diagnostics"
            fi
        fi
    else
        log "SUCCESS" "All required diagnostic tools are available on all nodes"
    fi
    
    # Final check - are we good to go?
    local recheck_missing=false
    
    # Recheck if any tools are still missing
    for node in "${nodes_with_missing_tools[@]}"; do
        if [[ "$node" == "local" ]]; then
            for tool in "${local_missing_tools[@]}"; do
                if ! command -v "$tool" &>/dev/null; then
                    recheck_missing=true
                    break
                fi
            done
        else
            # Find the IP for this node
            local node_ip=""
            for NODE_CONFIG in "${ALL_NODES[@]}"; do
                local NODE_NAME=$(get_node_property "$NODE_CONFIG" 0)
                if [[ "$NODE_NAME" == "$node" ]]; then
                    node_ip=$(get_node_property "$NODE_CONFIG" 1)
                    break
                fi
            done
            
            # Get the list of missing tools for this node
            local node_tools=""
            for node_info in "${missing_tools_by_node[@]}"; do
                if [[ "$node_info" == "$node:"* ]]; then
                    node_tools="${node_info#*:}"
                    break
                fi
            done
            
            # Check if any tools are still missing
            IFS=' ' read -ra node_missing_array <<< "$node_tools"
            for tool in "${node_missing_array[@]}"; do
                if ! remote_command "$node_ip" "command -v $tool" &>/dev/null; then
                    recheck_missing=true
                    break
                fi
            done
        fi
        
        if [[ "$recheck_missing" == "true" ]]; then
            break
        fi
    done
    
    if [[ "$recheck_missing" == "true" ]]; then
        check_result "Required Tools" "WARNING" "Some nodes are still missing required tools. Some diagnostics may be incomplete."
        return 1
    else
        check_result "Required Tools" "PASS" "All required diagnostic tools are available on all nodes"
        return 0
    fi
}

# ============================================================================
# NETWORK DIAGNOSTICS
# ============================================================================

# Function to check basic host connectivity
check_node_connectivity() {
    section_header "NODE CONNECTIVITY"
    
    local failed_nodes=()
    local ping_failures=0
    local ssh_failures=0
    
    log "INFO" "Checking connectivity to all cluster nodes..."
    
    # Process each node from environment config
    for NODE_CONFIG in "${ALL_NODES[@]}"; do
        # Extract node information
        local NODE_NAME=$(get_node_property "$NODE_CONFIG" 0)
        local NODE_IP=$(get_node_property "$NODE_CONFIG" 1)
        local NODE_ROLE=$(get_node_property "$NODE_CONFIG" 4)
        
        log "INFO" "Checking connectivity to $NODE_NAME ($NODE_IP)..."
        
        # Check ping
        if ping -c 3 -W 2 "$NODE_IP" &>/dev/null; then
            log "SUCCESS" "Ping to $NODE_NAME ($NODE_IP) successful"
        else
            log "ERROR" "Ping to $NODE_NAME ($NODE_IP) failed"
            ping_failures=$((ping_failures + 1))
            failed_nodes+=("$NODE_NAME:ping")
        fi
        
        # Check SSH
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -o BatchMode=yes -o LogLevel=quiet \
            "$NODE_IP" "echo SSH connection successful" &>/dev/null; then
            log "SUCCESS" "SSH to $NODE_NAME ($NODE_IP) successful"
        else
            log "ERROR" "SSH to $NODE_NAME ($NODE_IP) failed"
            ssh_failures=$((ssh_failures + 1))
            failed_nodes+=("$NODE_NAME:ssh")
        fi
    done
    
    # Summary
    if [[ $ping_failures -eq 0 && $ssh_failures -eq 0 ]]; then
        check_result "Node Connectivity" "PASS" "All nodes are reachable"
    else
        check_result "Node Connectivity" "FAIL" "Failed connections to: ${failed_nodes[*]}"
    fi
}

# Function to check VPN status across all nodes
check_vpn_status() {
    section_header "VPN STATUS"
    
    log "INFO" "Checking VPN connectivity across all cluster nodes..."
    local vpn_failures=0
    local failed_nodes=()
    
    # Check VPN interfaces on each node
    for NODE_CONFIG in "${ALL_NODES[@]}"; do
        local NODE_NAME=$(get_node_property "$NODE_CONFIG" 0)
        local NODE_IP=$(get_node_property "$NODE_CONFIG" 1)
        
        log "INFO" "Checking VPN interface on $NODE_NAME ($NODE_IP)..."
        
        # Check if VPN interface exists and has an IP address
        local vpn_output
        vpn_output=$(remote_command "$NODE_IP" "ip a | grep -E 'wg[0-9]+|tun[0-9]+|tap[0-9]+'" 2>/dev/null)
        
        if [[ -n "$vpn_output" ]]; then
            log "SUCCESS" "VPN interface found on $NODE_NAME: $vpn_output"
            
            # Verify interface has an IP address in our expected range
            if [[ "$vpn_output" =~ inet\ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
                local vpn_ip="${BASH_REMATCH[1]}"
                log "SUCCESS" "VPN IP on $NODE_NAME: $vpn_ip"
                
                # Verify if this IP matches what we expect from environment config
                if [[ "$vpn_ip" != "$NODE_IP" ]]; then
                    log "WARNING" "VPN IP ($vpn_ip) does not match expected IP ($NODE_IP) in config"
                fi
            else
                log "ERROR" "VPN interface on $NODE_NAME exists but has no IP address"
                vpn_failures=$((vpn_failures + 1))
                failed_nodes+=("$NODE_NAME:no-vpn-ip")
            fi
        else
            log "ERROR" "No VPN interface found on $NODE_NAME"
            vpn_failures=$((vpn_failures + 1))
            failed_nodes+=("$NODE_NAME:no-vpn")
        fi
    done
    
    # Summary
    if [[ $vpn_failures -eq 0 ]]; then
        check_result "VPN Status" "PASS" "VPN is properly configured on all nodes"
    else
        check_result "VPN Status" "FAIL" "VPN issues on nodes: ${failed_nodes[*]}"
    fi
}

# Check network latency between nodes
check_inter_node_latency() {
    section_header "INTER-NODE NETWORK LATENCY"
    
    log "INFO" "Measuring network latency between all cluster nodes..."
    local high_latency_count=0
    local latency_issues=()
    
    # Define an acceptable threshold for latency (in ms)
    local LATENCY_THRESHOLD=100
    
    # Test latency between each pair of nodes
    for source_config in "${ALL_NODES[@]}"; do
        local SOURCE_NAME=$(get_node_property "$source_config" 0)
        local SOURCE_IP=$(get_node_property "$source_config" 1)
        
        for target_config in "${ALL_NODES[@]}"; do
            local TARGET_NAME=$(get_node_property "$target_config" 0)
            local TARGET_IP=$(get_node_property "$target_config" 1)
            
            # Skip if source and target are the same
            if [[ "$SOURCE_IP" == "$TARGET_IP" ]]; then
                continue
            fi
            
            log "INFO" "Measuring latency from $SOURCE_NAME to $TARGET_NAME..."
            
            # Run ping test
            local ping_result
            ping_result=$(remote_command "$SOURCE_IP" "ping -c 5 -q $TARGET_IP" 2>/dev/null)
            
            # Extract average latency
            if [[ "$ping_result" =~ rtt\ min/avg/max.*=\ [0-9.]+/([0-9.]+)/[0-9.]+ ]]; then
                local avg_latency="${BASH_REMATCH[1]}"
                
                # Check if latency is above threshold
                if (( $(echo "$avg_latency > $LATENCY_THRESHOLD" | bc -l) )); then
                    log "WARNING" "High latency from $SOURCE_NAME to $TARGET_NAME: ${avg_latency}ms"
                    high_latency_count=$((high_latency_count + 1))
                    latency_issues+=("$SOURCE_NAME→$TARGET_NAME:${avg_latency}ms")
                else
                    log "SUCCESS" "Good latency from $SOURCE_NAME to $TARGET_NAME: ${avg_latency}ms"
                fi
            else
                log "ERROR" "Failed to measure latency from $SOURCE_NAME to $TARGET_NAME"
                high_latency_count=$((high_latency_count + 1))
                latency_issues+=("$SOURCE_NAME→$TARGET_NAME:failed")
            fi
        done
    done
    
    # Summary
    if [[ $high_latency_count -eq 0 ]]; then
        check_result "Inter-Node Latency" "PASS" "All node-to-node latency is below ${LATENCY_THRESHOLD}ms"
    else
        check_result "Inter-Node Latency" "WARNING" "High latency detected: ${latency_issues[*]}"
    fi
}

# Function to check network MTU consistency
check_network_mtu() {
    section_header "NETWORK MTU CONSISTENCY"
    
    log "INFO" "Checking MTU consistency across all cluster nodes..."
    local mtu_issues=0
    local mtu_variations=()
    local interface_mtus=()
    
    # Check MTU on each node's main network interface
    for NODE_CONFIG in "${ALL_NODES[@]}"; do
        local NODE_NAME=$(get_node_property "$NODE_CONFIG" 0)
        local NODE_IP=$(get_node_property "$NODE_CONFIG" 1)
        local NODE_INTERFACE=$(get_node_property "$NODE_CONFIG" 3)
        
        log "INFO" "Checking MTU on $NODE_NAME ($NODE_IP) interface $NODE_INTERFACE..."
        
        # Get MTU for specific interface
        local mtu_output
        mtu_output=$(remote_command "$NODE_IP" "ip link show $NODE_INTERFACE | grep mtu" 2>/dev/null)
        
        if [[ "$mtu_output" =~ mtu\ ([0-9]+) ]]; then
            local mtu="${BASH_REMATCH[1]}"
            log "SUCCESS" "MTU on $NODE_NAME interface $NODE_INTERFACE: $mtu"
            interface_mtus+=("$NODE_NAME:$NODE_INTERFACE:$mtu")
        else
            log "ERROR" "Could not determine MTU on $NODE_NAME interface $NODE_INTERFACE"
            mtu_issues=$((mtu_issues + 1))
            mtu_variations+=("$NODE_NAME:unknown")
        fi
    done
    
    # Check MTUs for consistency
    local reference_mtu=""
    local inconsistent=false
    
    for mtu_info in "${interface_mtus[@]}"; do
        local mtu_value=$(echo "$mtu_info" | cut -d':' -f3)
        
        if [[ -z "$reference_mtu" ]]; then
            reference_mtu="$mtu_value"
        elif [[ "$mtu_value" != "$reference_mtu" ]]; then
            inconsistent=true
            mtu_variations+=("$mtu_info")
        fi
    done
    
    # Summary
    if [[ $mtu_issues -eq 0 && "$inconsistent" == "false" ]]; then
        check_result "Network MTU" "PASS" "All nodes have consistent MTU ($reference_mtu)"
    else
        check_result "Network MTU" "WARNING" "MTU inconsistencies detected: ${mtu_variations[*]}"
    fi
}

# Function to check WireGuard interface MTU consistency
check_wireguard_mtu() {
    section_header "WIREGUARD MTU CONSISTENCY"
    
    log "INFO" "Checking WireGuard (wg0) interface MTU across all cluster nodes..."
    local wg_issues=0
    local wg_mtu_variations=()
    local wg_interface_mtus=()
    local wg_missing=0
    
    # Check WireGuard MTU on each node
    for NODE_CONFIG in "${ALL_NODES[@]}"; do
        local NODE_NAME=$(get_node_property "$NODE_CONFIG" 0)
        local NODE_IP=$(get_node_property "$NODE_CONFIG" 1)
        
        log "INFO" "Checking WireGuard interface on $NODE_NAME ($NODE_IP)..."
        
        # Check if WireGuard interface exists and get its MTU
        local wg_output
        wg_output=$(remote_command "$NODE_IP" "ip link show wg0 2>/dev/null | grep mtu" 2>/dev/null)
        
        if [[ -n "$wg_output" ]]; then
            if [[ "$wg_output" =~ mtu\ ([0-9]+) ]]; then
                local wg_mtu="${BASH_REMATCH[1]}"
                log "SUCCESS" "WireGuard MTU on $NODE_NAME: $wg_mtu"
                wg_interface_mtus+=("$NODE_NAME:wg0:$wg_mtu")
                
                # Get full WireGuard status if verbose mode is enabled
                if [[ "$VERBOSE" == "true" ]]; then
                    local full_wg_status
                    full_wg_status=$(remote_command "$NODE_IP" "wg show wg0" 2>/dev/null)
                    if [[ -n "$full_wg_status" ]]; then
                        log "INFO" "WireGuard status on $NODE_NAME:\n$full_wg_status"
                    fi
                fi
            else
                log "ERROR" "Could not determine WireGuard MTU on $NODE_NAME"
                wg_issues=$((wg_issues + 1))
            fi
        else
            log "ERROR" "No WireGuard interface (wg0) found on $NODE_NAME"
            wg_missing=$((wg_missing + 1))
            wg_issues=$((wg_issues + 1))
        fi
    done
    
    # Check if WireGuard MTUs are consistent across nodes
    local reference_wg_mtu=""
    local inconsistent_wg=false
    
    for wg_mtu_info in "${wg_interface_mtus[@]}"; do
        local wg_mtu_value=$(echo "$wg_mtu_info" | cut -d':' -f3)
        
        if [[ -z "$reference_wg_mtu" ]]; then
            reference_wg_mtu="$wg_mtu_value"
        elif [[ "$wg_mtu_value" != "$reference_wg_mtu" ]]; then
            inconsistent_wg=true
            wg_mtu_variations+=("$wg_mtu_info")
        fi
    done
    
    # Summary and recommendations
    if [[ $wg_missing -eq ${#ALL_NODES[@]} ]]; then
        check_result "WireGuard Interface" "FAIL" "WireGuard (wg0) interface not found on any nodes"
    elif [[ $wg_issues -eq 0 && "$inconsistent_wg" == "false" ]]; then
        check_result "WireGuard MTU" "PASS" "All nodes have consistent WireGuard MTU ($reference_wg_mtu)"
        
        # Check if MTU is optimal (typically 1420 for WireGuard over standard Internet)
        if [[ "$reference_wg_mtu" -lt 1380 || "$reference_wg_mtu" -gt 1460 ]]; then
            log "WARNING" "WireGuard MTU ($reference_wg_mtu) is outside the typical range (1380-1460)"
            log "INFO" "Recommended WireGuard MTU is typically 1420 (standard MTU 1500 - WireGuard overhead)"
        fi
    else
        if [[ "$inconsistent_wg" == "true" ]]; then
            check_result "WireGuard MTU" "WARNING" "Inconsistent WireGuard MTU across nodes: ${wg_mtu_variations[*]}"
            log "INFO" "Recommended action: Set consistent WireGuard MTU (typically 1420) across all nodes"
        else
            check_result "WireGuard MTU" "WARNING" "Issues with WireGuard interface on some nodes"
        fi
    fi
}

# Function to check DNS resolution
check_dns_resolution() {
    section_header "DNS RESOLUTION"
    
    log "INFO" "Checking DNS resolution on all cluster nodes..."
    local dns_failures=0
    local failed_dns=()
    
    # Test domains to check - include internal and external domains
    local test_domains=("kubernetes.default.svc.cluster.local" "google.com" "github.com")
    
    # Check DNS resolution on each node
    for NODE_CONFIG in "${ALL_NODES[@]}"; do
        local NODE_NAME=$(get_node_property "$NODE_CONFIG" 0)
        local NODE_IP=$(get_node_property "$NODE_CONFIG" 1)
        
        log "INFO" "Checking DNS resolution on $NODE_NAME ($NODE_IP)..."
        
        # Check resolv.conf to see what nameservers are configured
        local dns_config
        dns_config=$(remote_command "$NODE_IP" "cat /etc/resolv.conf | grep nameserver" 2>/dev/null)
        log "INFO" "DNS configuration on $NODE_NAME: $dns_config"
        
        # Check if kube-dns/CoreDNS is working (only applies to running clusters)
        if kubectl get service -n kube-system kube-dns &>/dev/null || \
           kubectl get service -n kube-system coredns &>/dev/null; then
            log "INFO" "Kubernetes DNS service is running in cluster"
            test_domains+=("kubernetes.default" "kubernetes.default.svc")
        fi
        
        # Test resolution of each domain
        for domain in "${test_domains[@]}"; do
            log "INFO" "Testing resolution of $domain on $NODE_NAME..."
            
            local dns_result
            dns_result=$(remote_command "$NODE_IP" "nslookup $domain" 2>/dev/null)
            
            if [[ "$dns_result" == *"Address:"*  ]]; then
                log "SUCCESS" "Successfully resolved $domain on $NODE_NAME"
            else
                log "ERROR" "Failed to resolve $domain on $NODE_NAME"
                dns_failures=$((dns_failures + 1))
                failed_dns+=("$NODE_NAME:$domain")
            fi
        done
    done
    
    # Summary
    if [[ $dns_failures -eq 0 ]]; then
        check_result "DNS Resolution" "PASS" "DNS resolution working properly on all nodes"
    else
        check_result "DNS Resolution" "FAIL" "DNS resolution issues: ${failed_dns[*]}"
    fi
}

# Function to check all network connectivity
check_network() {
    section_header "COMPREHENSIVE NETWORK CHECKS"
    
    check_node_connectivity
    check_vpn_status
    check_inter_node_latency
    check_network_mtu
    check_wireguard_mtu
    check_dns_resolution
    
    log "INFO" "Network diagnostics completed"
}

# ============================================================================
# KUBERNETES SERVICE DIAGNOSTICS
# ============================================================================

# Function to check Kubernetes component status
check_kubernetes_components() {
    section_header "KUBERNETES COMPONENT STATUS"
    
    log "INFO" "Checking status of Kubernetes components..."
    
    # Check if we have access to the Kubernetes API
    if ! kubectl version &>/dev/null; then
        log "ERROR" "Cannot access Kubernetes API - skipping component checks"
        check_result "Kubernetes API" "FAIL" "Cannot access Kubernetes API"
        return 1
    fi
    
    log "SUCCESS" "Kubernetes API is accessible"
    
    # Check control plane components
    log "INFO" "Checking control plane pods..."
    local cp_issues=0
    local failed_cp_components=()
    
    for component in "kube-apiserver" "kube-controller-manager" "kube-scheduler" "etcd"; do
        local pod_status
        pod_status=$(kubectl get pods -n kube-system -l component="$component" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
        
        if [[ "$pod_status" == "Running" ]]; then
            log "SUCCESS" "Control plane component $component is running"
        else
            log "ERROR" "Control plane component $component is not running (status: $pod_status)"
            cp_issues=$((cp_issues + 1))
            failed_cp_components+=("$component:$pod_status")
        fi
    done
    
    # Check CoreDNS and kube-proxy
    log "INFO" "Checking CoreDNS and kube-proxy..."
    local addon_issues=0
    local failed_addons=()
    
    for addon in "coredns" "kube-proxy"; do
        local addon_pods
        addon_pods=$(kubectl get pods -n kube-system -l k8s-app="$addon" -o jsonpath='{.items[*].status.phase}' 2>/dev/null)
        
        if [[ "$addon_pods" == *"Running"* ]]; then
            log "SUCCESS" "Addon component $addon is running"
        else
            log "ERROR" "Addon component $addon is not running properly (status: $addon_pods)"
            addon_issues=$((addon_issues + 1))
            failed_addons+=("$addon:$addon_pods")
        fi
    done
    
    # Check CNI (Flannel)
    log "INFO" "Checking CNI (Flannel)..."
    local cni_pods
    cni_pods=$(kubectl get pods -n kube-flannel -o jsonpath='{.items[*].status.phase}' 2>/dev/null)
    
    if [[ "$cni_pods" == *"Running"* ]]; then
        log "SUCCESS" "CNI pods are running"
    else
        log "ERROR" "CNI pods are not running properly (status: $cni_pods)"
        addon_issues=$((addon_issues + 1))
        failed_addons+=("flannel:$cni_pods")
    fi
    
    # Summary
    if [[ $cp_issues -eq 0 && $addon_issues -eq 0 ]]; then
        check_result "Kubernetes Components" "PASS" "All components are running"
    else
        local failed_components=("${failed_cp_components[@]}" "${failed_addons[@]}")
        check_result "Kubernetes Components" "FAIL" "Issues with components: ${failed_components[*]}"
    fi
}

# Function to check node status
check_node_status() {
    section_header "KUBERNETES NODE STATUS"
    
    log "INFO" "Checking status of Kubernetes nodes..."
    
    # Check if we have access to the Kubernetes API
    if ! kubectl version &>/dev/null; then
        log "ERROR" "Cannot access Kubernetes API - skipping node status checks"
        check_result "Node Status" "FAIL" "Cannot access Kubernetes API"
        return 1
    fi
    
    # Get node info
    local nodes_json
    nodes_json=$(kubectl get nodes -o json)
    
    # Count total nodes
    local node_count
    node_count=$(echo "$nodes_json" | jq '.items | length')
    log "INFO" "Cluster has $node_count nodes"
    
    # Check ready status
    local ready_count
    ready_count=$(echo "$nodes_json" | jq '[.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True"))] | length')
    
    # Check not ready nodes
    local not_ready=()
    local not_ready_nodes
    not_ready_nodes=$(echo "$nodes_json" | jq -r '.items[] | select(.status.conditions[] | select(.type=="Ready" and .status!="True")) | .metadata.name')
    
    if [[ -n "$not_ready_nodes" ]]; then
        readarray -t not_ready <<<"$not_ready_nodes"
    fi
    
    # Check node conditions
    local problem_nodes=()
    
    for condition in "DiskPressure" "MemoryPressure" "PIDPressure" "NetworkUnavailable"; do
        local problem_node_list
        problem_node_list=$(echo "$nodes_json" | jq -r ".items[] | select(.status.conditions[] | select(.type==\"$condition\" and .status==\"True\")) | .metadata.name")
        
        if [[ -n "$problem_node_list" ]]; then
            readarray -t nodes_with_condition <<<"$problem_node_list"
            for node in "${nodes_with_condition[@]}"; do
                problem_nodes+=("$node:$condition")
            done
        fi
    done
    
    # Check resource capacity and allocatable
    log "INFO" "Checking node resource allocation..."
    
    local nodes_with_low_resources=()
    local node_names
    node_names=$(echo "$nodes_json" | jq -r '.items[].metadata.name')
    
    for node in $node_names; do
        local cpu_capacity
        local cpu_allocatable
        local memory_capacity
        local memory_allocatable
        
        cpu_capacity=$(echo "$nodes_json" | jq -r ".items[] | select(.metadata.name==\"$node\") | .status.capacity.cpu")
        cpu_allocatable=$(echo "$nodes_json" | jq -r ".items[] | select(.metadata.name==\"$node\") | .status.allocatable.cpu")
        memory_capacity=$(echo "$nodes_json" | jq -r ".items[] | select(.metadata.name==\"$node\") | .status.capacity.memory")
        memory_allocatable=$(echo "$nodes_json" | jq -r ".items[] | select(.metadata.name==\"$node\") | .status.allocatable.memory")
        
        log "INFO" "Node $node: CPU $cpu_allocatable/$cpu_capacity, Memory $memory_allocatable/$memory_capacity"
        
        # Check if allocatable is significantly less than capacity (potential issue)
        if [[ "$cpu_capacity" != "0" && "$memory_capacity" != "0" ]]; then
            local cpu_ratio=$(echo "scale=2; $cpu_allocatable / $cpu_capacity" | bc)
            local memory_ratio=$(echo "scale=2; ${memory_allocatable//[A-Za-z]/} / ${memory_capacity//[A-Za-z]/}" | bc)
            
            if (( $(echo "$cpu_ratio < 0.7" | bc -l) )) || (( $(echo "$memory_ratio < 0.7" | bc -l) )); then
                nodes_with_low_resources+=("$node:cpu=$cpu_ratio:mem=$memory_ratio")
            fi
        fi
    done
    
    # Summary
    if [[ $ready_count -eq $node_count && ${#problem_nodes[@]} -eq 0 && ${#nodes_with_low_resources[@]} -eq 0 ]]; then
        check_result "Node Status" "PASS" "All $node_count nodes are ready and healthy"
    else
        local issues=()
        
        if [[ $ready_count -ne $node_count ]]; then
            issues+=("NotReady:${not_ready[*]}")
        fi
        
        if [[ ${#problem_nodes[@]} -gt 0 ]]; then
            issues+=("Conditions:${problem_nodes[*]}")
        fi
        
        if [[ ${#nodes_with_low_resources[@]} -gt 0 ]]; then
            issues+=("LowResources:${nodes_with_low_resources[*]}")
        fi
        
        check_result "Node Status" "FAIL" "Node issues: ${issues[*]}"
    fi
}

# Function to check pod status
check_pod_status() {
    section_header "POD STATUS"
    
    log "INFO" "Checking status of all pods in the cluster..."
    
    # Check if we have access to the Kubernetes API
    if ! kubectl version &>/dev/null; then
        log "ERROR" "Cannot access Kubernetes API - skipping pod status checks"
        check_result "Pod Status" "FAIL" "Cannot access Kubernetes API"
        return 1
    fi
    
    # Get all pods in all namespaces
    local pods_json
    pods_json=$(kubectl get pods --all-namespaces -o json)
    
    # Count total pods
    local pod_count
    pod_count=$(echo "$pods_json" | jq '.items | length')
    log "INFO" "Cluster has $pod_count pods"
    
    # Count running pods
    local running_count
    running_count=$(echo "$pods_json" | jq '[.items[] | select(.status.phase=="Running")] | length')
    log "INFO" "Running pods: $running_count/$pod_count"
    
    # Check pods with problems
    local problem_pods=()
    
    # Check pods not in Running state
    local non_running_pods
    non_running_pods=$(echo "$pods_json" | jq -r '.items[] | select(.status.phase!="Running" and .status.phase!="Succeeded") | "\(.metadata.namespace)/\(.metadata.name):\(.status.phase)"')
    
    if [[ -n "$non_running_pods" ]]; then
        readarray -t non_running <<<"$non_running_pods"
        problem_pods+=("${non_running[@]}")
    fi
    
    # Check pods with container problems
    local pod_container_issues
    pod_container_issues=$(echo "$pods_json" | jq -r '.items[] | select(.status.containerStatuses != null) | select(.status.containerStatuses[].ready==false) | "\(.metadata.namespace)/\(.metadata.name):ContainerNotReady"')
    
    if [[ -n "$pod_container_issues" ]]; then
        readarray -t container_issues <<<"$pod_container_issues"
        problem_pods+=("${container_issues[@]}")
    fi
    
    # Check pods with restart issues
    local pod_restart_issues
    pod_restart_issues=$(echo "$pods_json" | jq -r '.items[] | select(.status.containerStatuses != null) | select(.status.containerStatuses[].restartCount > 5) | "\(.metadata.namespace)/\(.metadata.name):RestartCount=\(.status.containerStatuses[].restartCount)"')
    
    if [[ -n "$pod_restart_issues" ]]; then
        readarray -t restart_issues <<<"$pod_restart_issues"
        problem_pods+=("${restart_issues[@]}")
    fi
    
    # Summary
    if [[ ${#problem_pods[@]} -eq 0 ]]; then
        check_result "Pod Status" "PASS" "All pods are running properly"
    else
        # Limit the number of problems shown in the summary
        local problem_pod_count=${#problem_pods[@]}
        local problem_sample="${problem_pods[*]:0:5}"
        
        if [[ $problem_pod_count -gt 5 ]]; then
            problem_sample="$problem_sample... ($((problem_pod_count - 5)) more)"
        fi
        
        check_result "Pod Status" "FAIL" "Issues with $problem_pod_count pods: $problem_sample"
    fi
}

# Function to check Pod CIDR configuration
check_pod_cidr_configuration() {
    section_header "POD CIDR CONFIGURATION"
    
    log "INFO" "Checking Pod CIDR configuration across nodes..."
    
    # Check if we have access to the Kubernetes API
    if ! kubectl version &>/dev/null; then
        log "ERROR" "Cannot access Kubernetes API - skipping CIDR configuration checks"
        check_result "Pod CIDR Configuration" "FAIL" "Cannot access Kubernetes API"
        return 1
    fi
    
    # Get node CIDR allocations
    local node_cidrs
    node_cidrs=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.podCIDR}{"\n"}{end}')
    
    if [[ -z "$node_cidrs" ]]; then
        log "ERROR" "Could not retrieve Pod CIDR information from nodes"
        check_result "Pod CIDR Configuration" "FAIL" "No Pod CIDR information available"
        return 1
    fi
    
    log "INFO" "Node CIDR assignments:"
    echo "$node_cidrs" | while read -r line; do
        log "INFO" "$line"
    done
    
    # Check for duplicate or missing CIDRs
    local cidr_issues=false
    local duplicate_check=$(echo "$node_cidrs" | awk '{print $2}' | sort | uniq -d)
    
    if [[ -n "$duplicate_check" ]]; then
        log "ERROR" "Duplicate Pod CIDRs found: $duplicate_check"
        cidr_issues=true
    fi
    
    # Check for overlapping CIDRs (simplified check)
    local overlapping_issues=false
    local cidrs=($(echo "$node_cidrs" | awk '{print $2}'))
    
    # Compare each CIDR's network portion
    for ((i=0; i<${#cidrs[@]}; i++)); do
        local cidr1="${cidrs[$i]}"
        local network1="${cidr1%/*}"
        
        for ((j=i+1; j<${#cidrs[@]}; j++)); do
            local cidr2="${cidrs[$j]}"
            local network2="${cidr2%/*}"
            
            if [[ "$network1" == "$network2" ]]; then
                log "ERROR" "Potentially overlapping CIDRs: $cidr1 and $cidr2"
                overlapping_issues=true
            fi
        done
    done
    
    # Check Flannel configuration matches node CIDRs
    local flannel_issues=false
    local node_names=$(echo "$node_cidrs" | awk '{print $1}')
    
    for node in $node_names; do
        local node_ip
        node_ip=$(kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
        
        local node_cidr
        node_cidr=$(echo "$node_cidrs" | grep "^$node" | awk '{print $2}')
        
        log "INFO" "Checking Flannel subnet file on node $node ($node_ip)..."
        
        local flannel_subnet
        flannel_subnet=$(remote_command "$node_ip" "cat /run/flannel/subnet.env 2>/dev/null || echo 'Not found'" 2>/dev/null)
        
        if [[ "$flannel_subnet" == *"Not found"* ]]; then
            log "WARNING" "Flannel subnet configuration not found on node $node"
            flannel_issues=true
        else
            log "INFO" "Flannel subnet configuration on $node: $flannel_subnet"
            
            # Extract CIDR from Flannel config
            if [[ "$flannel_subnet" =~ FLANNEL_SUBNET=([0-9./]+) ]]; then
                local flannel_cidr="${BASH_REMATCH[1]}"
                
                # Compare with node CIDR
                if [[ "$flannel_cidr" != "$node_cidr" ]]; then
                    log "ERROR" "Flannel CIDR ($flannel_cidr) doesn't match node CIDR ($node_cidr) on $node"
                    flannel_issues=true
                else
                    log "SUCCESS" "Flannel CIDR matches node CIDR on $node"
                fi
            else
                log "ERROR" "Could not parse Flannel CIDR on node $node"
                flannel_issues=true
            fi
        fi
    done
    
    # Summary
    if [[ "$cidr_issues" == "false" && "$overlapping_issues" == "false" && "$flannel_issues" == "false" ]]; then
        check_result "Pod CIDR Configuration" "PASS" "Pod CIDR configuration is consistent across all nodes"
    else
        local issues=()
        
        if [[ "$cidr_issues" == "true" ]]; then
            issues+=("DuplicateCIDRs")
        fi
        
        if [[ "$overlapping_issues" == "true" ]]; then
            issues+=("OverlappingCIDRs")
        fi
        
        if [[ "$flannel_issues" == "true" ]]; then
            issues+=("FlannelMismatch")
        fi
        
        check_result "Pod CIDR Configuration" "FAIL" "CIDR issues detected: ${issues[*]}"
    fi
}

# Function to check etcd health
check_etcd_health() {
    section_header "ETCD HEALTH"
    
    log "INFO" "Checking etcd cluster health..."
    
    # Check if etcd is running as expected
    if ! kubectl -n kube-system get pods -l component=etcd &>/dev/null; then
        log "ERROR" "Cannot find etcd pods - skipping etcd health checks"
        check_result "etcd Health" "FAIL" "Cannot find etcd pods"
        return 1
    fi
    
    # Get etcd pod name
    local etcd_pod
    etcd_pod=$(kubectl -n kube-system get pods -l component=etcd -o jsonpath='{.items[0].metadata.name}')
    
    if [[ -z "$etcd_pod" ]]; then
        log "ERROR" "Could not find any etcd pods"
        check_result "etcd Health" "FAIL" "No etcd pods found"
        return 1
    fi
    
    log "INFO" "Found etcd pod: $etcd_pod"
    
    # Check etcd health through the pod
    local etcd_health
    etcd_health=$(kubectl -n kube-system exec "$etcd_pod" -- etcdctl --endpoints=https://127.0.0.1:2379 \
        --cacert=/etc/kubernetes/pki/etcd/ca.crt \
        --cert=/etc/kubernetes/pki/etcd/server.crt \
        --key=/etc/kubernetes/pki/etcd/server.key \
        endpoint health 2>/dev/null)
    
    if [[ "$etcd_health" == *"is healthy"* ]]; then
        log "SUCCESS" "etcd is healthy: $etcd_health"
    else
        log "ERROR" "etcd health check failed: $etcd_health"
        check_result "etcd Health" "FAIL" "etcd health check failed"
        return 1
    fi
    
    # Check etcd endpoint status for more detail
    local etcd_status
    etcd_status=$(kubectl -n kube-system exec "$etcd_pod" -- etcdctl --endpoints=https://127.0.0.1:2379 \
        --cacert=/etc/kubernetes/pki/etcd/ca.crt \
        --cert=/etc/kubernetes/pki/etcd/server.crt \
        --key=/etc/kubernetes/pki/etcd/server.key \
        endpoint status -w json 2>/dev/null)
    
    if [[ -n "$etcd_status" ]]; then
        log "INFO" "etcd detailed status:"
        # Don't use jq here as it might not be available in the etcd pod
        log "INFO" "$etcd_status"
    else
        log "WARNING" "Could not get detailed etcd status"
    fi
    
    # Summary
    check_result "etcd Health" "PASS" "etcd is healthy"
}

# Function to check all Kubernetes services
check_kubernetes_services() {
    section_header "COMPREHENSIVE KUBERNETES SERVICE CHECKS"
    
    check_kubernetes_components
    check_node_status
    check_pod_status
    check_pod_cidr_configuration
    check_etcd_health
    
    log "INFO" "Kubernetes service diagnostics completed"
}

# ============================================================================
# SYSTEM RESOURCE DIAGNOSTICS
# ============================================================================

# Function to check system resources on all nodes
check_system_resources() {
    section_header "SYSTEM RESOURCES"
    
    log "INFO" "Checking system resources on all cluster nodes..."
    local resource_issues=0
    local resources_with_issues=()
    
    # Define threshold values
    local CPU_THRESHOLD=80      # 80% CPU usage is high
    local MEMORY_THRESHOLD=80   # 80% memory usage is high
    local DISK_THRESHOLD=80     # 80% disk usage is high
    
    # Check resources on each node
    for NODE_CONFIG in "${ALL_NODES[@]}"; do
        local NODE_NAME=$(get_node_property "$NODE_CONFIG" 0)
        local NODE_IP=$(get_node_property "$NODE_CONFIG" 1)
        
        log "INFO" "Checking system resources on $NODE_NAME ($NODE_IP)..."
        
        # Check CPU usage
        local cpu_usage
        cpu_usage=$(remote_command "$NODE_IP" "top -bn1 | grep '%Cpu' | awk '{print \$2+\$4}'" 2>/dev/null)
        
        if [[ -n "$cpu_usage" ]]; then
            if (( $(echo "$cpu_usage > $CPU_THRESHOLD" | bc -l) )); then
                log "WARNING" "High CPU usage on $NODE_NAME: ${cpu_usage}%"
                resource_issues=$((resource_issues + 1))
                resources_with_issues+=("$NODE_NAME:CPU=${cpu_usage}%")
            else
                log "SUCCESS" "CPU usage on $NODE_NAME: ${cpu_usage}%"
            fi
        else
            log "ERROR" "Failed to check CPU usage on $NODE_NAME"
        fi
        
        # Check memory usage
        local memory_usage
        memory_usage=$(remote_command "$NODE_IP" "free | grep Mem | awk '{print \$3/\$2 * 100.0}'" 2>/dev/null)
        
        if [[ -n "$memory_usage" ]]; then
            if (( $(echo "$memory_usage > $MEMORY_THRESHOLD" | bc -l) )); then
                log "WARNING" "High memory usage on $NODE_NAME: ${memory_usage}%"
                resource_issues=$((resource_issues + 1))
                resources_with_issues+=("$NODE_NAME:Memory=${memory_usage}%")
            else
                log "SUCCESS" "Memory usage on $NODE_NAME: ${memory_usage}%"
            fi
        else
            log "ERROR" "Failed to check memory usage on $NODE_NAME"
        fi
        
        # Check disk usage
        local disk_usage
        disk_usage=$(remote_command "$NODE_IP" "df -h / | awk 'NR==2 {print \$5}' | sed 's/%//'" 2>/dev/null)
        
        if [[ -n "$disk_usage" ]]; then
            if (( disk_usage > DISK_THRESHOLD )); then
                log "WARNING" "High disk usage on $NODE_NAME: ${disk_usage}%"
                resource_issues=$((resource_issues + 1))
                resources_with_issues+=("$NODE_NAME:Disk=${disk_usage}%")
            else
                log "SUCCESS" "Disk usage on $NODE_NAME: ${disk_usage}%"
            fi
        else
            log "ERROR" "Failed to check disk usage on $NODE_NAME"
        fi
        
        # Check for inode usage
        local inode_usage
        inode_usage=$(remote_command "$NODE_IP" "df -i / | awk 'NR==2 {print \$5}' | sed 's/%//'" 2>/dev/null)
        
        if [[ -n "$inode_usage" ]]; then
            if (( inode_usage > DISK_THRESHOLD )); then
                log "WARNING" "High inode usage on $NODE_NAME: ${inode_usage}%"
                resource_issues=$((resource_issues + 1))
                resources_with_issues+=("$NODE_NAME:Inodes=${inode_usage}%")
            else
                log "SUCCESS" "Inode usage on $NODE_NAME: ${inode_usage}%"
            fi
        else
            log "ERROR" "Failed to check inode usage on $NODE_NAME"
        fi
        
        # Check for process count
        local process_count
        process_count=$(remote_command "$NODE_IP" "ps aux | wc -l" 2>/dev/null)
        
        if [[ -n "$process_count" ]]; then
            if (( process_count > 2000 )); then
                log "WARNING" "High process count on $NODE_NAME: $process_count processes"
                resource_issues=$((resource_issues + 1))
                resources_with_issues+=("$NODE_NAME:Processes=$process_count")
            else
                log "SUCCESS" "Process count on $NODE_NAME: $process_count processes"
            fi
        fi
    done
    
    # Summary
    if [[ $resource_issues -eq 0 ]]; then
        check_result "System Resources" "PASS" "All nodes have healthy resource levels"
    else
        check_result "System Resources" "WARNING" "Resource issues detected: ${resources_with_issues[*]}"
    fi
}

# ============================================================================
# DIAGNOSTICS EXECUTION FUNCTIONS
# ============================================================================

# Function to run basic diagnostics
run_basic_diagnostics() {
    section_header "BASIC DIAGNOSTICS"
    
    check_required_tools
    check_node_connectivity
    check_kubernetes_components
    check_node_status
    check_system_resources
    
    log "INFO" "Basic diagnostics completed"
}

# Function to run network diagnostics
run_network_diagnostics() {
    section_header "NETWORK DIAGNOSTICS"
    
    check_required_tools
    check_network
    
    log "INFO" "Network diagnostics completed"
}

# Function to run service diagnostics
run_service_diagnostics() {
    section_header "SERVICE DIAGNOSTICS"
    
    check_required_tools
    check_kubernetes_services
    
    log "INFO" "Service diagnostics completed"
}

# Function to run full diagnostics
run_full_diagnostics() {
    section_header "FULL DIAGNOSTICS"
    
    check_required_tools
    check_network
    check_kubernetes_services
    check_system_resources
    
    log "INFO" "Full diagnostics completed"
}

# Function to generate HTML report
generate_html_report() {
    section_header "GENERATING DIAGNOSTIC REPORT"
    
    log "INFO" "Generating HTML report at $REPORT_FILE..."
    
    # Create HTML report header
    cat > "$REPORT_FILE" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Kubernetes Multi-Cloud Cluster Diagnostic Report</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            margin: 20px;
            background-color: #f5f5f5;
        }
        .header {
            background-color: #326ce5;
            color: white;
            padding: 20px;
            border-radius: 5px;
            margin-bottom: 20px;
        }
        .section {
            background-color: white;
            padding: 15px;
            margin-bottom: 20px;
            border-radius: 5px;
            box-shadow: 0 2px 5px rgba(0,0,0,0.1);
        }
        .section-title {
            font-size: 18px;
            font-weight: bold;
            margin-bottom: 10px;
            color: #326ce5;
            border-bottom: 1px solid #eee;
            padding-bottom: 5px;
        }
        .pass {
            color: green;
        }
        .fail {
            color: red;
        }
        .warning {
            color: orange;
        }
        .info {
            color: #444;
        }
        pre {
            background-color: #f9f9f9;
            padding: 10px;
            border-radius: 5px;
            overflow-x: auto;
        }
        .timestamp {
            color: #888;
            font-size: 14px;
        }
        .summary {
            font-weight: bold;
            margin-top: 15px;
        }
    </style>
</head>
<body>
    <div class="header">
        <h1>Kubernetes Multi-Cloud Cluster Diagnostic Report</h1>
        <p>Generated on: $(date)</p>
    </div>
EOF
    
    # Process log file into HTML report sections
    local current_section=""
    local in_section=false
    
    # Capture machine info
    cat >> "$REPORT_FILE" << EOF
    <div class="section">
        <div class="section-title">System Information</div>
        <pre>
Hostname: $(hostname)
Date: $(date)
Kernel: $(uname -r)
Kubernetes Version: $(kubectl version --short 2>/dev/null || echo "Not available")
        </pre>
    </div>
EOF
    
    # Process log file
    while IFS= read -r line; do
        if [[ "$line" == *"[INFO] SECTION:"* ]]; then
            # New section found
            if [[ "$in_section" == "true" ]]; then
                echo "</pre></div>" >> "$REPORT_FILE"
            fi
            
            current_section="${line#*SECTION: }"
            echo "<div class=\"section\">" >> "$REPORT_FILE"
            echo "<div class=\"section-title\">$current_section</div>" >> "$REPORT_FILE"
            echo "<pre>" >> "$REPORT_FILE"
            in_section=true
        elif [[ "$in_section" == "true" ]]; then
            # Format log line based on level
            if [[ "$line" == *"[SUCCESS]"* ]]; then
                echo "<span class=\"pass\">$line</span>" >> "$REPORT_FILE"
            elif [[ "$line" == *"[ERROR]"* ]]; then
                echo "<span class=\"fail\">$line</span>" >> "$REPORT_FILE"
            elif [[ "$line" == *"[WARNING]"* ]]; then
                echo "<span class=\"warning\">$line</span>" >> "$REPORT_FILE"
            else
                echo "<span class=\"info\">$line</span>" >> "$REPORT_FILE"
            fi
        fi
    done < "$TEMP_LOG_FILE"
    
    # Close final section
    if [[ "$in_section" == "true" ]]; then
        echo "</pre></div>" >> "$REPORT_FILE"
    fi
    
    # Add summary section
    echo "<div class=\"section\">" >> "$REPORT_FILE"
    echo "<div class=\"section-title\">Diagnostic Summary</div>" >> "$REPORT_FILE"
    echo "<pre>" >> "$REPORT_FILE"
    
    # Count issues
    local error_count=$(grep -c '\[ERROR\]' "$TEMP_LOG_FILE")
    local warning_count=$(grep -c '\[WARNING\]' "$TEMP_LOG_FILE")
    local success_count=$(grep -c '\[SUCCESS\]' "$TEMP_LOG_FILE")
    
    if [[ $error_count -eq 0 && $warning_count -eq 0 ]]; then
        echo "<span class=\"pass\">All diagnostics passed successfully! No issues detected.</span>" >> "$REPORT_FILE"
    else
        echo "<span class=\"summary\">Summary of issues:</span>" >> "$REPORT_FILE"
        echo "- <span class=\"fail\">Errors: $error_count</span>" >> "$REPORT_FILE"
        echo "- <span class=\"warning\">Warnings: $warning_count</span>" >> "$REPORT_FILE"
        echo "- <span class=\"pass\">Successful checks: $success_count</span>" >> "$REPORT_FILE"
        
        # Extract error and warning messages
        if [[ $error_count -gt 0 ]]; then
            echo "" >> "$REPORT_FILE"
            echo "<span class=\"fail\">Error details:</span>" >> "$REPORT_FILE"
            grep '\[ERROR\]' "$TEMP_LOG_FILE" | sed 's/\[ERROR\]/  -/' >> "$REPORT_FILE"
        fi
        
        if [[ $warning_count -gt 0 ]]; then
            echo "" >> "$REPORT_FILE"
            echo "<span class=\"warning\">Warning details:</span>" >> "$REPORT_FILE"
            grep '\[WARNING\]' "$TEMP_LOG_FILE" | sed 's/\[WARNING\]/  -/' >> "$REPORT_FILE"
        fi
    fi
    
    echo "</pre></div>" >> "$REPORT_FILE"
    
    # Close HTML report
    cat >> "$REPORT_FILE" << EOF
    <div class="section">
        <div class="section-title">Next Steps</div>
        <p>If issues were detected, consider the following steps:</p>
        <ol>
            <li>Check logs on affected nodes with <code>journalctl -u kubelet</code></li>
            <li>Verify network connectivity between nodes</li>
            <li>Run the troubleshooting scripts at <code>${SCRIPT_DIR}/1000-Troubleshooting/</code></li>
            <li>Consult the Kubernetes Multi-Cloud Cluster Guide documentation</li>
        </ol>
    </div>
    <p class="timestamp">Report generated by diagnosis.sh version 1.0.0</p>
</body>
</html>
EOF
    
    log "SUCCESS" "HTML report generated at $REPORT_FILE"
    
    # Offer to open the report
    if command -v xdg-open &>/dev/null; then
        log "INFO" "You can open the report with: xdg-open $REPORT_FILE"
    fi
    
    # Send email if requested
    if [[ "$EMAIL_ALERTS" == "true" && -n "$EMAIL_RECIPIENT" ]]; then
        if command -v mail &>/dev/null; then
            log "INFO" "Sending diagnostic report to $EMAIL_RECIPIENT"
            echo "Kubernetes Cluster Diagnostic Report - $(date)" | mail -s "Kubernetes Cluster Diagnostic Report" \
                -a "$REPORT_FILE" "$EMAIL_RECIPIENT"
            
            if [[ $? -eq 0 ]]; then
                log "SUCCESS" "Email sent to $EMAIL_RECIPIENT"
            else
                log "ERROR" "Failed to send email to $EMAIL_RECIPIENT"
            fi
        else
            log "ERROR" "Mail command not found, cannot send email"
        fi
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

# Trap to clean up temp file
trap 'rm -f "$TEMP_LOG_FILE"' EXIT

# Initialize log file
> "$TEMP_LOG_FILE"

# Run appropriate diagnostics based on mode
log "INFO" "Starting diagnostic mode: $DIAGNOSTIC_MODE"

# First ensure required tools are available
check_required_tools

# Then continue with the rest of the diagnostics
case "$DIAGNOSTIC_MODE" in
    "full")
        # Skip the required tools check since we already did it
        check_network
        check_kubernetes_services
        check_system_resources
        ;;
    "basic")
        # Skip the required tools check since we already did it
        check_node_connectivity
        check_kubernetes_components
        check_node_status
        check_system_resources
        ;;
    "network")
        # Skip the required tools check since we already did it
        check_network
        ;;
    "services")
        # Skip the required tools check since we already did it
        check_kubernetes_services
        ;;
    *)
        log "ERROR" "Unknown diagnostic mode: $DIAGNOSTIC_MODE"
        echo "Valid modes are: full, basic, network, services"
        exit 1
        ;;
esac

# Generate HTML report if requested
if [[ "$GENERATE_REPORT" == "true" ]]; then
    generate_html_report
fi

# Print summary
section_header "DIAGNOSTIC SUMMARY"

# Count issues
error_count=$(grep -c '\[ERROR\]' "$TEMP_LOG_FILE")
warning_count=$(grep -c '\[WARNING\]' "$TEMP_LOG_FILE")
success_count=$(grep -c '\[SUCCESS\]' "$TEMP_LOG_FILE")

echo ""
if [[ $error_count -eq 0 && $warning_count -eq 0 ]]; then
    echo -e "\e[32;1mAll diagnostics passed successfully! No issues detected.\e[0m"
else
    echo -e "\e[1mSummary of issues:\e[0m"
    echo -e "\e[31m- Errors: $error_count\e[0m"
    echo -e "\e[33m- Warnings: $warning_count\e[0m"
    echo -e "\e[32m- Successful checks: $success_count\e[0m"
    
    # List most critical issues
    if [[ $error_count -gt 0 ]]; then
        echo ""
        echo -e "\e[31mMost critical issues:\e[0m"
        grep '\[ERROR\]' "$TEMP_LOG_FILE" | head -5 | sed 's/\[ERROR\]/  -/' | sed 's/\[[0-9-]* [0-9:]*\] //'
        
        if [[ $error_count -gt 5 ]]; then
            echo "  ... and $((error_count - 5)) more errors"
        fi
    fi
fi

echo ""
echo "Diagnostic log saved to: $TEMP_LOG_FILE"
if [[ "$GENERATE_REPORT" == "true" ]]; then
    echo "HTML report saved to: $REPORT_FILE"
fi

echo ""
echo "For more detailed troubleshooting, consider using:"
echo "  ${SCRIPT_DIR}/1000-Troubleshooting/001-Fix_Common_Issues.sh"
echo "  ${SCRIPT_DIR}/1000-Troubleshooting/002-Network_Connectivity_Test.sh"
echo ""

# Save log to file
FULL_LOG_FILE="${LOG_DIR}/diagnosis-$(date +%Y%m%d-%H%M%S).log"
cp "$TEMP_LOG_FILE" "$FULL_LOG_FILE"
echo "Full diagnostic log saved to: $FULL_LOG_FILE"

# Exit with appropriate status
if [[ $error_count -gt 0 ]]; then
    exit 1
elif [[ $warning_count -gt 0 ]]; then
    exit 100
else
    exit 0
fi
