#!/bin/bash

# ============================================================================
# 001-CNI_Setup.sh - Script to set up Flannel CNI
# ============================================================================
# 
# DESCRIPTION:
#   This script installs and configures Flannel as the CNI network plugin.
#   It configures Flannel to use node-specific network interfaces based on
#   the centralized environment configuration.
#
# USAGE:
#   ./001-CNI_Setup.sh
#
# NOTES:
#   - Run this script on the control plane node after initialization
#   - Must be run before joining worker nodes
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
echo "Setting up Flannel CNI with node-specific network configurations"
echo "======================================================================"

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# Check if running on control plane node
HOSTNAME=$(get_current_hostname)
CONTROL_PLANE_HOSTNAME=$(get_node_property "${NODE_CP1}" 0)

if [[ "$HOSTNAME" != "$CONTROL_PLANE_HOSTNAME" ]]; then
    echo "Error: This script must be run on the control plane node ($CONTROL_PLANE_HOSTNAME)"
    echo "Current host: $HOSTNAME"
    exit 1
fi

# Function to check if command succeeded
check_status() {
  if [ $? -ne 0 ]; then
    echo "❌ ERROR: $1 failed"
    return 1
  else
    echo "✅ SUCCESS: $1 completed"
    return 0
  fi
}

# Extract the POD_CIDR prefix (e.g., 10.10 from 10.10.0.0/16)
POD_CIDR_PREFIX=$(echo "$POD_CIDR" | cut -d '.' -f 1-2)

# Create a directory for the manifests
MANIFEST_DIR="/tmp/flannel-manifests"
mkdir -p $MANIFEST_DIR

