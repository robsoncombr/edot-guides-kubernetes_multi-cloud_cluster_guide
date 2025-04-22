#!/bin/bash

# ============================================================================
# 001_fix-Flannel_Subnet.sh - Script to fix invalid Flannel subnet configuration
# ============================================================================
# 
# DESCRIPTION:
#   This script fixes the Flannel subnet configuration issue that causes CoreDNS
#   pods to crash with "invalid CIDR address: 10.10.X.0/24" error.
#
# USAGE:
#   ./001_fix-Flannel_Subnet.sh
#
# NOTES:
#   - Run this script when you see Flannel CNI or CoreDNS issues related to
#     invalid CIDR addresses in pod logs
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
echo "Fixing Flannel subnet configuration issues"
echo "======================================================================"

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# Create a temporary directory for manifests
MANIFEST_DIR="/tmp/flannel-fix"
mkdir -p $MANIFEST_DIR

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

# Check current nodes and their CIDRs
echo "Checking Kubernetes nodes and their assigned CIDRs..."
NODE_LIST=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.podCIDR}{"\n"}{end}')
echo "$NODE_LIST"

# Step 1: Check if we have invalid subnet config
echo "Checking for pods with 'invalid CIDR' errors..."
PROBLEM_PODS=$(kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}' | grep -v "kube-system coredns" || true)

if [[ -n "$PROBLEM_PODS" ]]; then
    echo "Found pods that might be affected by Flannel subnet issues"
    echo "$PROBLEM_PODS"
fi

# Step 2: Create fix for Flannel ConfigMap
echo "Creating fix for Flannel ConfigMap..."

# Get the POD_CIDR from the control plane node
CP_HOSTNAME=$(get_node_property "${NODE_CP1}" 0)
POD_CIDR_BASE=$(kubectl get node "$CP_HOSTNAME" -o jsonpath='{.spec.podCIDR}' | cut -d '/' -f 1 | cut -d '.' -f 1-2)
if [[ -z "$POD_CIDR_BASE" ]]; then
    echo "Could not determine POD_CIDR base from control plane node, using default from environment"
    POD_CIDR_BASE=$(echo "$POD_CIDR" | cut -d '/' -f 1 | cut -d '.' -f 1-2)
fi

echo "Using POD_CIDR base: $POD_CIDR_BASE"

# Check if kube-flannel-cfg ConfigMap exists in kube-flannel namespace
if kubectl get configmap -n kube-flannel kube-flannel-cfg &>/dev/null; then
    echo "Found kube-flannel-cfg ConfigMap. Backing up and updating..."
    
    # Backup the current ConfigMap
    kubectl get configmap -n kube-flannel kube-flannel-cfg -o yaml > $MANIFEST_DIR/kube-flannel-cfg-backup.yaml
    
    # Create a fixed ConfigMap
    cat > $MANIFEST_DIR/kube-flannel-cfg-fixed.yaml << EOF
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
      "Network": "${POD_CIDR_BASE}.0.0/16",
      "EnableNFTables": false,
      "Backend": {
        "Type": "vxlan",
        "MTU": 1450
      }
    }
EOF
    
    # Apply the fixed ConfigMap
    kubectl apply -f $MANIFEST_DIR/kube-flannel-cfg-fixed.yaml
    check_status "Flannel ConfigMap update"
    
    # Restart flannel pods
    echo "Restarting Flannel pods to apply changes..."
    kubectl delete pods -n kube-flannel -l app=flannel --grace-period=0 --force 2>/dev/null || true
    kubectl delete pods -n kube-flannel -l app=kube-flannel --grace-period=0 --force 2>/dev/null || true
    kubectl delete pods -n kube-flannel -l k8s-app=flannel --grace-period=0 --force 2>/dev/null || true
    sleep 5
else
    echo "kube-flannel-cfg ConfigMap not found in kube-flannel namespace."
    echo "Checking in kube-system namespace..."
    
    if kubectl get configmap -n kube-system kube-flannel-cfg &>/dev/null; then
        echo "Found kube-flannel-cfg ConfigMap in kube-system namespace. Backing up and updating..."
        
        # Backup the current ConfigMap
        kubectl get configmap -n kube-system kube-flannel-cfg -o yaml > $MANIFEST_DIR/kube-flannel-cfg-backup.yaml
        
        # Create a fixed ConfigMap
        cat > $MANIFEST_DIR/kube-flannel-cfg-fixed.yaml << EOF
