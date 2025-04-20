#!/bin/bash

# ============================================================================
# 002-Fix_Node_CIDRs.sh - Script to fix Pod CIDR assignments
# ============================================================================
# 
# DESCRIPTION:
#   This script fixes Pod CIDR assignments for all nodes in the cluster,
#   ensuring they match the values defined in the environment configuration.
#
# USAGE:
#   ./002-Fix_Node_CIDRs.sh
#
# NOTES:
#   - Run this script on the control plane node after CNI setup
#   - This ensures the Kubernetes API and Flannel use consistent CIDR ranges
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
echo "Fixing Pod CIDR assignments for all nodes"
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

echo "Current Pod CIDR assignments:"
kubectl get nodes -o custom-columns=NAME:.metadata.name,INTERNAL-IP:.status.addresses[0].address,POD-CIDR:.spec.podCIDR,STATUS:.status.conditions[-1].type
echo ""

# Fix CIDR for each node
for NODE_CONFIG in "${ALL_NODES[@]}"; do
    NODE_NAME=$(get_node_property "$NODE_CONFIG" 0)
    NODE_POD_CIDR=$(get_node_property "$NODE_CONFIG" 2)
    CURRENT_CIDR=$(kubectl get node "$NODE_NAME" -o jsonpath='{.spec.podCIDR}' 2>/dev/null || echo "")
    
    if [ -z "$CURRENT_CIDR" ]; then
        echo "Patching node $NODE_NAME with Pod CIDR: $NODE_POD_CIDR"
        kubectl patch node "$NODE_NAME" -p "{\"spec\":{\"podCIDR\":\"$NODE_POD_CIDR\",\"podCIDRs\":[\"$NODE_POD_CIDR\"]}}"
    elif [ "$CURRENT_CIDR" != "$NODE_POD_CIDR" ]; then
        echo "Fixing Pod CIDR for $NODE_NAME: changing from $CURRENT_CIDR to $NODE_POD_CIDR"
        kubectl patch node "$NODE_NAME" -p "{\"spec\":{\"podCIDR\":\"$NODE_POD_CIDR\",\"podCIDRs\":[\"$NODE_POD_CIDR\"]}}"
    else
        echo "Node $NODE_NAME already has the correct Pod CIDR: $NODE_POD_CIDR"
    fi
done

echo ""
echo "Updated Pod CIDR assignments:"
kubectl get nodes -o custom-columns=NAME:.metadata.name,INTERNAL-IP:.status.addresses[0].address,POD-CIDR:.spec.podCIDR,STATUS:.status.conditions[-1].type
echo ""

echo "======================================================================"
echo "Pod CIDR fix complete!"
echo ""
echo "You may need to restart Flannel pods to ensure they use the correct CIDRs."
echo "You can do this with:"
echo "  kubectl -n kube-flannel delete pods --all"
echo "======================================================================"
