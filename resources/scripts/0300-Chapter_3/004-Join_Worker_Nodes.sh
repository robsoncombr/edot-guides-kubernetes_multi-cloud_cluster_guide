#!/bin/bash

# ============================================================================
# 004-Join_Worker_Nodes.sh - Script to join worker nodes to the Kubernetes cluster
# ============================================================================
# 
# DESCRIPTION:
#   This script joins a worker node to an existing Kubernetes cluster and 
#   automatically configures the Flannel CNI network settings with the 
#   appropriate pod CIDR.
#
# USAGE:
#   ./004-Join_Worker_Nodes.sh 'kubeadm join ... --token ... --discovery-token-ca-cert-hash ...'
#
# ARGUMENTS:
#   $1 - The 'kubeadm join' command to use for joining the cluster
#
# ORDER OF USE:
#   1. Run Chapter 3 master node initialization script first
#   2. Run this script on each worker node with the join command
#   3. After all nodes join, verify with 'kubectl get nodes' on control plane
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
#   - After joining, the node's pod CIDR must be patched on the control plane
#   - The script will attempt to configure Flannel with the appropriate subnet
#   - Requires root privileges to run
# ============================================================================

echo "======================================================================"
echo "Joining Worker Nodes to Kubernetes Cluster"
echo "======================================================================"

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

# Check if join command is provided
if [ -z "$1" ]; then
    echo "Error: No join command provided."
    echo "Usage: $0 'kubeadm join ... --token ... --discovery-token-ca-cert-hash ...'"
    exit 1
fi

JOIN_COMMAND="$1"

echo "Joining this node to the Kubernetes cluster..."
echo "Using command: $JOIN_COMMAND"

# Execute the join command
$JOIN_COMMAND

if [ $? -ne 0 ]; then
    echo "Error: Failed to join the cluster. Check the join command and try again."
    exit 1
fi

echo "Node joined successfully!"

# Path to the Flannel fix script from Chapter 4
FLANNEL_FIX_SCRIPT="$(dirname "$0")/../0400-Chapter_4/001_fix-Flannel_Subnet.sh"

# Apply Flannel subnet fix
echo "Applying Flannel subnet configuration fix..."
if [ -f "$FLANNEL_FIX_SCRIPT" ]; then
    # Execute the fix script
    echo "Using the centralized Flannel fix script..."
    bash "$FLANNEL_FIX_SCRIPT"
else
    echo "Error: Flannel fix script not found at $FLANNEL_FIX_SCRIPT"
    echo "Cannot configure Flannel networking properly. Please ensure the fix script exists."
    exit 1
fi

# Extract node details for the informational message
NODE_NAME=$(hostname)
if [[ $NODE_NAME =~ ([0-9]+)$ ]]; then
    NODE_NUM=${BASH_REMATCH[1]}
else
    NODE_NUM=${NODE_NAME##*-}
    NODE_NUM=${NODE_NUM##*0}
fi
POD_CIDR="10.10.${NODE_NUM}.0/24"

echo "======================================================================"
echo "Worker node joined and network configured successfully!"
echo "Node will appear in 'kubectl get nodes' on the control plane"
echo "Note: The control plane node must patch this node with the correct Pod CIDR:"
echo ""
echo "IMPORTANT: On the control plane node, run:"
echo "  kubectl patch node $(hostname) -p '{\"spec\":{\"podCIDR\":\"$POD_CIDR\",\"podCIDRs\":[\"$POD_CIDR\"]}}'"
echo ""
echo "Note: It may take a minute for the node to become Ready"
echo "======================================================================"
