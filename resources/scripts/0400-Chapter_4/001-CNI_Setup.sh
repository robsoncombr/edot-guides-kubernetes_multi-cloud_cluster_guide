#!/bin/bash

# ============================================================================
# 001-CNI_Setup.sh - Script to install and configure Flannel CNI
# ============================================================================
# 
# DESCRIPTION:
#   This script installs and configures Flannel as the Container Network Interface 
#   (CNI) for the Kubernetes cluster. It performs node-specific pod CIDR assignments
#   and creates helper scripts for worker node networking configuration.
#
# USAGE:
#   ./001-CNI_Setup.sh
#
# ARGUMENTS:
#   None
#
# ORDER OF USE:
#   1. Run only on the control plane node (k8s-01-oci-01)
#   2. Run after Kubernetes cluster initialization and before joining worker nodes
#   3. Can be run after worker nodes join to apply/fix node CIDR assignments
#
# CIDR ALLOCATIONS:
#   - Service CIDR: 10.1.0.0/16 (defined during kubeadm init)
#   - Pod CIDR: 10.10.0.0/16 (used by Flannel)
#   - Node-specific pod CIDRs:
#     - Node 01 (k8s-01-oci-01): 10.10.1.0/24
#     - Node 02 (k8s-02-oci-02): 10.10.2.0/24
#     - Node 03 (k8s-03-htg-01): 10.10.3.0/24
#
# NOTES:
#   - Requires root privileges to run
#   - Uses the dedicated fix script at ../0400-Chapter_4/001_fix-Flannel_Subnet.sh for nodes
#   - After worker nodes join the cluster, they should run the fix script
#   - Flannel DaemonSet will be deployed to all nodes in the cluster automatically
# ============================================================================

echo "========================================================================"
echo "Installing and Configuring Flannel CNI with Custom Pod CIDR Allocation"
echo "========================================================================"

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

# Check if script is running on control plane node
HOSTNAME=$(hostname)
if [[ "$HOSTNAME" != "k8s-01-oci-01" ]]; then
    echo "Error: This script must be run on the control plane node (k8s-01-oci-01)"
    echo "Current host: $HOSTNAME"
    exit 1
fi

echo "Step 1: Patching nodes with specific CIDR ranges..."

# Patch the control plane node
kubectl patch node k8s-01-oci-01 -p '{"spec":{"podCIDR":"10.10.1.0/24","podCIDRs":["10.10.1.0/24"]}}'
echo "Control plane node patched with CIDR 10.10.1.0/24"

# Check if worker nodes have already joined and patch them
if kubectl get node k8s-02-oci-02 &>/dev/null; then
    kubectl patch node k8s-02-oci-02 -p '{"spec":{"podCIDR":"10.10.2.0/24","podCIDRs":["10.10.2.0/24"]}}'
    echo "Worker node k8s-02-oci-02 patched with CIDR 10.10.2.0/24"
fi

if kubectl get node k8s-03-htg-01 &>/dev/null; then
    kubectl patch node k8s-03-htg-01 -p '{"spec":{"podCIDR":"10.10.3.0/24","podCIDRs":["10.10.3.0/24"]}}'
    echo "Worker node k8s-03-htg-01 patched with CIDR 10.10.3.0/24"
fi

echo "Step 2: Creating custom Flannel configuration file..."
# Create custom Flannel configuration
cat > /tmp/kube-flannel.yaml << 'EOF2'
---
kind: Namespace
apiVersion: v1
metadata:
  name: kube-flannel
  labels:
    pod-security.kubernetes.io/enforce: privileged
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: flannel
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
  - list
  - watch
- apiGroups:
  - ""
  resources:
  - nodes/status
  verbs:
  - patch
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: flannel
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: flannel
subjects:
- kind: ServiceAccount
  name: flannel
  namespace: kube-flannel
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: flannel
  namespace: kube-flannel
---
kind: ConfigMap
apiVersion: v1
metadata:
  name: kube-flannel-cfg
  namespace: kube-flannel
  labels:
    tier: node
    app: flannel
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
      "Network": "10.10.0.0/16",
      "Backend": {
        "Type": "vxlan",
        "VNI": 1,
        "DirectRouting": true
      }
    }
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kube-flannel-ds
  namespace: kube-flannel
  labels:
    tier: node
    app: flannel
spec:
  selector:
    matchLabels:
      app: flannel
  template:
    metadata:
      labels:
        tier: node
        app: flannel
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
        - --iface=eth0
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
EOF2

echo "Step 3: Applying Flannel configuration..."
kubectl apply -f /tmp/kube-flannel.yaml
# Clean up
rm -f /tmp/kube-flannel.yaml

# Swap steps 4 and 5 for better logical flow
echo "Step 4: Using the dedicated fix script for worker nodes..."
# Reference the existing fix script
FLANNEL_FIX_SCRIPT="$(dirname "$0")/001_fix-Flannel_Subnet.sh"
echo "Worker nodes should use the fix script at: $FLANNEL_FIX_SCRIPT"
# Check if the control plane node should run the fix script
if [ -f "$FLANNEL_FIX_SCRIPT" ]; then
    echo "Running the Flannel subnet fix script on the control plane node..."
    # Run the fix script but don't restart kubelet on control plane to avoid disconnects
    bash "$FLANNEL_FIX_SCRIPT" --no-restart
else
    echo "Warning: Fix script not found at $FLANNEL_FIX_SCRIPT"
    echo "Flannel fix script must be separately applied to worker nodes after joining."
fi

echo "Step 5: Waiting for Flannel pods to be ready..."
# Wait for Flannel pods to be running
kubectl -n kube-flannel wait --for=condition=ready pods --selector=app=flannel --timeout=120s

echo "Step 6: Verifying node status and CIDR allocation..."
# Check node status and CIDR allocation
kubectl get nodes -o custom-columns=NAME:.metadata.name,INTERNAL-IP:.status.addresses[0].address,POD-CIDR:.spec.podCIDR

echo "========================================================================"
echo "Flannel CNI installed successfully!"
echo "IMPORTANT NOTES:"
echo "1. It may take a minute or two for the CNI pods to become Ready"
echo "2. For worker nodes, use the fix script at: $FLANNEL_FIX_SCRIPT"
echo "3. On the control plane node, patch worker nodes after they join:"
echo "   kubectl patch node k8s-02-oci-02 -p '{\"spec\":{\"podCIDR\":\"10.10.2.0/24\",\"podCIDRs\":[\"10.10.2.0/24\"]}}'"
echo "   kubectl patch node k8s-03-htg-01 -p '{\"spec\":{\"podCIDR\":\"10.10.3.0/24\",\"podCIDRs\":[\"10.10.3.0/24\"]}}'"
echo "========================================================================"
