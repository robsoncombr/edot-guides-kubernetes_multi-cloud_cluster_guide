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

# Create a directory for the manifests
MANIFEST_DIR="/tmp/flannel-manifests"
mkdir -p $MANIFEST_DIR

# Download the Flannel base manifest
echo "Downloading Flannel base manifest..."
curl -s https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml > $MANIFEST_DIR/kube-flannel-base.yml

# Modify the network configuration in the Flannel ConfigMap
echo "Modifying Flannel ConfigMap to use our Pod CIDR: $POD_CIDR"
sed -i "s|\"Network\": \"10.244.0.0/16\"|\"Network\": \"$POD_CIDR\"|g" $MANIFEST_DIR/kube-flannel-base.yml

# Disable Flannel default DaemonSet - we'll create our own node-specific DaemonSets
sed -i '/^---/,$d' $MANIFEST_DIR/kube-flannel-base.yml

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

# Create the Flannel namespace first
cat > $MANIFEST_DIR/kube-flannel-namespace.yml << EOF
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
EOF

# Create the Flannel ConfigMap with our network settings
cat > $MANIFEST_DIR/kube-flannel-configmap.yml << EOF
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
      "Backend": {
        "Type": "vxlan"
      }
    }
EOF

# Apply the Flannel namespace, service account, and ConfigMap
echo "Creating Flannel namespace, RBAC, and ConfigMap..."
kubectl apply -f $MANIFEST_DIR/kube-flannel-namespace.yml
kubectl apply -f $MANIFEST_DIR/kube-flannel-configmap.yml

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
    
    # Join the node selectors with commas for the nodeAffinity
    NODE_AFFINITY_SELECTORS=$(IFS=,; echo "${NODE_SELECTORS[*]}")
    
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
done

# Wait for Flannel pods to be running
echo "Waiting for Flannel pods to start (this may take a minute)..."
sleep 10

# Check the status of Flannel pods
echo "Checking Flannel pod status:"
kubectl -n kube-flannel get pods -o wide

# Check if control plane node has correct CIDR
CP_HOSTNAME=$(get_node_property "${NODE_CP1}" 0)
CP_POD_CIDR=$(get_node_property "${NODE_CP1}" 2)
CURRENT_CIDR=$(kubectl get node "$CP_HOSTNAME" -o jsonpath='{.spec.podCIDR}' 2>/dev/null || echo "")

# Let Kubernetes assign the CIDR naturally - don't force it
if [ -z "$CURRENT_CIDR" ]; then
    echo "Control plane node doesn't have a Pod CIDR assigned yet."
    echo "Kubernetes will assign the Pod CIDR automatically."
elif [ "$CURRENT_CIDR" != "$CP_POD_CIDR" ]; then
    echo "Note: Control plane node has CIDR $CURRENT_CIDR (environment config specifies $CP_POD_CIDR)"
    echo "Using the Kubernetes-assigned CIDR for proper compatibility."
    # Update our reference to use the actual assigned CIDR
    CP_POD_CIDR=$CURRENT_CIDR
else
    echo "Control plane node already has CIDR: $CP_POD_CIDR"
fi

# Configure Flannel subnet on the control plane to use whatever CIDR is assigned
CP_INTERFACE=$(get_node_property "${NODE_CP1}" 3)
echo "Configuring Flannel subnet on control plane with interface $CP_INTERFACE..."

# Only configure Flannel if we actually have a CIDR
if [ -n "$CURRENT_CIDR" ]; then
    # Set up Flannel subnet configuration on the control plane using the actual assigned CIDR
    mkdir -p /run/flannel
    cat > /run/flannel/subnet.env << EOF
FLANNEL_NETWORK=$POD_CIDR
FLANNEL_SUBNET=$CURRENT_CIDR
FLANNEL_MTU=1450
FLANNEL_IPMASQ=true
FLANNEL_IFACE=$CP_INTERFACE
EOF
    echo "Flannel subnet configuration created using CIDR: $CURRENT_CIDR"
else
    echo "No Pod CIDR assigned yet. Flannel will use the CIDR when Kubernetes assigns it."
fi

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
            NODE_POD_CIDR=$(get_node_property "$NODE_CONFIG" 2)
            echo "  - $NODE_NAME (CIDR: $NODE_POD_CIDR)"
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
echo "IMPORTANT: Control plane node should now be in 'Ready' state."
echo "You can now join worker nodes to the cluster using the script:"
echo "  ./004-Join_Worker_Nodes.sh"
echo "======================================================================"

# Clean up
rm -rf $MANIFEST_DIR
