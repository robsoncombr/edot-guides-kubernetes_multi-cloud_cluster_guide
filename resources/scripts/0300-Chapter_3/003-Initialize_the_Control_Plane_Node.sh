#!/bin/bash

# ============================================================================
# 003-Initialize_the_Control_Plane_Node.sh - Initialize Kubernetes control plane
# ============================================================================
# 
# DESCRIPTION:
#   This script initializes the Kubernetes control plane node with the specified
#   configuration. It uses kubeadm to bootstrap the control plane and sets up
#   the basic configuration needed for a multi-cloud cluster.
#
# USAGE:
#   ./003-Initialize_the_Control_Plane_Node.sh
#
# NOTES:
#   - This script should be run on the designated control plane node only
#   - After running this script, set up CNI (Chapter 4) before joining worker nodes
# ============================================================================

# Source the environment configuration
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
ENV_CONFIG_PATH="$(realpath "$SCRIPT_DIR/../0100-Chapter_1/001-Environment_Config.sh")"

if [ ! -f "$ENV_CONFIG_PATH" ]; then
    echo "Error: Environment configuration file not found at $ENV_CONFIG_PATH"
    exit 1
fi

source "$ENV_CONFIG_PATH"

echo "======================================================================"
echo "Pre-flight checks for Kubernetes control plane initialization"
echo "======================================================================"

# Check 1: Ensure running as root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# Check 2: Verify this is the correct control plane node
CURRENT_HOSTNAME=$(get_current_hostname)
CONTROL_PLANE_HOSTNAME=$(get_node_property "${NODE_CP1}" 0)
if [[ "$CURRENT_HOSTNAME" != "$CONTROL_PLANE_HOSTNAME" ]]; then
    echo "Error: This script must be run on the control plane node ($CONTROL_PLANE_HOSTNAME)"
    echo "Current host: $CURRENT_HOSTNAME"
    exit 1
fi

# Check 3: Validate Pod CIDR format
if [[ "$POD_CIDR" == *"X"* ]]; then
    echo "Error: Invalid Pod CIDR found in environment config: $POD_CIDR"
    echo "Please update the POD_CIDR in $ENV_CONFIG_PATH to use a valid CIDR notation"
    echo "For example: POD_CIDR=\"10.10.0.0/16\""
    exit 1
fi

# Check 4: Verify network interface exists
NODE_INTERFACE=$(get_current_node_property "interface")
if ! ip link show "$NODE_INTERFACE" &>/dev/null; then
    echo "Error: Network interface $NODE_INTERFACE not found on this host"
    echo "Available interfaces:"
    ip -br link show
    echo "Please update the interface value in $ENV_CONFIG_PATH"
    exit 1
fi

# Check 5: Verify Docker/containerd is running
if ! systemctl is-active --quiet containerd; then
    echo "Error: containerd is not running"
    echo "Please ensure containerd is installed and running:"
    echo "  systemctl start containerd"
    exit 1
fi

# Check 6: Verify kubeadm, kubelet, and kubectl are installed
for cmd in kubeadm kubelet kubectl; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: $cmd not found or not in PATH"
        echo "Please ensure Kubernetes components are properly installed"
        exit 1
    fi
done

# Check 7: Verify port availability
for port in 6443 10250 10251 10252; do
    if ss -tulwn | grep -q ":$port "; then
        echo "Error: Port $port is already in use"
        echo "Kubernetes requires this port to be available"
        exit 1
    fi
done

# Check 8: Check if swap is disabled
SWAP_ENABLED=$(free | grep -i swap | awk '{print $2}')
if [ "$SWAP_ENABLED" != "0" ]; then
    echo "Warning: Swap appears to be enabled. Kubernetes requires swap to be disabled."
    echo "Calling the swap disabling script..."
    
    # Call the existing swap disabling script
    DISABLE_SWAP_SCRIPT="$(realpath "$SCRIPT_DIR/../0200-Chapter_2/003-Disable-Swap.sh")"
    if [ -f "$DISABLE_SWAP_SCRIPT" ]; then
        bash "$DISABLE_SWAP_SCRIPT"
        
        # Verify swap is now disabled
        SWAP_ENABLED=$(free | grep -i swap | awk '{print $2}')
        if [ "$SWAP_ENABLED" != "0" ]; then
            echo "Error: Swap is still enabled after running the disabling script."
            echo "Please check why swap disabling failed and try again."
            exit 1
        else
            echo "Swap successfully disabled. Continuing with installation."
        fi
    else
        echo "Error: Swap disabling script not found at $DISABLE_SWAP_SCRIPT"
        echo "Attempting to disable swap manually..."
        swapoff -a
        sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab
        
        # Verify swap is now disabled
        SWAP_ENABLED=$(free | grep -i swap | awk '{print $2}')
        if [ "$SWAP_ENABLED" != "0" ]; then
            echo "Error: Failed to disable swap. Please disable swap manually before continuing."
            exit 1
        else
            echo "Swap successfully disabled manually. Continuing with installation."
        fi
    fi