# Function to generate a valid CIDR without leading zeros
# This fixes the issue where "10.10.02.0/24" would cause flannel to fail
generate_valid_cidr() {
    local node_name=$1
    # Extract node number and ensure it's a decimal number (remove leading zeros)
    local node_num=$(echo "$node_name" | grep -oE '[0-9]+$' || echo "0")
    node_num=$((10#$node_num)) # Force decimal interpretation
    echo "${POD_CIDR_PREFIX}.${node_num}.0/24"
}

# ============================================================================
# STEP 1: Prepare CNI directories and configurations on control plane
# ============================================================================
echo "Creating CNI directories and configurations on control plane..."
mkdir -p /etc/cni/net.d
mkdir -p /opt/cni/bin
mkdir -p /run/flannel

# Create the flannel CNI configuration directly
cat > /etc/cni/net.d/10-flannel.conflist << EOF
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
EOF
check_status "Creating CNI configuration on control plane"

# Get the pod CIDR for the control plane node
CONTROL_PLANE_CIDR=$(kubectl get node $HOSTNAME -o jsonpath='{.spec.podCIDR}' 2>/dev/null)
if [ -z "$CONTROL_PLANE_CIDR" ]; then
    # If not assigned, use default based on POD_CIDR
    CONTROL_PLANE_CIDR="${POD_CIDR_PREFIX}.1.0/24"
    echo "No Pod CIDR assigned to control plane, using default: $CONTROL_PLANE_CIDR"
else
    echo "Control plane Pod CIDR: $CONTROL_PLANE_CIDR"
fi

# Create Flannel subnet configuration on control plane
CONTROL_PLANE_INTERFACE=$(get_node_property "${NODE_CP1}" 3)
echo "Creating Flannel subnet configuration on control plane..."
cat > /run/flannel/subnet.env << EOF
FLANNEL_NETWORK=${POD_CIDR}
FLANNEL_SUBNET=${CONTROL_PLANE_CIDR}
FLANNEL_MTU=1450
FLANNEL_IPMASQ=true
FLANNEL_IFACE=${CONTROL_PLANE_INTERFACE}
EOF
check_status "Creating Flannel subnet configuration on control plane"

# Restart containerd and kubelet on control plane to pick up CNI changes
echo "Restarting containerd and kubelet services on control plane..."
systemctl restart containerd
sleep 3
systemctl restart kubelet
check_status "Restarting control plane services"

# Pre-create all required configurations for worker nodes
echo "Preparing scripts to configure CNI on worker nodes..."
for NODE_CONFIG in "${ALL_NODES[@]}"; do
    NODE_NAME=$(get_node_property "$NODE_CONFIG" 0)
    NODE_IP=$(get_node_property "$NODE_CONFIG" 1)
    NODE_INTERFACE=$(get_node_property "$NODE_CONFIG" 3)
    NODE_ROLE=$(get_node_property "$NODE_CONFIG" 4)
    
    # Skip control plane node (already configured)
    if [[ "$NODE_NAME" == "$HOSTNAME" ]]; then
        continue
    fi
    
    # Generate valid CIDR without leading zeros
    NODE_CIDR=$(generate_valid_cidr "$NODE_NAME")
    echo "Node $NODE_NAME will use CIDR: $NODE_CIDR"
    
    # Create a script to set up CNI on this worker node
    echo "Creating CNI setup script for node: $NODE_NAME"
    cat > $MANIFEST_DIR/setup-cni-$NODE_NAME.sh << EOF
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

# Create Flannel subnet configuration with correctly formatted CIDR
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
EOF
    chmod +x $MANIFEST_DIR/setup-cni-$NODE_NAME.sh
    
    # Copy and execute the script on the worker node
    echo "Copying and executing CNI setup script on $NODE_NAME..."
    scp -o StrictHostKeyChecking=no $MANIFEST_DIR/setup-cni-$NODE_NAME.sh root@$NODE_IP:/tmp/setup-cni.sh
    ssh -o StrictHostKeyChecking=no root@$NODE_IP "bash /tmp/setup-cni.sh && rm /tmp/setup-cni.sh"
    check_status "Setting up CNI on $NODE_NAME"
done

# ============================================================================
# STEP 2: Create Flannel resources
# ============================================================================

# Create a Flannel manifest for each unique network interface
declare -A INTERFACES

# Extract unique interfaces from node configurations
for NODE_CONFIG in "${ALL_NODES[@]}"; do
    NODE_NAME=$(get_node_property "$NODE_CONFIG" 0)
    NODE_INTERFACE=$(get_node_property "$NODE_CONFIG" 3)
    INTERFACES["$NODE_INTERFACE"]="$NODE_INTERFACE"
done

echo "Found the following network interfaces across nodes:"
for IFACE in "${!INTERFACES[@]}"; do
    echo "- $IFACE"
done

# Create the Flannel base resources first (namespace, RBAC, ConfigMap)
cat > $MANIFEST_DIR/kube-flannel-base.yml << EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: kube-flannel
  labels:
    pod-security.kubernetes.io/enforce: privileged
    app.kubernetes.io/name: flannel
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: flannel
  namespace: kube-flannel
  labels:
    app.kubernetes.io/name: flannel
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: flannel
  labels:
    app.kubernetes.io/name: flannel
rules:
- apiGroups:
  - ""
  resources:
  - pods
  verbs:
  - get
- apiGroups:
  - ""
  resources:
  - nodes
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - ""
  resources:
  - nodes/status
  verbs:
  - patch
- apiGroups:
  - networking.k8s.io
  resources:
  - clustercidrs
  verbs:
  - list
  - watch
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: flannel
  labels:
    app.kubernetes.io/name: flannel
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: flannel
subjects:
- kind: ServiceAccount
  name: flannel
  namespace: kube-flannel
---
kind: ConfigMap
apiVersion: v1
metadata:
  name: kube-flannel-cfg
  namespace: kube-flannel
  labels:
    app.kubernetes.io/name: flannel
data:
  cni-conf.json: |
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
  net-conf.json: |
    {
      "Network": "$POD_CIDR",
      "EnableNFTables": false,
      "Backend": {
        "Type": "vxlan",
        "MTU": 1450
      }
    }
EOF

# Apply the base Flannel resources
echo "Creating Flannel namespace, RBAC, and ConfigMap..."
kubectl apply -f $MANIFEST_DIR/kube-flannel-base.yml
check_status "Applying Flannel base resources"

# Create a Flannel DaemonSet for each interface
for IFACE in "${!INTERFACES[@]}"; do
    echo "Creating Flannel DaemonSet for interface: $IFACE"
    
    # Create a list of node names that use this interface
    NODE_SELECTORS=()
    for NODE_CONFIG in "${ALL_NODES[@]}"; do
        NODE_NAME=$(get_node_property "$NODE_CONFIG" 0)
        NODE_INTERFACE=$(get_node_property "$NODE_CONFIG" 3)
        if [[ "$NODE_INTERFACE" == "$IFACE" ]]; then
            NODE_SELECTORS+=("kubernetes.io/hostname: $NODE_NAME")
        fi
    done
    
    # Generate the Flannel DaemonSet manifest for this interface
    cat > $MANIFEST_DIR/kube-flannel-ds-$IFACE.yml << EOF
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kube-flannel-ds-$IFACE
  namespace: kube-flannel
  labels:
    app: flannel
    k8s-app: flannel
    tier: node
    app.kubernetes.io/name: flannel
spec:
  selector:
    matchLabels:
      app: flannel
      k8s-app: flannel
  template:
    metadata:
      labels:
        app: flannel
        k8s-app: flannel
        tier: node
        app.kubernetes.io/name: flannel
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: kubernetes.io/os
                operator: In
                values:
                - linux
              - key: kubernetes.io/hostname
                operator: In
                values:
EOF

    # Add the node hostnames separately to avoid YAML formatting issues
    for SELECTOR in "${NODE_SELECTORS[@]}"; do
      NODE_NAME=$(echo $SELECTOR | cut -d: -f2 | tr -d ' ')
      echo "                - $NODE_NAME" >> $MANIFEST_DIR/kube-flannel-ds-$IFACE.yml
    done

    # Continue with the rest of the DaemonSet template
    cat >> $MANIFEST_DIR/kube-flannel-ds-$IFACE.yml << EOF
      hostNetwork: true
      priorityClassName: system-node-critical
      tolerations:
      - operator: Exists
        effect: NoSchedule
      - key: node.kubernetes.io/not-ready
        operator: Exists
        effect: NoSchedule
      serviceAccountName: flannel
      initContainers:
      - name: install-cni-plugin
        image: docker.io/flannel/flannel-cni-plugin:v1.1.2
        command:
        - cp
        args:
        - -f
        - /flannel
        - /opt/cni/bin/flannel
        volumeMounts:
        - name: cni-plugin
          mountPath: /opt/cni/bin
      - name: install-cni
        image: docker.io/flannel/flannel:v0.24.0
        command:
        - cp
        args:
        - -f
        - /etc/kube-flannel/cni-conf.json
        - /etc/cni/net.d/10-flannel.conflist
        volumeMounts:
        - name: cni
          mountPath: /etc/cni/net.d
        - name: flannel-cfg
          mountPath: /etc/kube-flannel/
      containers:
      - name: kube-flannel
        image: docker.io/flannel/flannel:v0.24.0
        command:
        - /opt/bin/flanneld
        args:
        - --ip-masq
        - --kube-subnet-mgr
        - --iface=$IFACE
        resources:
          requests:
            cpu: "100m"
            memory: "50Mi"
          limits:
            cpu: "100m"
            memory: "50Mi"
        securityContext:
          privileged: false
          capabilities:
            add: ["NET_ADMIN", "NET_RAW"]
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: EVENT_QUEUE_DEPTH
          value: "5000"
        volumeMounts:
        - name: run
          mountPath: /run/flannel
        - name: flannel-cfg
          mountPath: /etc/kube-flannel/
        - name: xtables-lock
          mountPath: /run/xtables.lock
      volumes:
      - name: run
        hostPath:
          path: /run/flannel
      - name: cni-plugin
        hostPath:
          path: /opt/cni/bin
      - name: cni
        hostPath:
          path: /etc/cni/net.d
      - name: flannel-cfg
        configMap:
          name: kube-flannel-cfg
      - name: xtables-lock
        hostPath:
          path: /run/xtables.lock
          type: FileOrCreate
EOF
    
    # Apply the Flannel DaemonSet for this interface
    kubectl apply -f $MANIFEST_DIR/kube-flannel-ds-$IFACE.yml
    check_status "Applying Flannel DaemonSet for interface $IFACE"
done

# ============================================================================
# STEP 3: Fix any invalid CIDR configurations on existing nodes
# ============================================================================
echo "Checking for and fixing any invalid CIDR configurations on existing nodes..."

# Get all nodes
ALL_K8S_NODES=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')

for NODE_NAME in $ALL_K8S_NODES; do
    echo "Checking CIDR configuration for node $NODE_NAME"
    
    # Skip if node is the local node
    if [[ "$NODE_NAME" == "$HOSTNAME" ]]; then
        echo "Skipping local node $NODE_NAME"
        continue
    fi
    
    # Get the correct CIDR for the node using our function
    CORRECT_CIDR=$(generate_valid_cidr "$NODE_NAME")
    
    # Get the node IP to connect to it
    NODE_IP=""
    for NODE_CONFIG in "${ALL_NODES[@]}"; do
        NODE_CFG_NAME=$(get_node_property "$NODE_CONFIG" 0)
        if [[ "$NODE_CFG_NAME" == "$NODE_NAME" ]]; then
            NODE_IP=$(get_node_property "$NODE_CONFIG" 1)
            NODE_INTERFACE=$(get_node_property "$NODE_CONFIG" 3)
            break
        fi
    done
    
    if [[ -z "$NODE_IP" ]]; then
        echo "Warning: Could not find IP for node $NODE_NAME, skipping CIDR fix"
        continue
    fi
    
    # Create script to check and fix the Flannel subnet on the node
    FIX_SCRIPT="/tmp/fix-flannel-$NODE_NAME.sh"
    cat > $FIX_SCRIPT << EOF
#!/bin/bash
echo "Checking and fixing Flannel subnet configuration on $NODE_NAME"

# Check if the subnet file exists
if [ -f /run/flannel/subnet.env ]; then
    echo "Current subnet.env content:"
    cat /run/flannel/subnet.env
    
    # Check if the subnet file contains an invalid CIDR (with leading zeros)
    if grep -q "FLANNEL_SUBNET=.*0[0-9]\.0\/24" /run/flannel/subnet.env; then
        echo "Found invalid CIDR with leading zeros, fixing..."
        
        # Create correct subnet file with proper CIDR
        echo "Updating with correct CIDR $CORRECT_CIDR"
        cat > /run/flannel/subnet.env << EOL
FLANNEL_NETWORK=${POD_CIDR}
FLANNEL_SUBNET=${CORRECT_CIDR}
FLANNEL_MTU=1450
FLANNEL_IPMASQ=true
FLANNEL_IFACE=${NODE_INTERFACE}
EOL
        
        echo "Updated subnet.env content:"
        cat /run/flannel/subnet.env
        
        # Restart flannel pods to apply the fix
        echo "Restarting Flannel pods..."
        crictl pods --name flannel -q | xargs -r crictl rmp -f
        
        # Restart kubelet to ensure new settings are applied
        echo "Restarting kubelet..."
        systemctl restart kubelet
        
        echo "Flannel subnet configuration fixed on $NODE_NAME"
    else
        echo "CIDR is already valid in subnet.env"
    fi
else
    echo "Warning: Flannel subnet.env file not found on $NODE_NAME"
fi
EOF
    
    chmod +x $FIX_SCRIPT
    
    # Copy and execute script on the remote node
    echo "Copying and executing fix script on $NODE_NAME"
    scp -o StrictHostKeyChecking=no $FIX_SCRIPT root@$NODE_IP:/tmp/fix-flannel.sh
    ssh -o StrictHostKeyChecking=no root@$NODE_IP "bash /tmp/fix-flannel.sh; rm /tmp/fix-flannel.sh"
    
    # Clean up local script
    rm -f $FIX_SCRIPT
done

# ============================================================================
# STEP 4: Create script for adding additional nodes in the future
# ============================================================================

cat > $SCRIPT_DIR/prepare-new-node-cni.sh << 'EOF'
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
EOF

chmod +x $SCRIPT_DIR/prepare-new-node-cni.sh
echo "✅ Created script for preparing CNI on new nodes: $SCRIPT_DIR/prepare-new-node-cni.sh"

# Wait for Flannel pods to be running
echo "Waiting for Flannel pods to start..."
kubectl wait --for=condition=Ready pods -l app=flannel --timeout=120s -n kube-flannel || true
sleep 5

# Restart any Flannel pods that might still be in error state
echo "Restarting any Flannel pods that might be in error state..."
kubectl delete pods -n kube-flannel --field-selector status.phase!=Running 2>/dev/null || true
sleep 5

# Check the status of Flannel pods
echo "Checking Flannel pod status:"
kubectl -n kube-flannel get pods -o wide

# Wait for all nodes to become ready
echo "Waiting for all nodes to become Ready (this may take a minute)..."
for i in {1..20}; do
    NOT_READY_NODES=$(kubectl get nodes --no-headers | grep -v " Ready " | wc -l)
    if [[ "$NOT_READY_NODES" -eq 0 ]]; then
        echo "✅ All nodes are now Ready!"
        break
    else
        echo "Waiting for nodes to become Ready... ($i/20) - $NOT_READY_NODES nodes still not ready"
        sleep 6
    fi
    
    if [[ $i -eq 20 ]]; then
        echo "⚠️ Some nodes are still not Ready after 2 minutes"
        echo "Running diagnostics..."
        kubectl get nodes -o wide
        for NODE in $(kubectl get nodes -o name); do
            NODE_NAME=$(echo $NODE | cut -d/ -f2)
            echo "--------- Details for node $NODE_NAME ---------"
            kubectl describe node $NODE_NAME | grep -A10 "Conditions:"
        done
    fi
done

# Display status message
echo "======================================================================"
echo "Flannel CNI installed with node-specific interface configurations:"
for IFACE in "${!INTERFACES[@]}"; do
    echo "- Interface: $IFACE"
    echo "  Used by nodes:"
    for NODE_CONFIG in "${ALL_NODES[@]}"; do
        NODE_NAME=$(get_node_property "$NODE_CONFIG" 0)
        NODE_INTERFACE=$(get_node_property "$NODE_CONFIG" 3)
        if [[ "$NODE_INTERFACE" == "$IFACE" ]]; then
            echo "  - $NODE_NAME"
        fi
    done
done
echo ""
echo "Flannel CNI configuration completed successfully!"
echo "Your network configuration summary:"
echo "- Pod CIDR: $POD_CIDR"
echo "- Service CIDR: $SERVICE_CIDR"
echo "- DNS Service IP: $DNS_SERVICE_IP"
echo ""
echo "Checking node status:"
kubectl get nodes -o custom-columns=NAME:.metadata.name,INTERNAL-IP:.status.addresses[0].address,POD-CIDR:.spec.podCIDR,STATUS:.status.conditions[-1].type
echo ""
echo "IMPORTANT: To add a new node in the future, use the included script:"
echo "  $SCRIPT_DIR/prepare-new-node-cni.sh <node_hostname> <node_ip> <node_interface>"
echo "======================================================================"

# Clean up
rm -rf $MANIFEST_DIR
