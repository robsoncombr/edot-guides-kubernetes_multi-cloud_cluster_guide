#!/bin/bash

# First Apply Fixes
#./002_fix-Duplicate_Repository_Entries.sh #* this fix was removed since we implemented the correct removal keys and repositories when running '/resources/scripts/0399-Chapter_3-Addendums/0399-Chapter_3-Addendum-Cleaning_Up_Kubernetes_Before_Fresh_Installation.sh'

# Source the environment configuration
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
ENV_CONFIG_PATH="$(realpath "$SCRIPT_DIR/../0100-Chapter_1/001-Environment_Config.sh")"

if [ ! -f "$ENV_CONFIG_PATH" ]; then
    echo "Error: Environment configuration file not found at $ENV_CONFIG_PATH"
    exit 1
fi

source "$ENV_CONFIG_PATH"

# Define Kubernetes version (strip the 'v' prefix if present)
KUBERNETES_VERSION=${K8S_VERSION#v}
KUBERNETES_MAJOR_MINOR=$(echo $KUBERNETES_VERSION | cut -d. -f1,2)

# Function to get formatted timestamp for logging
get_timestamp() {
    date "+%y%m%d-%H%M%S"
}

# Log with timestamp and hostname prefix
log_message() {
    echo "[$(hostname): $(get_timestamp)] $1"
}

log_message "Starting Kubernetes repository setup and component installation"
log_message "Kubernetes version: $KUBERNETES_VERSION"

# Create a script to add Kubernetes repositories and install components
cat > /tmp/install_kubernetes.sh << 'EOF'
#!/bin/bash

# Function to get formatted timestamp for logging
get_timestamp() {
    date "+%y-%m-%d %H:%M:%S"
}

# Log with timestamp and hostname prefix
log_message() {
    echo "[$(hostname): $(get_timestamp)] $1"
}

# Get system architecture
ARCH=$(dpkg --print-architecture)
log_message "Detected system architecture: $ARCH"

# Add Kubernetes GPG key
log_message "Adding Kubernetes GPG key..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION}/deb/Release.key | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-archive-keyring.gpg

# Add Kubernetes apt repository with architecture detection
log_message "Adding Kubernetes apt repository..."
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-archive-keyring.gpg arch=$ARCH] https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list

# Update package listings
log_message "Updating package listings..."
apt-get update

# Install kubelet, kubeadm, and kubectl
log_message "Installing Kubernetes components..."
apt-get install -y kubelet kubeadm kubectl etcd-client containernetworking-plugins

# Pin the installed packages at their current versions to prevent automatic updates
log_message "Pinning package versions..."
apt-mark hold kubelet kubeadm kubectl

log_message "Kubernetes components installed successfully"

# Verify installation
KUBECTL_VERSION=$(kubectl version --client -o yaml 2>/dev/null | grep "gitVersion" | head -n 1 || echo "Not installed")
KUBEADM_VERSION=$(kubeadm version -o yaml 2>/dev/null | grep "gitVersion" | head -n 1 || echo "Not installed")
KUBELET_VERSION=$(kubelet --version 2>/dev/null || echo "Not installed")

log_message "kubectl: $KUBECTL_VERSION"
log_message "kubeadm: $KUBEADM_VERSION"
log_message "kubelet: $KUBELET_VERSION"
EOF

# Replace the placeholder with the actual Kubernetes version
sed -i "s/\${KUBERNETES_VERSION}/$KUBERNETES_MAJOR_MINOR/g" /tmp/install_kubernetes.sh

# Make the script executable
chmod +x /tmp/install_kubernetes.sh

# Execute on all nodes
log_message "Installing Kubernetes components on local node $(hostname)..."
bash /tmp/install_kubernetes.sh

# Install on worker nodes
for NODE_CONFIG in "${ALL_NODES[@]}"; do
    NODE_NAME=$(get_node_property "$NODE_CONFIG" 0)
    NODE_IP=$(get_node_property "$NODE_CONFIG" 1)
    
    # Skip the local node (already handled)
    if [[ "$NODE_NAME" == "$(hostname)" ]]; then
        continue
    fi
    
    log_message "Installing Kubernetes components on $NODE_NAME ($NODE_IP)..."
    scp /tmp/install_kubernetes.sh root@$NODE_IP:/tmp/
    ssh root@$NODE_IP "bash /tmp/install_kubernetes.sh && rm -f /tmp/install_kubernetes.sh"
done

log_message "Removing temporary installation script..."
rm -f /tmp/install_kubernetes.sh

log_message "Kubernetes installation completed on all nodes"