kind: ConfigMap
apiVersion: v1
metadata:
  name: kube-flannel-cfg
  namespace: kube-system
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
      "Network": "${POD_CIDR_BASE}.0.0/16",
      "EnableNFTables": false,
      "Backend": {
        "Type": "vxlan",
        "MTU": 1450
      }
    }
EOF
        
        # Apply the fixed ConfigMap
        kubectl apply -f $MANIFEST_DIR/kube-flannel-cfg-fixed.yaml
        check_status "Flannel ConfigMap update"
        
        # Restart flannel pods
        echo "Restarting Flannel pods to apply changes..."
        kubectl delete pods -n kube-system -l app=flannel --grace-period=0 --force 2>/dev/null || true
        kubectl delete pods -n kube-system -l k8s-app=flannel --grace-period=0 --force 2>/dev/null || true
        sleep 5
    else
        echo "Could not find kube-flannel-cfg ConfigMap in either namespace. Creating direct fix..."
        
        # Create a DaemonSet to fix the Flannel subnet.env file on all nodes
        echo "Creating a DaemonSet to fix Flannel subnet files on all nodes..."
        
        cat > $MANIFEST_DIR/flannel-subnet-fixer.yaml << EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: flannel-subnet-fixer
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: flannel-subnet-fixer
  template:
    metadata:
      labels:
        app: flannel-subnet-fixer
    spec:
      hostNetwork: true
      priorityClassName: system-node-critical
      tolerations:
      - operator: Exists
      containers:
      - name: fixer
        image: busybox:1.28
        command:
        - /bin/sh
        - -c
        - |
          echo "Fixing Flannel subnet configuration"
          mkdir -p /host/run/flannel
          NODE_NAME=\$(hostname)
          POD_CIDR=\$(kubectl get node \$NODE_NAME -o jsonpath='{.spec.podCIDR}')
          if [ -z "\$POD_CIDR" ]; then
            echo "No POD_CIDR assigned to node \$NODE_NAME yet"
            # Assign a default CIDR based on node name
            NODE_NUM=\$(echo \$NODE_NAME | sed -E 's/.*-([0-9]+)$/\1/')
            POD_CIDR="${POD_CIDR_BASE}.\$NODE_NUM.0/24"
            echo "Using generated POD_CIDR: \$POD_CIDR"
          fi
          
          # Get the primary interface
          IFACE=\$(ip route | grep default | cut -d ' ' -f 5)
          if [ -z "\$IFACE" ]; then
            IFACE="eth0"
          fi
          
          echo "Creating subnet.env with CIDR: \$POD_CIDR on interface \$IFACE"
          cat > /host/run/flannel/subnet.env << INNER_EOF
FLANNEL_NETWORK=${POD_CIDR_BASE}.0.0/16
FLANNEL_SUBNET=\$POD_CIDR
FLANNEL_MTU=1450
FLANNEL_IPMASQ=true
FLANNEL_IFACE=\$IFACE
INNER_EOF
          cat /host/run/flannel/subnet.env
          echo "Subnet configuration fixed. Sleeping for a while to allow time for checking..."
          sleep 3600
        securityContext:
          privileged: true
        volumeMounts:
        - name: run
          mountPath: /host/run
      volumes:
      - name: run
        hostPath:
          path: /run
EOF
        
        kubectl apply -f $MANIFEST_DIR/flannel-subnet-fixer.yaml
        check_status "Flannel subnet fixer DaemonSet creation"
        
        echo "Waiting for flannel-subnet-fixer pods to start..."
        sleep 10
        kubectl -n kube-system get pods -l app=flannel-subnet-fixer
    fi
fi

# Step 3: Restart CoreDNS pods to pick up the fixed network configuration
echo "Restarting CoreDNS pods to pick up the fixed network configuration..."
kubectl -n kube-system delete pods -l k8s-app=kube-dns --grace-period=0 --force
sleep 10

# Step 4: Check if CoreDNS pods are now running correctly
echo "Checking if CoreDNS pods are now running correctly..."
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide

# Display final status
echo "======================================================================"
echo "Flannel subnet configuration fix completed! Current node status:"
kubectl get nodes -o custom-columns=NAME:.metadata.name,INTERNAL-IP:.status.addresses[0].address,POD-CIDR:.spec.podCIDR,STATUS:.status.conditions[-1].type
echo ""
echo "CoreDNS pod status:"
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
echo ""
echo "You can run the DNS setup script again to verify DNS is working properly:"
echo "  ./002-DNS_Setup.sh"
echo "======================================================================"

# Clean up
rm -rf $MANIFEST_DIR
