#!/bin/bash

# ============================================================================
# 003-Fix_Flannel_Subnets.sh - Script to fix Flannel subnet configuration on all nodes
# ============================================================================
# 
# DESCRIPTION:
#   This script configures Flannel subnet.env on all nodes with the correct
#   CIDR ranges and network interfaces according to the environment configuration.
#
# USAGE:
#   ./003-Fix_Flannel_Subnets.sh
#
# NOTES:
#   - Run this script on the control plane node
#   - The script creates the correct Flannel subnet configuration on all nodes
# ============================================================================

# Source the environment configuration
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
ENV_CONFIG_PATH="/root/data/development/edot-guides-kubernetes_multi-cloud_cluster_guide/resources/scripts/0100-Chapter_1/001-Environment_Config.sh"

if [ ! -f "$ENV_CONFIG_PATH" ]; then
    echo "Error: Environment configuration file not found at $ENV_CONFIG_PATH"
    exit 1
fi

source "$ENV_CONFIG_PATH"

echo "======================================================================"
echo "Fixing Flannel subnet configuration on all nodes"
echo "======================================================================"

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# Configure Flannel subnet on the control plane
CP_HOSTNAME=$(get_node_property "${NODE_CP1}" 0)
CP_POD_CIDR=$(get_node_property "${NODE_CP1}" 2)
CP_INTERFACE=$(get_node_property "${NODE_CP1}" 3)

echo "Configuring Flannel subnet on control plane node: $CP_HOSTNAME"
echo "  - Pod CIDR: $CP_POD_CIDR"
echo "  - Interface: $CP_INTERFACE"

# Set up Flannel subnet configuration on the control plane
mkdir -p /run/flannel
cat > /run/flannel/subnet.env << EOF
FLANNEL_NETWORK=$POD_CIDR
FLANNEL_SUBNET=$CP_POD_CIDR
FLANNEL_MTU=1450
FLANNEL_IPMASQ=true
FLANNEL_IFACE=$CP_INTERFACE
EOF

# Restart kubelet on control plane
echo "Restarting kubelet on control plane..."
systemctl restart kubelet

# Display current configuration
echo "Current Flannel subnet configuration on control plane:"
cat /run/flannel/subnet.env
echo ""

# For each worker node, display the expected configuration
for NODE_CONFIG in "${ALL_NODES[@]}"; do
    NODE_NAME=$(get_node_property "$NODE_CONFIG" 0)
    NODE_IP=$(get_node_property "$NODE_CONFIG" 1)
    NODE_POD_CIDR=$(get_node_property "$NODE_CONFIG" 2)
    NODE_INTERFACE=$(get_node_property "$NODE_CONFIG" 3)
    
    # Skip control plane node as we already configured it
    if [[ "$NODE_NAME" == "$CP_HOSTNAME" ]]; then
        continue
    fi
    
    echo "--------------------------------------------------------------------"
    echo "For worker node: $NODE_NAME ($NODE_IP)"
    echo "The Flannel subnet configuration should be:"
    echo ""
    echo "  mkdir -p /run/flannel"
    echo "  cat > /run/flannel/subnet.env << EOF"
    echo "  FLANNEL_NETWORK=$POD_CIDR"
    echo "  FLANNEL_SUBNET=$NODE_POD_CIDR"
    echo "  FLANNEL_MTU=1450"
    echo "  FLANNEL_IPMASQ=true"
    echo "  FLANNEL_IFACE=$NODE_INTERFACE"
    echo "  EOF"
    echo ""
    echo "  systemctl restart kubelet"
    echo "--------------------------------------------------------------------"
done

echo "======================================================================"
echo "Control plane Flannel subnet configuration fixed!"
echo ""
echo "To fix worker nodes, please run the displayed commands on each worker node"
echo "After applying these configurations, restart the Flannel pods with:"
echo "  kubectl -n kube-flannel delete pods --all"
echo ""
echo "NOTE: The Pod CIDRs shown in 'kubectl get nodes' may still show incorrect values,"
echo "but Flannel will now use the correct CIDRs configured in subnet.env on each node."
echo "======================================================================"
