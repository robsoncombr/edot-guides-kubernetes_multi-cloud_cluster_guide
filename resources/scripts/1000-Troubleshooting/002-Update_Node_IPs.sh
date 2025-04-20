#!/bin/bash
# ============================================================================
# 002-Update_Node_IPs.sh - Update node IP configurations
# ============================================================================
# 
# DESCRIPTION:
#   This script updates the node IPs across the cluster using the centralized
#   environment configuration. It ensures all nodes use their VPN IPs for
#   internal cluster communication.
#
# USAGE:
#   ./002-Update_Node_IPs.sh
#
# NOTES:
#   - Run this script from the control plane node
#   - Requires password-less SSH access to all nodes
# ============================================================================

# Source the environment configuration
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
ENV_CONFIG_PATH="$(realpath "$SCRIPT_DIR/../0100-Chapter_1/001-Environment_Config.sh")"

if [ ! -f "$ENV_CONFIG_PATH" ]; then
    echo "Error: Environment configuration file not found at $ENV_CONFIG_PATH"
    exit 1
fi

source "$ENV_CONFIG_PATH"

echo "======================================================================"
echo "Updating Node IP Configurations"
echo "======================================================================"

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# Check if running on control plane node
HOSTNAME=$(get_current_hostname)
CONTROL_PLANE_HOSTNAME=$(get_node_property "${NODE_CP1}" 0)

if [[ "$HOSTNAME" != "$CONTROL_PLANE_HOSTNAME" ]]; then
    echo "Error: This script must be run on the control plane node ($CONTROL_PLANE_HOSTNAME)"
    echo "Current host: $HOSTNAME"
    exit 1
fi

# Function to update node IP configuration
update_node_ip() {
    local node_config="$1"
    local node_name=$(get_node_property "$node_config" 0)
    local node_ip=$(get_node_property "$node_config" 1)
    local node_interface=$(get_node_property "$node_config" 3)
    
    echo "-------------------------------------------------------------------"
    echo "Updating Kubernetes node: $node_name"
    echo "Setting node-ip to VPN address: $node_ip"
    echo "Using network interface: $node_interface"
    
    # Check current internal IP
    local current_ip=$(kubectl get node "$node_name" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "None")
    echo "Current internal IP: $current_ip"
    
    # Update kubelet configuration on the node
    echo "Connecting to node and updating kubelet configuration..."
    ssh -o StrictHostKeyChecking=no root@${node_ip} "echo 'KUBELET_EXTRA_ARGS=\"--node-ip=${node_ip} --cluster-dns=${DNS_SERVICE_IP}\"' > /etc/default/kubelet && systemctl restart kubelet" && \
    echo "✅ Successfully updated kubelet configuration on $node_name" || \
    echo "❌ Failed to update kubelet configuration on $node_name"
    
    echo "Waiting for kubelet to restart and re-register with the API server..."
    sleep 10
    
    # Verify the update
    echo "Verifying node IP update..."
    local new_ip=$(kubectl get node "$node_name" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "None")
    
    if [[ "$new_ip" == "$node_ip" ]]; then
        echo "✅ Node $node_name now has the correct internal IP: $new_ip"
    else
        echo "❌ Node $node_name still has incorrect internal IP: $new_ip (expected: $node_ip)"
    fi
}

# Update IP configuration for each node
for NODE_CONFIG in "${ALL_NODES[@]}"; do
    update_node_ip "$NODE_CONFIG"
done

echo "-------------------------------------------------------------------"
echo "Checking node status:"
kubectl get nodes -o custom-columns=NAME:.metadata.name,INTERNAL-IP:.status.addresses[0].address,POD-CIDR:.spec.podCIDR,STATUS:.status.conditions[-1].type

echo "======================================================================"
echo "Node IP update process completed!"
echo "======================================================================"
