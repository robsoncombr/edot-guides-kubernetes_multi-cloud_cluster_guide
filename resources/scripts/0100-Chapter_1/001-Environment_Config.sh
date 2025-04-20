#!/bin/bash
# ============================================================================
# 001-Environment_Config.sh - Environment Configuration for Multi-Cloud Kubernetes
# ============================================================================
# 
# DESCRIPTION:
#   This script defines all environment variables and configurations for the
#   multi-cloud Kubernetes cluster. It is intended to be sourced by other
#   scripts to provide consistent configuration across the entire guide.
#
# USAGE:
#   source /path/to/001-Environment_Config.sh
#
# NOTES:
#   - Modify this file to match your specific environment
#   - All scripts in this guide should source this file for configuration
# ============================================================================

# Export all variables defined in this script
set -a

# ============================================================================
# Cluster-wide Configuration
# ============================================================================

# Kubernetes version to use
K8S_VERSION="v1.32.3"

# Global network configuration
POD_CIDR="10.10.0.0/16"
SERVICE_CIDR="10.1.0.0/16"
DNS_SERVICE_IP="10.1.0.10"

# ============================================================================
# Node-specific Configuration
# ============================================================================

# Define array of node configurations
# Format: hostname:vpn_ip:pod_cidr:interface:role:external_ip

# Control plane node
NODE_CP1="k8s-01-oci-01:172.16.0.1:10.10.1.0/24:enp0s6:control-plane:172.16.0.1"

# Worker nodes
NODE_W1="k8s-02-oci-02:172.16.0.2:10.10.2.0/24:enp0s6:worker:172.16.0.2"
NODE_W2="k8s-03-htg-01:172.16.0.3:10.10.3.0/24:eth0:worker:172.16.0.3"

# Combined array of all nodes
ALL_NODES=("$NODE_CP1" "$NODE_W1" "$NODE_W2")

# Control plane endpoint (used for HA setup)
CONTROL_PLANE_ENDPOINT="172.16.0.1:6443"

# ============================================================================
# Helper Functions
# ============================================================================

# Get any property from a node configuration string
# Usage: get_node_property "node_string" "property_index"
# Property indices: 0=hostname, 1=vpn_ip, 2=pod_cidr, 3=interface, 4=role, 5=external_ip
get_node_property() {
    local node_string="$1"
    local property_index="$2"
    
    echo "$node_string" | cut -d: -f$((property_index+1))
}

# Get a property for a specific node by hostname
# Usage: get_node_property_by_hostname "hostname" "property_name"
# Property names: hostname, vpn_ip, pod_cidr, interface, role, external_ip
get_node_property_by_hostname() {
    local hostname="$1"
    local property_name="$2"
    local property_index=0
    
    # Map property name to index
    case "$property_name" in
        hostname) property_index=0 ;;
        vpn_ip) property_index=1 ;;
        pod_cidr) property_index=2 ;;
        interface) property_index=3 ;;
        role) property_index=4 ;;
        external_ip) property_index=5 ;;
        *) echo "Unknown property: $property_name" >&2; return 1 ;;
    esac
    
    # Find the node by hostname and extract the property
    for node in "${ALL_NODES[@]}"; do
        local node_hostname=$(get_node_property "$node" 0)
        if [[ "$node_hostname" == "$hostname" ]]; then
            get_node_property "$node" "$property_index"
            return 0
        fi
    done
    
    echo "Node not found: $hostname" >&2
    return 1
}

# Get the current node's hostname
get_current_hostname() {
    hostname
}

# Get a property for the current node
# Usage: get_current_node_property "property_name"
get_current_node_property() {
    local current_hostname=$(get_current_hostname)
    get_node_property_by_hostname "$current_hostname" "$1"
}

# Print all node configurations
print_node_configs() {
    echo "Node Configurations:"
    printf "%-15s %-15s %-15s %-10s %-15s %-15s\n" "HOSTNAME" "VPN IP" "POD CIDR" "INTERFACE" "ROLE" "EXTERNAL IP"
    echo "---------------------------------------------------------------------------------"
    
    for node in "${ALL_NODES[@]}"; do
        local hostname=$(get_node_property "$node" 0)
        local vpn_ip=$(get_node_property "$node" 1)
        local pod_cidr=$(get_node_property "$node" 2)
        local interface=$(get_node_property "$node" 3)
        local role=$(get_node_property "$node" 4)
        local external_ip=$(get_node_property "$node" 5)
        
        printf "%-15s %-15s %-15s %-10s %-15s %-15s\n" "$hostname" "$vpn_ip" "$pod_cidr" "$interface" "$role" "$external_ip"
    done
}

# Stop exporting variables
set +a

# Print configuration if run directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Kubernetes Multi-Cloud Cluster Environment Configuration"
    echo "========================================================"
    echo "Kubernetes Version: $K8S_VERSION"
    echo "Pod CIDR: $POD_CIDR"
    echo "Service CIDR: $SERVICE_CIDR"
    echo "DNS Service IP: $DNS_SERVICE_IP"
    echo "Control Plane Endpoint: $CONTROL_PLANE_ENDPOINT"
    echo ""
    print_node_configs
fi
