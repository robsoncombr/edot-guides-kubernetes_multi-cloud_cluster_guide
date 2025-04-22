#!/bin/bash

# Required parameters
if [ "$#" -lt 3 ]; then
  echo "Usage: $0 <node_hostname> <node_ip> <node_interface>"
  echo "Example: $0 k8s-04-aws-01 172.16.0.4 ens5"
  exit 1
fi

NODE_NAME=$1
NODE_IP=$2
NODE_INTERFACE=$3

# Load environment config
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
ENV_CONFIG_PATH="$(realpath "$SCRIPT_DIR/../0100-Chapter_1/001-Environment_Config.sh")"

if [ ! -f "$ENV_CONFIG_PATH" ]; then
    echo "Error: Environment configuration file not found at $ENV_CONFIG_PATH"
    exit 1
fi

source "$ENV_CONFIG_PATH"

# Extract POD_CIDR prefix
POD_CIDR_PREFIX=$(echo "$POD_CIDR" | cut -d '.' -f 1-2)

# Generate node number for CIDR assignment - ensure no leading zeros
NODE_NUM=$(echo "$NODE_NAME" | grep -oE '[0-9]+$' || echo "0")
NODE_NUM=$((10#$NODE_NUM)) # Force decimal interpretation
NODE_CIDR="${POD_CIDR_PREFIX}.${NODE_NUM}.0/24"

echo "Using CIDR $NODE_CIDR for node $NODE_NAME"

# Create setup script
TEMP_SCRIPT="/tmp/setup-cni-$NODE_NAME.sh"

cat > $TEMP_SCRIPT << EOFSCRIPT
#!/bin/bash
# CNI Setup script for $NODE_NAME

# Create required directories
mkdir -p /etc/cni/net.d
mkdir -p /opt/cni/bin
mkdir -p /run/flannel

# Create CNI configuration
cat > /etc/cni/net.d/10-flannel.conflist << 'EOFCNI'
{
  "name": "cbr0",
  "cniVersion": "0.3.1",
  "plugins": [
    {
      "type": "flannel",
      "delegate": {
        "hairpinMode": true,
        "isDefaultGateway": true
      }
    },
    {
      "type": "portmap",
      "capabilities": {
        "portMappings": true
      }
    }
  ]
}
EOFCNI

# Create Flannel subnet configuration
cat > /run/flannel/subnet.env << EOFSUBNET
FLANNEL_NETWORK=${POD_CIDR}
FLANNEL_SUBNET=${NODE_CIDR}
FLANNEL_MTU=1450
FLANNEL_IPMASQ=true
FLANNEL_IFACE=${NODE_INTERFACE}
EOFSUBNET

# Restart containerd and kubelet to pick up CNI changes
systemctl restart containerd
sleep 3
systemctl restart kubelet

echo "CNI setup completed on $NODE_NAME"
exit 0
EOFSCRIPT

chmod +x $TEMP_SCRIPT

# Copy and execute the script on the new node
echo "Copying and executing CNI setup script on $NODE_NAME..."
scp -o StrictHostKeyChecking=no $TEMP_SCRIPT root@$NODE_IP:/tmp/setup-cni.sh
ssh -o StrictHostKeyChecking=no root@$NODE_IP "bash /tmp/setup-cni.sh && rm /tmp/setup-cni.sh"

if [ $? -eq 0 ]; then
  echo "✅ CNI setup successful on $NODE_NAME"
  echo "The node is now ready to join the cluster."
  echo "Use the kubeadm join command to add it to the cluster."
else
  echo "❌ Failed to setup CNI on $NODE_NAME"
  exit 1
fi

rm $TEMP_SCRIPT
