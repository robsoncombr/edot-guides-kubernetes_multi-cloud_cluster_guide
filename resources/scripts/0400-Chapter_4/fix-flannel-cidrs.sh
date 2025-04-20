#!/bin/bash

# Fix Flannel subnet configuration on control plane node
echo "Fixing Flannel subnet on control plane node (k8s-01-oci-01)..."
mkdir -p /run/flannel
cat > /run/flannel/subnet.env << 'SUBNET_EOF'
FLANNEL_NETWORK=10.10.0.0/16
FLANNEL_SUBNET=10.10.1.0/24
FLANNEL_MTU=1450
FLANNEL_IPMASQ=true
FLANNEL_IFACE=enp0s6
SUBNET_EOF

echo "Control plane node Flannel subnet config:"
cat /run/flannel/subnet.env

echo 
echo "Commands to fix worker nodes:"
echo "==================================="
echo "For k8s-02-oci-02 (172.16.0.2), run:"
echo "mkdir -p /run/flannel"
echo "cat > /run/flannel/subnet.env << EOF"
echo "FLANNEL_NETWORK=10.10.0.0/16"
echo "FLANNEL_SUBNET=10.10.2.0/24"
echo "FLANNEL_MTU=1450"
echo "FLANNEL_IPMASQ=true"
echo "FLANNEL_IFACE=enp0s6"
echo "EOF"
echo
echo "For k8s-03-htg-01 (172.16.0.3), run:"
echo "mkdir -p /run/flannel"
echo "cat > /run/flannel/subnet.env << EOF"
echo "FLANNEL_NETWORK=10.10.0.0/16"
echo "FLANNEL_SUBNET=10.10.3.0/24"
echo "FLANNEL_MTU=1450"
echo "FLANNEL_IPMASQ=true"
echo "FLANNEL_IFACE=eth0"
echo "EOF"

echo
echo "After configuring all nodes, restart Flannel pods:"
echo "kubectl -n kube-flannel delete pods --all"
