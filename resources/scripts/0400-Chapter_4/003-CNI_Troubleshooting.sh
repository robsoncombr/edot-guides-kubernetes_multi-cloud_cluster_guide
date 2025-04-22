#!/bin/bash

# ============================================================================
# 0400-Chapter_4/003-CNI_Troubleshooting.sh - Script to troubleshoot and fix CNI issues
# ============================================================================
# 
# DESCRIPTION:
#   This script helps troubleshoot and fix common CNI issues in a Kubernetes
#   cluster. It checks for common problems such as missing CNI configurations,
#   incorrect network settings, and plugin initialization failures.
#
# USAGE:
#   ./003-CNI_Troubleshooting.sh
#
# NOTES:
#   - Run this script if nodes remain in NotReady state after CNI setup
#   - Will attempt to restart CNI components and fix common issues
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
echo "Troubleshooting CNI issues in Kubernetes cluster"
echo "======================================================================"

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root"
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

# Check if running on control plane node
HOSTNAME=$(get_current_hostname)
CONTROL_PLANE_HOSTNAME=$(get_node_property "${NODE_CP1}" 0)

if [[ "$HOSTNAME" != "$CONTROL_PLANE_HOSTNAME" ]]; then
    echo "Error: This script must be run on the control plane node ($CONTROL_PLANE_HOSTNAME)"
    echo "Current host: $HOSTNAME"
    exit 1
fi

# Create a temporary directory for manifests
MANIFEST_DIR="/tmp/cni-troubleshooting"
mkdir -p $MANIFEST_DIR

# Check node status
echo "Checking node status..."
kubectl get nodes -o wide

# Extract the POD_CIDR prefix (e.g., 10.10 from 10.10.0.0/16)
POD_CIDR_PREFIX=$(echo "$POD_CIDR" | cut -d '.' -f 1-2)

# Check for common CNI issues
echo "Checking for common CNI issues..."

# 1. Check if CNI configuration exists on all nodes
echo "Verifying CNI configuration files on all nodes..."

for NODE_CONFIG in "${ALL_NODES[@]}"; do
    NODE_NAME=$(get_node_property "$NODE_CONFIG" 0)
    NODE_IP=$(get_node_property "$NODE_CONFIG" 1)
    NODE_INTERFACE=$(get_node_property "$NODE_CONFIG" 3)
    
    echo "Checking CNI configuration on node: $NODE_NAME ($NODE_IP)"
    
    if [ "$NODE_NAME" = "$HOSTNAME" ]; then
        # Local node
        if [ ! -f "/etc/cni/net.d/10-flannel.conflist" ]; then
            echo "❌ CNI configuration file missing on $NODE_NAME"
            echo "Creating CNI configuration..."
            mkdir -p /etc/cni/net.d
            
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
            check_status "CNI configuration creation on $NODE_NAME"
        else
            echo "✅ CNI configuration file exists on $NODE_NAME"
        fi
        
        # Check for subnet.env file
        if [ ! -f "/run/flannel/subnet.env" ]; then
            echo "❌ Flannel subnet configuration missing on $NODE_NAME"
            
            # Get node CIDR
            NODE_CIDR=$(kubectl get node $NODE_NAME -o jsonpath='{.spec.podCIDR}' 2>/dev/null || echo "${POD_CIDR_PREFIX}.0.0/24")
            
            echo "Creating Flannel subnet configuration..."
            mkdir -p /run/flannel
            
            cat > /run/flannel/subnet.env << EOF
