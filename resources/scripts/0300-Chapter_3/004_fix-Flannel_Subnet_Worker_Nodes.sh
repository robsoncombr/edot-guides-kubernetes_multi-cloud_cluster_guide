#!/bin/bash
# 004_fix-Flannel_Subnet.sh - Helper script to configure flannel on worker nodes properly
# This configures the correct pod CIDR based on the node name pattern and hostname

# Set -e to exit on error
set -e

echo "======================================================================="
echo "Flannel Subnet Configuration Fix for Worker Nodes"
echo "======================================================================="

# Extract node number from hostname
NODE_NAME=$(hostname)
echo "Current hostname: $NODE_NAME"

# Extract node number using pattern matching
if [[ $NODE_NAME =~ ([0-9]+)$ ]]; then
  NODE_NUM=${BASH_REMATCH[1]}
else
  # Default fallback if pattern doesn't match
  NODE_NUM=${NODE_NAME##*-}
  NODE_NUM=${NODE_NUM##*0}
fi

# Safety check to ensure we have a valid node number
if [[ ! $NODE_NUM =~ ^[0-9]+$ ]]; then
  echo "Error: Could not extract valid node number from hostname."
  echo "Using default node number 1."
  NODE_NUM=1
fi

# Configure the pod CIDR based on node number
POD_CIDR="10.10.${NODE_NUM}.0/24"

echo "Configuring flannel subnet for $NODE_NAME with CIDR $POD_CIDR"

# Ensure CNI directory exists
mkdir -p /run/flannel

# Create subnet.env file with correct CIDR
echo "FLANNEL_NETWORK=10.10.0.0/16" > /run/flannel/subnet.env
echo "FLANNEL_SUBNET=$POD_CIDR" >> /run/flannel/subnet.env
echo "FLANNEL_MTU=1450" >> /run/flannel/subnet.env
echo "FLANNEL_IPMASQ=true" >> /run/flannel/subnet.env

echo "Subnet configured. Restarting kubelet..."
systemctl restart kubelet

echo "======================================================================="
echo "Flannel configuration complete!"
echo "Pod CIDR: $POD_CIDR"
echo "Please verify network connectivity with:"
echo "  kubectl get nodes -o wide"
echo "======================================================================="
