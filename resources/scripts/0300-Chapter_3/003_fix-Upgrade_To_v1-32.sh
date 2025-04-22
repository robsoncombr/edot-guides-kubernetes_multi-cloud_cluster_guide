#!/bin/bash

#* This fix was created during work on the guide to assist with the ad-hoc upgrade to Kubernetes v1.32.
#* The solution is implemented by setting the KUBERNETES_VERSION variable in the 
#* 001-Add_Kubernetes_Repositories_and_Install.sh script.

# First, perform a cleanup of the old installation
echo "Cleaning up existing Kubernetes installation..."

# Create cleanup script
cat > /tmp/cleanup_k8s.sh << 'EOF'
#!/bin/bash
# Reset kubeadm (only on control plane)
if command -v kubeadm &>/dev/null; then
  kubeadm reset -f
fi

# Stop and disable kubelet
systemctl stop kubelet
systemctl disable kubelet

# Remove kubeconfig files
rm -rf /etc/kubernetes
rm -rf $HOME/.kube

# Clean up CNI configurations
rm -rf /etc/cni/net.d

# Clean up kubernetes directories
rm -rf /var/lib/kubelet
rm -rf /var/lib/etcd

# Remove Kubernetes packages
apt-mark unhold kubelet kubeadm kubectl
apt-get remove -y kubelet kubeadm kubectl
apt-get autoremove -y

# Remove repository
rm -f /etc/apt/keyrings/kubernetes-archive-keyring.gpg
rm -f /etc/apt/sources.list.d/kubernetes.list

echo "Kubernetes cleanup completed on $(hostname)"
EOF

chmod +x /tmp/cleanup_k8s.sh

# Run cleanup on all nodes
echo "Cleaning up control plane node..."
bash /tmp/cleanup_k8s.sh

for NODE in 172.16.0.2 172.16.0.3; do
  echo "Cleaning up node $NODE..."
  scp /tmp/cleanup_k8s.sh root@$NODE:/tmp/
  ssh root@$NODE "bash /tmp/cleanup_k8s.sh && rm -f /tmp/cleanup_k8s.sh"
done
rm -f /tmp/cleanup_k8s.sh

# Now install the correct version
echo "Installing Kubernetes v1.32..."

# Create installation script
cat > /tmp/install_kubernetes.sh << 'EOF'
#!/bin/bash

# Add Kubernetes GPG key
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-archive-keyring.gpg

# Add Kubernetes apt repository for v1.32
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-archive-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list

# Update package listings
apt-get update

# Install kubelet, kubeadm, and kubectl
apt-get install -y kubelet kubeadm kubectl etcd-client containernetworking-plugins

# Pin the installed packages at their current versions to prevent automatic updates
apt-mark hold kubelet kubeadm kubectl

echo "Kubernetes v1.32 components installed on $(hostname)"
EOF

chmod +x /tmp/install_kubernetes.sh

# Run installation on all nodes
echo "Installing on control plane node..."
bash /tmp/install_kubernetes.sh

for NODE in 172.16.0.2 172.16.0.3; do
  echo "Installing on node $NODE..."
  scp /tmp/install_kubernetes.sh root@$NODE:/tmp/
  ssh root@$NODE "bash /tmp/install_kubernetes.sh && rm -f /tmp/install_kubernetes.sh"
done
rm -f /tmp/install_kubernetes.sh

echo "Installation complete! You can now re-run the control plane initialization script."