FLANNEL_NETWORK=${POD_CIDR}
FLANNEL_SUBNET=${NODE_CIDR}
FLANNEL_MTU=1450
FLANNEL_IPMASQ=true
FLANNEL_IFACE=${NODE_INTERFACE}
EOF
            check_status "Flannel subnet configuration creation on $NODE_NAME"
        else
            echo "✅ Flannel subnet configuration exists on $NODE_NAME"
            echo "Current subnet configuration:"
            cat /run/flannel/subnet.env
        fi
    else
        # Remote node - use SSH
        echo "Checking remote node: $NODE_NAME"
        if ! ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$NODE_IP "test -f /etc/cni/net.d/10-flannel.conflist" 2>/dev/null; then
            echo "❌ CNI configuration file missing on $NODE_NAME"
            echo "Creating CNI configuration..."
            
            ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$NODE_IP "mkdir -p /etc/cni/net.d" 2>/dev/null
            
            ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$NODE_IP "cat > /etc/cni/net.d/10-flannel.conflist << EOF
{
  \"name\": \"cbr0\",
  \"cniVersion\": \"0.3.1\",
  \"plugins\": [
    {
      \"type\": \"flannel\",
      \"delegate\": {
        \"hairpinMode\": true,
        \"isDefaultGateway\": true
      }
    },
    {
      \"type\": \"portmap\",
      \"capabilities\": {
        \"portMappings\": true
      }
    }
  ]
}
EOF" 2>/dev/null
            
            if [ $? -eq 0 ]; then
                echo "✅ CNI configuration created on $NODE_NAME"
            else
                echo "❌ Failed to create CNI configuration on $NODE_NAME via SSH"
                echo "Will try using a Kubernetes job..."
                
                # Create a job to fix the CNI configuration
                cat > $MANIFEST_DIR/fix-cni-config-$NODE_NAME.yaml << EOF
apiVersion: v1
kind: Pod
metadata:
  name: fix-cni-config-$NODE_NAME
  namespace: default
spec:
  hostNetwork: true
  restartPolicy: Never
  nodeName: $NODE_NAME
  tolerations:
  - key: node.kubernetes.io/not-ready
    operator: Exists
    effect: NoSchedule
  containers:
  - name: fix-cni
    image: busybox:1.28
    command: 
    - /bin/sh
    - -c
    - |
      mkdir -p /host/etc/cni/net.d
      cat > /host/etc/cni/net.d/10-flannel.conflist << EOF
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
      chmod 644 /host/etc/cni/net.d/10-flannel.conflist
      echo "CNI config fixed"
    volumeMounts:
    - name: cni-config
      mountPath: /host/etc/cni/net.d
    securityContext:
      privileged: true
  volumes:
  - name: cni-config
    hostPath:
      path: /etc/cni/net.d
EOF
                kubectl apply -f $MANIFEST_DIR/fix-cni-config-$NODE_NAME.yaml
                sleep 5
                kubectl logs fix-cni-config-$NODE_NAME --tail=10 || true
                kubectl delete -f $MANIFEST_DIR/fix-cni-config-$NODE_NAME.yaml --force --grace-period=0 || true
            fi
        else
            echo "✅ CNI configuration file exists on $NODE_NAME"
        fi
        
        # Check for subnet.env file
        if ! ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$NODE_IP "test -f /run/flannel/subnet.env" 2>/dev/null; then
            echo "❌ Flannel subnet configuration missing on $NODE_NAME"
            
            # Get node CIDR
            NODE_CIDR=$(kubectl get node $NODE_NAME -o jsonpath='{.spec.podCIDR}' 2>/dev/null || echo "${POD_CIDR_PREFIX}.${NODE_NUM}.0/24")
            NODE_NUM=$(echo "$NODE_NAME" | grep -oE '[0-9]+$')
            
            echo "Creating Flannel subnet configuration..."
            ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$NODE_IP "mkdir -p /run/flannel" 2>/dev/null
            
            ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$NODE_IP "cat > /run/flannel/subnet.env << EOF
