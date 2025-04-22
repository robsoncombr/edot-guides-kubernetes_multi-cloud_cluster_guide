#!/bin/bash
# ============================================================================
# 003-Fix_Flannel_Interfaces.sh - Fix Flannel network interfaces
# ============================================================================
# 
# DESCRIPTION:
#   This script fixes Flannel network interface configurations by creating
#   appropriate DaemonSets for each interface type defined in the environment
#   configuration.
#
# USAGE:
#   ./003-Fix_Flannel_Interfaces.sh
#
# NOTES:
#   - Run this script from the control plane node
#   - Useful for fixing Flannel when nodes have different network interfaces
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
echo "Fixing Flannel Network Interface Configurations"
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

# Create a temporary directory for manifest files
TMP_DIR="/tmp/flannel-fix"
mkdir -p $TMP_DIR

# Delete any existing Flannel DaemonSets
echo "Removing existing Flannel DaemonSets..."
kubectl -n kube-flannel get daemonset -o name | xargs -r kubectl -n kube-flannel delete

# Keep any existing ConfigMap
echo "Keeping existing Flannel ConfigMap for reuse..."

# Find unique network interfaces across all nodes
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

# Create a Flannel DaemonSet for each interface
for IFACE in "${!INTERFACES[@]}"; do
    echo "Creating Flannel DaemonSet for interface: $IFACE"
    
    # Create a list of node names that use this interface
    NODE_SELECTORS=()
    for NODE_CONFIG in "${ALL_NODES[@]}"; do
        NODE_NAME=$(get_node_property "$NODE_CONFIG" 0)
        NODE_INTERFACE=$(get_node_property "$NODE_CONFIG" 3)
        if [[ "$NODE_INTERFACE" == "$IFACE" ]]; then
            NODE_SELECTORS+=("$NODE_NAME")
        fi
    done
    
    # Create the Flannel DaemonSet manifest
    cat > $TMP_DIR/kube-flannel-ds-$IFACE.yaml << EOF
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
            - matchExpressions:
              - key: kubernetes.io/hostname
                operator: In
                values:
EOF

    # Add the node selectors to the manifest
    for NODE_NAME in "${NODE_SELECTORS[@]}"; do
        echo "                - $NODE_NAME" >> $TMP_DIR/kube-flannel-ds-$IFACE.yaml
    done

    # Complete the manifest
    cat >> $TMP_DIR/kube-flannel-ds-$IFACE.yaml << EOF
      hostNetwork: true
      priorityClassName: system-node-critical
      tolerations:
      - operator: Exists
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

    # Apply the Flannel DaemonSet
    echo "Applying Flannel DaemonSet for interface $IFACE..."
    kubectl apply -f $TMP_DIR/kube-flannel-ds-$IFACE.yaml
done

# Wait for Flannel pods to be created
echo "Waiting for Flannel pods to start (30 seconds)..."
sleep 30

# Check status of Flannel pods
echo "Checking Flannel pod status:"
kubectl -n kube-flannel get pods -o wide

# Clean up temporary files
rm -rf $TMP_DIR

echo "-------------------------------------------------------------------"
echo "Checking node status:"
kubectl get nodes -o custom-columns=NAME:.metadata.name,INTERNAL-IP:.status.addresses[0].address,POD-CIDR:.spec.podCIDR,STATUS:.status.conditions[-1].type

echo "======================================================================"
echo "Flannel network interface fix completed!"
echo "======================================================================"
