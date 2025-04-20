#!/bin/bash

# Source the environment configuration
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
ENV_CONFIG_PATH="$(realpath "$SCRIPT_DIR/../0100-Chapter_1/001-Environment_Config.sh")"

if [ ! -f "$ENV_CONFIG_PATH" ]; then
    echo "Error: Environment configuration file not found at $ENV_CONFIG_PATH"
    exit 1
fi

source "$ENV_CONFIG_PATH"

# Get current node properties
CURRENT_HOSTNAME=$(get_current_hostname)
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