FLANNEL_NETWORK=${POD_CIDR}
FLANNEL_SUBNET=${NODE_CIDR}
FLANNEL_MTU=1450
FLANNEL_IPMASQ=true
FLANNEL_IFACE=${NODE_INTERFACE}
EOF" 2>/dev/null
            
            if [ $? -eq 0 ]; then
                echo "✅ Flannel subnet configuration created on $NODE_NAME"
            else
                echo "❌ Failed to create Flannel subnet configuration on $NODE_NAME via SSH"
                echo "Will try using a Kubernetes job..."
                
                # Create a job to fix the Flannel subnet configuration
                cat > $MANIFEST_DIR/fix-flannel-subnet-$NODE_NAME.yaml << EOF
apiVersion: v1
kind: Pod
metadata:
  name: fix-flannel-subnet-$NODE_NAME
  namespace: default
spec:
  hostNetwork: true
  restartPolicy: Never
  nodeName: $NODE_NAME
  tolerations:
  - key: node.kubernetes.io/not-ready
    operator: Exists
    effect: NoSchedule
  containers:
  - name: fix-subnet
    image: busybox:1.28
    command: 
    - /bin/sh
    - -c
    - |
      mkdir -p /host/run/flannel
      NODE_NUM=\$(echo "$NODE_NAME" | grep -oE '[0-9]+\$')
      NODE_CIDR="${POD_CIDR_PREFIX}.\${NODE_NUM}.0/24"
      cat > /host/run/flannel/subnet.env << EOF
FLANNEL_NETWORK=${POD_CIDR}
FLANNEL_SUBNET=\${NODE_CIDR}
FLANNEL_MTU=1450
FLANNEL_IPMASQ=true
FLANNEL_IFACE=${NODE_INTERFACE}
EOF
      chmod 644 /host/run/flannel/subnet.env
      echo "Flannel subnet config fixed: \$(cat /host/run/flannel/subnet.env)"
    volumeMounts:
    - name: flannel-run
      mountPath: /host/run/flannel
    securityContext:
      privileged: true
  volumes:
  - name: flannel-run
    hostPath:
      path: /run/flannel
EOF
                kubectl apply -f $MANIFEST_DIR/fix-flannel-subnet-$NODE_NAME.yaml
                sleep 5
                kubectl logs fix-flannel-subnet-$NODE_NAME --tail=10 || true
                kubectl delete -f $MANIFEST_DIR/fix-flannel-subnet-$NODE_NAME.yaml --force --grace-period=0 || true
            fi
        else
            echo "✅ Flannel subnet configuration exists on $NODE_NAME"
            echo "Current subnet configuration:"
            ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$NODE_IP "cat /run/flannel/subnet.env" 2>/dev/null || echo "Unable to read subnet configuration"
        fi
    fi
done

# 2. Check if Flannel pods are running
echo "Checking Flannel pods status..."
kubectl get pods -n kube-flannel -o wide

# 3. Check for CNI binaries
echo "Verifying CNI binary installation on all nodes..."

for NODE_CONFIG in "${ALL_NODES[@]}"; do
    NODE_NAME=$(get_node_property "$NODE_CONFIG" 0)
    NODE_IP=$(get_node_property "$NODE_CONFIG" 1)
    
    echo "Checking CNI binaries on node: $NODE_NAME ($NODE_IP)"
    
    if [ "$NODE_NAME" = "$HOSTNAME" ]; then
        # Local node
        if [ ! -f "/opt/cni/bin/flannel" ]; then
            echo "❌ Flannel CNI binary missing on $NODE_NAME"
            echo "Will attempt to reinstall Flannel CNI binaries..."
            
            # Create a job to reinstall CNI
            kubectl delete pod -n kube-flannel -l app=flannel --grace-period=0 --force
            sleep 5
        else
            echo "✅ Flannel CNI binary exists on $NODE_NAME"
        fi
    else
        # Remote node - use SSH
        if ! ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$NODE_IP "test -f /opt/cni/bin/flannel" 2>/dev/null; then
            echo "❌ Flannel CNI binary missing on $NODE_NAME"
            echo "Will attempt to reinstall Flannel CNI binaries..."
            
            # Create a job to reinstall CNI
            kubectl delete pod -n kube-flannel -l app=flannel --grace-period=0 --force
            sleep 5
        else
            echo "✅ Flannel CNI binary exists on $NODE_NAME"
        fi
    fi
