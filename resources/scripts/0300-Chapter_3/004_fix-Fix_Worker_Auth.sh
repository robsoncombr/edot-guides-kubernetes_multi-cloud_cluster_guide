#!/bin/bash
echo "====================================================================="
echo "Fixing worker node authentication issues"
echo "====================================================================="

# Define worker nodes
WORKER_NODES=("k8s-02-oci-02:172.16.0.2" "k8s-03-htg-01:172.16.0.3")

# Generate a new bootstrap token
echo "Generating new bootstrap token..."
BOOTSTRAP_TOKEN=$(kubeadm token create)
DISCOVERY_CA_CERT_HASH=$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | \
                         openssl rsa -pubin -outform der 2>/dev/null | \
                         openssl dgst -sha256 -hex | sed 's/^.* //')
API_SERVER="172.16.0.1:6443"

echo "New token: $BOOTSTRAP_TOKEN"
echo "CA Cert Hash: $DISCOVERY_CA_CERT_HASH"

# Function to fix node authentication
fix_node_auth() {
    local node_name=$(echo $1 | cut -d: -f1)
    local node_ip=$(echo $1 | cut -d: -f2)
    
    echo "-------------------------------------------------------------------"
    echo "Fixing authentication on $node_name ($node_ip)"
    
    # Create a valid kubelet.conf for this node
    cat > /tmp/kubelet.conf << EOL
apiVersion: v1
clusters:
- cluster:
    certificate-authority: /etc/kubernetes/pki/ca.crt
    server: https://${API_SERVER}
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: system:node:${node_name}
  name: system:node:${node_name}@kubernetes
current-context: system:node:${node_name}@kubernetes
kind: Config
preferences: {}
users:
- name: system:node:${node_name}
  user:
    token: ${BOOTSTRAP_TOKEN}
EOL

    # Copy the kubelet.conf file to the worker node
    echo "Copying kubelet configuration files..."
    scp -o StrictHostKeyChecking=no /tmp/kubelet.conf root@${node_ip}:/etc/kubernetes/
    
    # Set correct node IP
    echo "Updating node IP configuration..."
    ssh -o StrictHostKeyChecking=no root@${node_ip} "echo 'KUBELET_EXTRA_ARGS=\"--node-ip=${node_ip}\"' > /etc/default/kubelet"
    
    # Reset kubelet and kubernetes directories on the node
    echo "Resetting kubelet configuration on $node_name..."
    ssh -o StrictHostKeyChecking=no root@${node_ip} "systemctl stop kubelet && \
        rm -f /etc/kubernetes/bootstrap-kubelet.conf || true && \
        rm -f /var/lib/kubelet/config.yaml || true && \
        mkdir -p /etc/kubernetes/manifests"
    
    # Restart kubelet
    echo "Restarting kubelet on $node_name..."
    ssh -o StrictHostKeyChecking=no root@${node_ip} "systemctl daemon-reload && systemctl restart kubelet"
    
    echo "Authentication fix completed for $node_name"
}

# Fix authentication on each worker node
for node in "${WORKER_NODES[@]}"; do
    fix_node_auth "$node"
done

echo "====================================================================="
echo "Authentication fix complete. Checking node status in 20 seconds..."
sleep 20
kubectl get nodes -o wide
echo "====================================================================="

# Clean up
rm -f /tmp/kubelet.conf
