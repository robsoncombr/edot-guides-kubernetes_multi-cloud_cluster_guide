#!/bin/bash

# 004-Join_Worker_Nodes.sh - Script to join worker nodes to the Kubernetes cluster

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

# Path to the Flannel fix script
FLANNEL_FIX_SCRIPT="/root/data/development/edot-guides-kubernetes_multi-cloud_cluster_guide/resources/scripts/0300-Chapter_3/004_fix-Flannel_Subnet_Worker_Nodes.sh"

# Apply Flannel subnet fix
echo "Applying Flannel subnet configuration fix..."
if [ -f "$FLANNEL_FIX_SCRIPT" ]; then
    # Execute the fix script
    "$FLANNEL_FIX_SCRIPT"
else
    echo "Warning: Flannel fix script not found at $FLANNEL_FIX_SCRIPT"
    echo "You may need to manually configure Flannel networking after joining."
fi

echo "======================================================================"
echo "Worker node joined and network configured successfully!"
echo "Node will appear in 'kubectl get nodes' on the control plane"
echo "Note: It may take a minute for the node to become Ready"
echo "======================================================================"
