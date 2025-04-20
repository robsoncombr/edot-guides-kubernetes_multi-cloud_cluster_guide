#!/bin/bash

# Define Kubernetes version
KUBERNETES_VERSION=1.32

# First Apply Fixes
#./002_fix-Duplicate_Repository_Entries.sh #* this fix was removed since we implemented the correct removal keys and repositories when running '/resources/scripts/0399-Chapter_3-Addendums/0399-Chapter_3-Addendum-Cleaning_Up_Kubernetes_Before_Fresh_Installation.sh'

# Create a script to add Kubernetes repositories and install components
cat > /tmp/install_kubernetes.sh << EOF
#!/bin/bash

# Add Kubernetes GPG key
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-archive-keyring.gpg

# Add Kubernetes apt repository
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-archive-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list

# Update package listings
apt-get update

# Install kubelet, kubeadm, and kubectl
apt-get install -y kubelet kubeadm kubectl etcd-client containernetworking-plugins

# Pin the installed packages at their current versions to prevent automatic updates
apt-mark hold kubelet kubeadm kubectl

echo "Kubernetes components installed on \$(hostname)"
EOF

# Make the script executable
chmod +x /tmp/install_kubernetes.sh

# Execute on all nodes
echo "Installing Kubernetes components on 172.16.0.1..."
bash /tmp/install_kubernetes.sh
for NODE in 172.16.0.2 172.16.0.3; do
  echo "Installing Kubernetes components on $NODE..."
  scp /tmp/install_kubernetes.sh root@$NODE:/tmp/
  ssh root@$NODE "bash /tmp/install_kubernetes.sh && rm -f /tmp/install_kubernetes.sh"
done
rm -f /tmp/install_kubernetes.sh
