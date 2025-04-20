#!/bin/bash
# ============================================================================
# 004_fix-Flannel_Subnet.sh - Helper script to configure flannel on worker nodes
# ============================================================================
# 
# DESCRIPTION:
#   This script configures Flannel CNI networking on worker nodes by setting the
#   correct pod CIDR based on node name/number. It creates the necessary subnet
#   environment file that Flannel uses to configure pod networking.
#
# USAGE:
#   ./004_fix-Flannel_Subnet.sh [--no-restart]
#
# ARGUMENTS:
#   --no-restart: Optional flag to skip kubelet restart (useful for control plane)
#
# ORDER OF USE:
#   1. This script is called automatically by the Join Worker Nodes script
#   2. It can also be run manually on any worker node that's having Flannel issues
#   3. Must be run after joining the cluster but before expecting network connectivity
#
# CIDR ALLOCATIONS:
#   - Service CIDR: 10.1.0.0/16 (defined during kubeadm init)
#   - Pod CIDR: 10.10.0.0/16 (used by Flannel)
#   - Node-specific pod CIDRs are defined in the environment configuration
#
# NOTES:
#   - Requires root privileges to run
#   - After running this script, the control plane node still needs to patch the
#     node with the correct pod CIDR using kubectl
#   - The hostname must follow the pattern that includes the node number
# ============================================================================

# Source the environment configuration
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
ENV_CONFIG_PATH="$(realpath "$SCRIPT_DIR/../0100-Chapter_1/001-Environment_Config.sh")"

if [ ! -f "$ENV_CONFIG_PATH" ]; then
    echo "Error: Environment configuration file not found at $ENV_CONFIG_PATH"
    exit 1
fi

source "$ENV_CONFIG_PATH"

# Set -e to exit on error
set -e

# Check for --no-restart flag
NO_RESTART=false
if [[ "$1" == "--no-restart" ]]; then
  NO_RESTART=true
fi

echo "======================================================================="
echo "Flannel Subnet Configuration Fix for Worker Nodes"
echo "======================================================================="

# Get current node properties
CURRENT_HOSTNAME=$(get_current_hostname)
NODE_POD_CIDR=$(get_current_node_property "pod_cidr")
NODE_INTERFACE=$(get_current_node_property "interface")

echo "Current hostname: $CURRENT_HOSTNAME"
echo "Using settings from environment configuration:"
echo "- Pod CIDR: $NODE_POD_CIDR"
echo "- Network Interface: $NODE_INTERFACE"

# If we couldn't find the node in the configuration, fall back to extraction from hostname
if [[ -z "$NODE_POD_CIDR" || -z "$NODE_INTERFACE" ]]; then
  echo "Warning: Could not find node settings in environment configuration, using fallback method."
  # Fallback: Extract node number from hostname
  if [[ $CURRENT_HOSTNAME =~ k8s-([0-9]+)[-] ]]; then
    NODE_NUM=${BASH_REMATCH[1]}
    # Remove any leading zeros
    NODE_NUM=$(echo $NODE_NUM | sed 's/^0*//')
  else
    # Fallback for alternative hostname formats
    NODE_NUM=${CURRENT_HOSTNAME##*-}
    # Remove any leading zeros
    NODE_NUM=$(echo $NODE_NUM | sed 's/^0*//')
  fi

  # Safety check to ensure we have a valid node number
  if [[ ! $NODE_NUM =~ ^[0-9]+$ ]]; then
    echo "Error: Could not extract valid node number from hostname."
    echo "Please ensure hostname follows the expected format (k8s-XX-*)"
    exit 1
  fi

  # Configure the pod CIDR based on node number
  NODE_POD_CIDR="10.10.${NODE_NUM}.0/24"
  
  # Default to eth0 for unknown nodes
  NODE_INTERFACE="eth0"
  
  echo "Fallback settings:"
  echo "- Extracted Node Number: $NODE_NUM"
  echo "- Pod CIDR: $NODE_POD_CIDR"
  echo "- Network Interface: $NODE_INTERFACE"
fi

echo "Configuring flannel subnet for $CURRENT_HOSTNAME with CIDR $NODE_POD_CIDR via interface $NODE_INTERFACE"

# Ensure CNI directory exists
mkdir -p /run/flannel

# Create subnet.env file with correct CIDR
echo "FLANNEL_NETWORK=$POD_CIDR" > /run/flannel/subnet.env
echo "FLANNEL_SUBNET=$NODE_POD_CIDR" >> /run/flannel/subnet.env
echo "FLANNEL_MTU=1450" >> /run/flannel/subnet.env
echo "FLANNEL_IPMASQ=true" >> /run/flannel/subnet.env
echo "FLANNEL_IFACE=$NODE_INTERFACE" >> /run/flannel/subnet.env

if [ "$NO_RESTART" = false ]; then
  echo "Subnet configured. Restarting kubelet..."
  systemctl restart kubelet
else
  echo "Subnet configured. Skipping kubelet restart as requested."
fi

echo "======================================================================="
echo "Flannel configuration complete!"
echo "Pod CIDR: $NODE_POD_CIDR"
echo "Network Interface: $NODE_INTERFACE"
echo "Please verify network connectivity with:"
echo "  kubectl get nodes -o wide"
echo "======================================================================="
