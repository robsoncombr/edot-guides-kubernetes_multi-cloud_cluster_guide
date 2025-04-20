#!/bin/bash

# Script to fix certificate issues on worker nodes
echo "====================================================================="
echo "Fixing certificate issues on worker nodes"
echo "====================================================================="

# Define worker nodes
WORKER_NODES=("k8s-02-oci-02:172.16.0.2" "k8s-03-htg-01:172.16.0.3")

# Function to fix certificates on a node
fix_node_certs() {
    local node_name=$(echo $1 | cut -d: -f1)
    local node_ip=$(echo $1 | cut -d: -f2)
    
    echo "Fixing certificates on $node_name ($node_ip)"
    
    # Copy the CA certificate and kubeconfig files to the worker node
    echo "Copying CA certificate and kubeconfig files..."
    scp -o StrictHostKeyChecking=no /etc/kubernetes/pki/ca.crt root@${node_ip}:/etc/kubernetes/pki/
    scp -o StrictHostKeyChecking=no /etc/kubernetes/kubelet.conf root@${node_ip}:/etc/kubernetes/
    
    # Restart kubelet on the worker node
    echo "Restarting kubelet service..."
    ssh -o StrictHostKeyChecking=no root@${node_ip} "systemctl restart kubelet"
    
    # Set correct node IP if needed
    echo "Updating node IP configuration..."
    ssh -o StrictHostKeyChecking=no root@${node_ip} "echo 'KUBELET_EXTRA_ARGS=\"--node-ip=${node_ip}\"' > /etc/default/kubelet && systemctl restart kubelet"
    
    echo "Certificate fix completed for $node_name"
    echo "-------------------------------------------------------------------"
}

# Make sure the PKI directory exists on worker nodes
for node in "${WORKER_NODES[@]}"; do
    node_ip=$(echo $node | cut -d: -f2)
    ssh -o StrictHostKeyChecking=no root@${node_ip} "mkdir -p /etc/kubernetes/pki"
done

# Fix certificates on each worker node
for node in "${WORKER_NODES[@]}"; do
    fix_node_certs "$node"
done

echo "====================================================================="
echo "Certificate fix complete. Checking node status in 10 seconds..."
sleep 10
kubectl get nodes -o wide
echo "====================================================================="
