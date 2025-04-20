#!/bin/bash
# ============================================================================
# 004-Fix_Existing_Node_CIDRs.sh - Fix CIDRs on existing nodes
# ============================================================================
# 
# DESCRIPTION:
#   This script fixes Pod CIDR mismatches on nodes that are already joined
#   to the cluster by reconfiguring Flannel subnet files and patching the
#   node objects according to the centralized environment configuration.
#
# USAGE:
#   ./004-Fix_Existing_Node_CIDRs.sh
#
# NOTES:
#   - Run this script from the control plane node
#   - Fixes Pod CIDRs when nodes are already joined but have incorrect CIDRs
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
echo "Fixing Pod CIDRs on Existing Nodes"
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

# Get current node CIDRs from the cluster
echo "Current node Pod CIDR assignments:"
kubectl get nodes -o custom-columns=NAME:.metadata.name,INTERNAL-IP:.status.addresses[0].address,POD-CIDR:.spec.podCIDR,STATUS:.status.conditions[-1].type

# Function to fix Pod CIDR for a node
fix_node_cidr() {
    local node_config="$1"
    local node_name=$(get_node_property "$node_config" 0)
    local node_ip=$(get_node_property "$node_config" 1)
    local node_pod_cidr=$(get_node_property "$node_config" 2)
    
    echo "-------------------------------------------------------------------"
    echo "Fixing Pod CIDR for node: $node_name"
    echo "Target Pod CIDR: $node_pod_cidr"
    
    # Get current Pod CIDR in Kubernetes
    local current_cidr=$(kubectl get node "$node_name" -o jsonpath='{.spec.podCIDR}' 2>/dev/null || echo "")
    
    if [ -z "$current_cidr" ]; then
        echo "No Pod CIDR currently assigned to $node_name"
    else
        echo "Current Pod CIDR in Kubernetes: $current_cidr"
    fi
    
    if [ "$current_cidr" == "$node_pod_cidr" ]; then
        echo "Node $node_name already has the correct Pod CIDR: $node_pod_cidr"
    else
        echo "Patching node $node_name with correct Pod CIDR: $node_pod_cidr"
        
        # First, try a "proper" patch that retains other fields
        if kubectl patch node "$node_name" --type=merge -p "{\"spec\":{\"podCIDR\":\"$node_pod_cidr\",\"podCIDRs\":[\"$node_pod_cidr\"]}}" &>/dev/null; then
            echo "✅ Successfully patched node $node_name with CIDR $node_pod_cidr"
        else
            echo "Warning: Standard patch failed, trying alternative approach..."
            
            # For nodes that are already running with a different CIDR, we need a more invasive approach
            echo "Creating a temporary manifest of the node object..."
            kubectl get node "$node_name" -o yaml > /tmp/node-$node_name.yaml
            
            # Modify the Pod CIDR in the manifest
            sed -i "s|podCIDR:.*|podCIDR: $node_pod_cidr|" /tmp/node-$node_name.yaml
            sed -i "/podCIDRs:/,+1d" /tmp/node-$node_name.yaml  # Remove existing podCIDRs list
            sed -i "/spec:/a \ \ podCIDRs:\n \ \ - $node_pod_cidr" /tmp/node-$node_name.yaml  # Add new podCIDRs list
            
            # Replace the node object with the modified manifest
            echo "Replacing node object with modified manifest..."
            kubectl replace --force -f /tmp/node-$node_name.yaml
            
            rm -f /tmp/node-$node_name.yaml
            echo "✅ Replaced node $node_name with correct CIDR: $node_pod_cidr"
        fi
    fi
    
    # Update Flannel subnet configuration on the node
    echo "Updating Flannel subnet configuration on $node_name..."
    ssh -o StrictHostKeyChecking=no root@${node_ip} "mkdir -p /run/flannel && \
        echo 'FLANNEL_NETWORK=$POD_CIDR' > /run/flannel/subnet.env && \
        echo 'FLANNEL_SUBNET=$node_pod_cidr' >> /run/flannel/subnet.env && \
        echo 'FLANNEL_MTU=1450' >> /run/flannel/subnet.env && \
        echo 'FLANNEL_IPMASQ=true' >> /run/flannel/subnet.env"
    
    # Reset CNI network interfaces
    echo "Resetting CNI network interfaces on $node_name..."
    ssh -o StrictHostKeyChecking=no root@${node_ip} "ip link set cni0 down 2>/dev/null || true && \
        ip link delete cni0 2>/dev/null || true && \
        ip link delete flannel.1 2>/dev/null || true && \
        rm -rf /var/lib/cni/networks/* 2>/dev/null || true"
    
    # Restart kubelet
    echo "Restarting kubelet on $node_name..."
    ssh -o StrictHostKeyChecking=no root@${node_ip} "systemctl restart kubelet"
    
    echo "Pod CIDR fixed for node $node_name"
}

# Fix Pod CIDR for each node
for NODE_CONFIG in "${ALL_NODES[@]}"; do
    fix_node_cidr "$NODE_CONFIG"
done

# Restart all Flannel pods
echo "-------------------------------------------------------------------"
echo "Restarting Flannel pods to apply changes..."
kubectl -n kube-flannel delete pods --all

echo "-------------------------------------------------------------------"
echo "Waiting for Flannel pods to restart (30 seconds)..."
sleep 30

# Check Flannel pod status
echo "Checking Flannel pod status:"
kubectl -n kube-flannel get pods -o wide

echo "-------------------------------------------------------------------"
echo "Verifying node Pod CIDR assignments:"
kubectl get nodes -o custom-columns=NAME:.metadata.name,INTERNAL-IP:.status.addresses[0].address,POD-CIDR:.spec.podCIDR,STATUS:.status.conditions[-1].type

echo "======================================================================"
echo "Pod CIDR fix completed!"
echo "======================================================================"