else
    echo "Swap is already disabled. Continuing with installation."
fi

echo "All pre-flight checks passed. Proceeding with control plane initialization..."
echo "======================================================================"

# Get current node properties
NODE_IP=$(get_current_node_property "vpn_ip")
NODE_INTERFACE=$(get_current_node_property "interface")
NODE_POD_CIDR=$(get_current_node_property "pod_cidr")

echo "Initializing control plane node: $CURRENT_HOSTNAME"
echo "Node IP: $NODE_IP"
echo "Network Interface: $NODE_INTERFACE"
echo "Pod CIDR: $NODE_POD_CIDR"

# Create kubeadm configuration file
cat > /tmp/kubeadm-config.yaml << EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
nodeRegistration:
  name: $CURRENT_HOSTNAME
  kubeletExtraArgs:
    node-ip: "$NODE_IP"
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: $K8S_VERSION
networking:
  serviceSubnet: "$SERVICE_CIDR"
  podSubnet: "$POD_CIDR"
controlPlaneEndpoint: "$CONTROL_PLANE_ENDPOINT"
apiServer:
  certSANs:
  - "$NODE_IP"
controllerManager:
  extraArgs:
    # Configure the controller manager to use specific CIDR ranges
    cluster-cidr: "$POD_CIDR"
    node-cidr-mask-size: "24"
    allocate-node-cidrs: "true"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF

# Initialize the Kubernetes control plane
echo "Initializing Kubernetes control plane..."

# Ensure kubelet is enabled before initialization
echo "Enabling kubelet service..."
systemctl enable kubelet.service

kubeadm init --config=/tmp/kubeadm-config.yaml --upload-certs --v=5 | tee /tmp/kubeadm-init.log

# Set up kubeconfig for the root user
echo "Setting up kubeconfig for root user..."
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# Patch the control plane node to use the correct CIDR range
echo "Patching control plane node with specific CIDR range..."
kubectl patch node $CURRENT_HOSTNAME -p "{\"spec\":{\"podCIDR\":\"$NODE_POD_CIDR\",\"podCIDRs\":[\"$NODE_POD_CIDR\"]}}" || \
  echo "Note: Could not patch the node CIDR immediately. This will be handled in the CNI setup script."

# Display kubeconfig setup message
echo ""
echo "==========================================================================="
echo "kubectl configuration set up successfully for admin user!"
echo ""
echo "Testing kubectl configuration:"
echo ""
kubectl get nodes
echo ""
echo "Checking system pods:"
echo ""
kubectl get pods -n kube-system
echo ""
echo "NOTE: At this point, the control plane node will show as 'Pending' or 'NotReady'"
echo "This is expected because we haven't installed a CNI plugin yet."
echo "==========================================================================="

# Display join command for worker nodes
echo ""
echo "==========================================================================="
echo "Control plane initialization complete!"
echo ""
echo "To join other control-plane node, run the following command on that node:"
grep -B 2 "\--control-plane" /tmp/kubeadm-init.log
echo "To join worker nodes to this cluster, run the following command on each node:"
tail -n 2 /tmp/kubeadm-init.log
echo ""
echo "IMPORTANT:"
echo "- A full log of this command was saved to:"
echo "  > $(ls -ls /tmp/kubeadm-init.log)"
echo "- The log contains the join secrets, be sure you delete it or move to a safe place"
echo "- Do *not* join worker nodes until you've installed a CNI plugin (Chapter 4)"
echo "==========================================================================="

echo ""
echo "NEXT STEP:"
echo "1. Install a CNI plugin (Chapter 4) to enable networking in the cluster."
echo "2. After installing the CNI plugin, you can back (Chapter 3) to join worker nodes."
echo ""

# Clean up
rm -f /tmp/kubeadm-config.yaml
