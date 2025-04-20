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
#   - Node-specific pod CIDRs:
#     - Node 01 (k8s-01-oci-01): 10.10.1.0/24
#     - Node 02 (k8s-02-oci-02): 10.10.2.0/24
#     - Node 03 (k8s-03-htg-01): 10.10.3.0/24
#
# NOTES:
#   - Requires root privileges to run
#   - After running this script, the control plane node still needs to patch the
#     node with the correct pod CIDR using kubectl
#   - The hostname must follow the pattern that includes the node number
# ============================================================================

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

# Extract node number from hostname
NODE_NAME=$(hostname)
echo "Current hostname: $NODE_NAME"

# Special case for the control plane node - assign 10.10.1.0/24
if [[ "$NODE_NAME" == "k8s-01-oci-01" ]]; then
  # Control plane gets 10.10.1.0/24 as configured in our requirements
  POD_CIDR="10.10.1.0/24"
else
  # For worker nodes, extract the node number and use it for CIDR
  if [[ $NODE_NAME =~ k8s-([0-9]+)[-] ]]; then
    NODE_NUM=${BASH_REMATCH[1]}
    # Remove any leading zeros
    NODE_NUM=$(echo $NODE_NUM | sed 's/^0*//')
  else
    # Fallback for alternative hostname formats
    NODE_NUM=${NODE_NAME##*-}
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
  POD_CIDR="10.10.${NODE_NUM}.0/24"
fi

echo "Configuring flannel subnet for $NODE_NAME with CIDR $POD_CIDR"

# Ensure CNI directory exists
mkdir -p /run/flannel

# Create subnet.env file with correct CIDR
echo "FLANNEL_NETWORK=10.10.0.0/16" > /run/flannel/subnet.env
echo "FLANNEL_SUBNET=$POD_CIDR" >> /run/flannel/subnet.env
echo "FLANNEL_MTU=1450" >> /run/flannel/subnet.env
echo "FLANNEL_IPMASQ=true" >> /run/flannel/subnet.env

if [ "$NO_RESTART" = false ]; then
  echo "Subnet configured. Restarting kubelet..."
  systemctl restart kubelet
else
  echo "Subnet configured. Skipping kubelet restart as requested."
fi

echo "======================================================================="
echo "Flannel configuration complete!"
echo "Pod CIDR: $POD_CIDR"
echo "Please verify network connectivity with:"
echo "  kubectl get nodes -o wide"
echo "======================================================================="
