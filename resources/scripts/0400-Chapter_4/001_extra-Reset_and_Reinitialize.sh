#!/bin/bash
# ============================================================================
# Script to reset and reinitialize Kubernetes cluster
# ============================================================================
# 
# DESCRIPTION:
#   This script performs a complete reset of the Kubernetes cluster and CNI,
#   then reinitializes it with the correct CIDR configurations. Use this when
#   you need to reset and reconfigure an existing cluster.
#
# USAGE:
#   ./001_extra-Reset_and_Reinitialize.sh
#
# NOTES:
#   - Requires root privileges to run
#   - Will completely reset the Kubernetes cluster
#   - All workloads will be lost
#   - Only run this script when you want to start fresh
# ============================================================================

set -e

echo "========================================================================"
echo "CAUTION: This will completely reset your Kubernetes cluster!"
echo "All workloads and configurations will be lost."
echo "Press Ctrl+C within 5 seconds to cancel..."
echo "========================================================================"
sleep 5

echo "Step 1: Draining the nodes..."
# Force drain the node (ignore errors since we're resetting anyway)
kubectl drain k8s-01-oci-01 --delete-emptydir-data --force --ignore-daemonsets || true

echo "Step 2: Removing Flannel CNI resources..."
# Delete flannel resources, ignore errors if not found
kubectl delete namespace kube-flannel || true
kubectl delete -f /tmp/kube-flannel.yaml || true

echo "Step 3: Resetting kubeadm..."
kubeadm reset -f

echo "Step 4: Cleaning up CNI files and configurations..."
# Clean up CNI configurations
rm -rf /etc/cni/net.d/*
rm -rf /run/flannel
rm -rf $HOME/.kube/config
rm -rf /var/lib/cni/

# Clean up iptables and ip routes related to CNI
ip link delete cni0 || true
ip link delete flannel.1 || true

# Restart containerd to ensure clean state
systemctl restart containerd

echo "Step 5: Reinitializing the Kubernetes cluster..."
# Run the initialization script with the fixed config
bash $(dirname "$0")/../0300-Chapter_3/003-Initialize_the_Control_Plane_Node.sh


echo "Step 6: Applying Flannel CNI..."
sleep 10 # Give some time for the API server to become ready
bash $(dirname "$0")/../0400-Chapter_4/001-CNI_Setup.sh

echo "========================================================================"
echo "Kubernetes cluster has been reset and reinitialized with correct CIDRs!"
echo "Control plane node should now be using CIDR: 10.10.1.0/24"
echo "Verify the configuration with: kubectl get nodes -o wide"
echo "========================================================================"

# Display the result
kubectl get nodes -o custom-columns=NAME:.metadata.name,INTERNAL-IP:.status.addresses[0].address,POD-CIDR:.spec.podCIDR
