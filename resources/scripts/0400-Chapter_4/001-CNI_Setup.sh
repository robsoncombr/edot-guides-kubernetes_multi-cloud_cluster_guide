#!/bin/bash

# 001-CNI_Setup.sh - Script to install and configure Flannel CNI
# This script should be executed on the control plane node after kubeadm init

echo "Setting up Flannel CNI for Kubernetes cluster..."
echo "======================================================================================="
echo "This will configure Flannel with the following settings:"
echo "- Pod CIDR: 10.10.0.0/16 (as configured in kubeadm-config.yaml)"
echo "- Node 01 pods: 10.10.1.0/24"
echo "- Node 02 pods: 10.10.2.0/24"
echo "- Node 03 pods: 10.10.3.0/24"
echo "- Using VPN network 172.16.0.0/16 for inter-node communication"
echo "======================================================================================="

# Ensure we're running as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

# Ensure kubectl is available and the cluster is accessible
if ! kubectl get nodes &>/dev/null; then
    echo "Error: kubectl cannot access the Kubernetes cluster."
    echo "Make sure you have initialized the control plane and set up kubectl properly."
    exit 1
fi

# Create a custom flannel configuration with our specific subnet settings
echo "Creating custom Flannel configuration..."
cat > /tmp/kube-flannel.yaml << 'EOF'
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
EOF

# Apply the Flannel configuration
echo "Applying Flannel CNI to Kubernetes cluster..."
kubectl apply -f /tmp/kube-flannel.yaml

# Create a script to set up pod CIDRs for each node
echo "Creating node-specific pod CIDR configuration..."
cat > /tmp/setup-node-cidrs.yaml << EOF
apiVersion: v1
kind: Node
metadata:
  name: k8s-01-oci-01
spec:
  podCIDR: "10.10.1.0/24"
  podCIDRs:
  - "10.10.1.0/24"
---
apiVersion: v1
kind: Node
metadata:
  name: k8s-02-oci-02
spec:
  podCIDR: "10.10.2.0/24"
  podCIDRs:
  - "10.10.2.0/24"
---
apiVersion: v1
kind: Node
metadata:
  name: k8s-03-htg-01
spec:
  podCIDR: "10.10.3.0/24"
  podCIDRs:
  - "10.10.3.0/24"
EOF

# Function to set node pod CIDR
setup_node_cidr() {
  local node=$1
  local cidr=$2
  
  # Wait for node to be available
  echo "Checking if node $node is available..."
  if kubectl get node $node &>/dev/null; then
    echo "Setting pod CIDR $cidr for node $node"
    kubectl patch node $node -p "{\"spec\":{\"podCIDR\":\"$cidr\",\"podCIDRs\":[\"$cidr\"]}}"
  else
    echo "Node $node is not yet available. It will be configured when it joins the cluster."
  fi
}

# Apply pod CIDRs for each node
echo "Configuring per-node pod CIDR allocations..."
setup_node_cidr "k8s-01-oci-01" "10.10.1.0/24"
setup_node_cidr "k8s-02-oci-02" "10.10.2.0/24"
setup_node_cidr "k8s-03-htg-01" "10.10.3.0/24"

# Create a helper script to fix flannel configuration on worker nodes
echo "Creating helper script for worker nodes..."
cat > /tmp/fix-flannel-subnet.sh << 'EOF'
#!/bin/bash
# Helper script to configure flannel on worker nodes properly
# This should be run on worker nodes after joining the cluster if there are network issues

NODE_NAME=$(hostname)
NODE_NUM=${NODE_NAME##*-}
NODE_NUM=${NODE_NUM##*0}
POD_CIDR="10.10.${NODE_NUM}.0/24"

echo "Configuring flannel subnet for $NODE_NAME with CIDR $POD_CIDR"

# Ensure CNI directory exists
mkdir -p /run/flannel

# Create subnet.env file with correct CIDR
echo "FLANNEL_NETWORK=10.10.0.0/16" > /run/flannel/subnet.env
echo "FLANNEL_SUBNET=$POD_CIDR" >> /run/flannel/subnet.env
echo "FLANNEL_MTU=1450" >> /run/flannel/subnet.env
echo "FLANNEL_IPMASQ=true" >> /run/flannel/subnet.env

echo "Subnet configured. Restarting kubelet..."
systemctl restart kubelet
EOF

chmod +x /tmp/fix-flannel-subnet.sh

echo "Waiting for CNI pods to start..."
sleep 10

echo "Checking pods in kube-flannel namespace:"
kubectl get pods -n kube-flannel

echo "Checking nodes status:"
kubectl get nodes -o wide
kubectl get pods --all-namespaces -o wide

echo "======================================================================================="
echo "Flannel CNI installation complete!"
echo ""
echo "IMPORTANT NOTES:"
echo "1. It may take a minute or two for the CNI pods to become Ready"
echo "2. If you experience any networking issues on worker nodes after joining,"
echo "   transfer and run the helper script generated at /tmp/fix-flannel-subnet.sh"
echo "======================================================================================="

echo ""
echo "Monitoring the CNI pod status:"
kubectl get pods -n kube-flannel -w -o wide &
WATCH_PID=$!
sleep 30
kill $WATCH_PID

echo ""
echo "NEXT STEP:"
echo "1. Wait for CNI to be fully initialized (control plane node should change to Ready)"
echo "2. Return to Chapter 3 to complete joining worker nodes to the cluster"
echo ""
