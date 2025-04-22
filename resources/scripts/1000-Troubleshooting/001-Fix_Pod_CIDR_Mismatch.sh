#!/bin/bash
# ============================================================================
# 001-Fix_Pod_CIDR_Mismatch.sh - Fix Pod CIDR mismatches
# ============================================================================
# 
# DESCRIPTION:
#   This script fixes Pod CIDR mismatches between Kubernetes node objects and
#   Flannel configurations by updating the Flannel subnet files on each node
#   to match the expected configuration from the environment settings.
#
# USAGE:
#   ./001-Fix_Pod_CIDR_Mismatch.sh
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
echo "Fixing Pod CIDR mismatches in Kubernetes cluster"
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

# Function to fix Flannel subnet configuration on a node
fix_flannel_subnet() {
    local node_config="$1"
    local node_name=$(get_node_property "$node_config" 0)
    local node_ip=$(get_node_property "$node_config" 1)
    local node_pod_cidr=$(get_node_property "$node_config" 2)
    
    echo "-------------------------------------------------------------------"
    echo "Fixing Flannel subnet for node $node_name ($node_ip)"
    echo "Setting Pod CIDR to $node_pod_cidr"
    
    # Check current Pod CIDR in Kubernetes
    local k8s_cidr=$(kubectl get node "$node_name" -o jsonpath='{.spec.podCIDR}' 2>/dev/null || echo "")
    echo "Current Pod CIDR in Kubernetes: $k8s_cidr"
    
    # Check current Flannel subnet configuration
    echo "Checking current Flannel subnet configuration on $node_name..."
    local flannel_subnet=$(ssh -o StrictHostKeyChecking=no root@${node_ip} "cat /run/flannel/subnet.env 2>/dev/null | grep FLANNEL_SUBNET | cut -d= -f2" || echo "Not found")
    echo "Current Flannel subnet: $flannel_subnet"
    
    # Update Flannel subnet configuration
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
    
    echo "Flannel subnet fixed for node $node_name"
}

# Process each node
for NODE_CONFIG in "${ALL_NODES[@]}"; do
    fix_flannel_subnet "$NODE_CONFIG"
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
echo "Checking node status:"
kubectl get nodes -o custom-columns=NAME:.metadata.name,INTERNAL-IP:.status.addresses[0].address,POD-CIDR:.spec.podCIDR,STATUS:.status.conditions[-1].type

echo "======================================================================"
echo "Pod CIDR mismatch fix completed!"
echo "======================================================================"