done

# 4. Check for kubelet and containerd issues
echo "Checking kubelet and containerd status on all nodes..."

for NODE_CONFIG in "${ALL_NODES[@]}"; do
    NODE_NAME=$(get_node_property "$NODE_CONFIG" 0)
    NODE_IP=$(get_node_property "$NODE_CONFIG" 1)
    
    echo "Checking services on node: $NODE_NAME ($NODE_IP)"
    
    if [ "$NODE_NAME" = "$HOSTNAME" ]; then
        # Local node
        echo "Restarting containerd and kubelet services..."
        systemctl restart containerd
        sleep 2
        systemctl restart kubelet
        sleep 2
        
        echo "Service status:"
        systemctl status containerd --no-pager | grep Active
        systemctl status kubelet --no-pager | grep Active
    else
        # Remote node - use SSH
        echo "Restarting containerd and kubelet services on $NODE_NAME..."
        ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$NODE_IP "systemctl restart containerd && sleep 2 && systemctl restart kubelet" 2>/dev/null
        
        echo "Service status:"
        ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$NODE_IP "systemctl status containerd --no-pager | grep Active && systemctl status kubelet --no-pager | grep Active" 2>/dev/null || echo "Unable to get service status"
    fi
done

# Wait for nodes to update their status
echo "Waiting for nodes to update their status (this may take up to 60 seconds)..."
sleep 60

# Final status check
echo "Final node status:"
kubectl get nodes -o wide

echo "Final pod status:"
kubectl get pods -A -o wide

# Create a simple test pod to verify cluster is working
echo "Creating a test pod to verify cluster functionality..."
cat > $MANIFEST_DIR/test-pod.yaml << EOF
apiVersion: v1
kind: Pod
metadata:
  name: connectivity-test
  namespace: default
spec:
  containers:
  - name: connectivity-test
    image: busybox:1.28
    command:
      - sleep
      - "3600"
  tolerations:
  - key: node.kubernetes.io/not-ready
    operator: Exists
    effect: NoSchedule
EOF

kubectl apply -f $MANIFEST_DIR/test-pod.yaml
check_status "Test pod creation"

# Wait for the pod to start
echo "Waiting for test pod to start (this may take a minute)..."
TIMEOUT=60
for i in $(seq 1 $TIMEOUT); do
    POD_STATUS=$(kubectl get pod connectivity-test -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    if [ "$POD_STATUS" = "Running" ]; then
        echo "✅ Test pod is running"
        POD_NODE=$(kubectl get pod connectivity-test -o jsonpath='{.spec.nodeName}')
        POD_IP=$(kubectl get pod connectivity-test -o jsonpath='{.status.podIP}')
        echo "   Pod is running on node: $POD_NODE"
        echo "   Pod IP: $POD_IP"
        break
    elif [ "$i" -eq "$TIMEOUT" ]; then
        echo "⚠️ Test pod did not reach Running state within $TIMEOUT seconds"
        kubectl describe pod connectivity-test
    else
        echo "Waiting for test pod... ($i/$TIMEOUT)"
        sleep 1
    fi
done

# Summary
echo "======================================================================"
echo "CNI Troubleshooting Summary:"
echo "- CNI configuration files checked and fixed if needed"
echo "- Flannel subnet configuration checked and fixed if needed"
echo "- Kubelet and containerd services restarted on all nodes"
echo ""
echo "Next steps if nodes are still not Ready:"
echo "1. Check kubelet logs: journalctl -u kubelet -n 100"
echo "2. Check containerd logs: journalctl -u containerd -n 100"
echo "3. Verify network connectivity between nodes"
echo "4. Consider fully resetting the cluster and reinstalling if issues persist"
echo "======================================================================"

# Clean up
rm -rf $MANIFEST_DIR
