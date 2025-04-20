# Chapter 4: Networking with CNI Implementation

This chapter covers the implementation of Container Network Interface (CNI) in our Kubernetes cluster. We'll use Flannel as our CNI plugin with custom CIDR allocation for each node.

## 4.1 CNI Overview and Selection Criteria

Container Network Interface (CNI) is a specification and set of libraries for configuring network interfaces in Linux containers. CNI is essential for Kubernetes as it:

1. Enables pod-to-pod communication across nodes
2. Provides network isolation and security through network policies
3. Supports advanced features like IP address management (IPAM)

Several CNI plugins are available, each with their own advantages:

| CNI Plugin | Key Features | Best For |
|------------|--------------|----------|
| Flannel    | - Simple setup<br>- VXLAN encapsulation<br>- Lightweight<br>- DirectRouting option | Development or production with simple requirements |
| Calico     | - Network policies<br>- VXLAN or BGP routing<br>- Fine-grained security controls | Production environments requiring security and flexibility |
| Cilium     | - eBPF-based<br>- Deep packet inspection<br>- Layer 7 policies | Advanced use cases with security focus |
| Weave Net  | - Mesh overlay network<br>- Encryption<br>- DNS integration | Multi-cloud environments |

For our multi-cloud Kubernetes cluster, we're using Flannel for its simplicity, reliable performance across different environments, and compatibility with VPN-based networking between nodes.

## 4.2 Installing and Configuring Flannel with Custom Pod CIDR Allocation

In Chapter 3, we initialized our Kubernetes cluster with the following CIDR ranges:
- Service CIDR: 10.1.0.0/16
- Pod CIDR: 10.10.0.0/16

Now we'll configure Flannel to assign specific pod CIDR ranges to each node:
- Node 01 (k8s-01-oci-01): 10.10.1.0/24
- Node 02 (k8s-02-oci-02): 10.10.2.0/24
- Node 03 (k8s-03-htg-01): 10.10.3.0/24

### 4.2.1 Patch Nodes with Specific CIDRs

**[Execute ONLY on the control plane node (172.16.0.1)]**

First, we need to patch the nodes to assign specific CIDR ranges:

```bash
# Patch the control plane node
kubectl patch node k8s-01-oci-01 -p '{"spec":{"podCIDR":"10.10.1.0/24","podCIDRs":["10.10.1.0/24"]}}'

# If worker nodes have already joined the cluster (which they shouldn't have yet),
# patch them as well
# kubectl patch node k8s-02-oci-02 -p '{"spec":{"podCIDR":"10.10.2.0/24","podCIDRs":["10.10.2.0/24"]}}'
# kubectl patch node k8s-03-htg-01 -p '{"spec":{"podCIDR":"10.10.3.0/24","podCIDRs":["10.10.3.0/24"]}}'
```

### 4.2.2 Install Flannel

**[Execute ONLY on the control plane node (172.16.0.1)]**

Create a custom Flannel configuration file:

```bash
# Create custom Flannel configuration
cat > kube-flannel.yaml << 'EOF'
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

# Apply Flannel
kubectl apply -f kube-flannel.yaml
```

This configuration:
- Uses VXLAN encapsulation
- Enables DirectRouting for better performance when nodes can communicate directly 
- Works with our VPN-based networking (172.16.0.0/16) between nodes

### 4.2.3 Configure Flannel on Worker Nodes (Optional)

**[Execute on worker nodes if needed]**

If there are network issues after joining worker nodes, you can create a helper script to configure the proper subnets for Flannel:

```bash
# Helper script for worker nodes
cat > fix-flannel-subnet.sh << 'EOF'
#!/bin/bash
# Helper script to configure flannel on worker nodes properly

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

echo "Configuration complete."
EOF

chmod +x fix-flannel-subnet.sh
```

### 4.2.4 Verify Flannel Installation

**[Execute ONLY on the control plane node (172.16.0.1)]**

Wait for all Flannel pods to be in the Running state:

```bash
# Check Flannel pod status
kubectl get pods -n kube-flannel -w
```

Once all pods are running, verify the node status:

```bash
# Verify nodes are in Ready state
kubectl get nodes
```

## 4.3 Joining Worker Nodes with Specific CIDRs

Now that Flannel is installed and configured, we can join worker nodes to the cluster.

### 4.3.1 Generate Join Token on Control Plane

**[Execute ONLY on the control plane node (172.16.0.1)]**

```bash
# Generate a join token
JOIN_COMMAND=$(kubeadm token create --print-join-command)
echo "$JOIN_COMMAND"
```

### 4.3.2 Join Worker Nodes

**[Execute on worker node 02 (172.16.0.2)]**

```bash
# Join the cluster with the node name parameter
# Replace with the actual join command from the previous step
kubeadm join 172.16.0.1:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --node-name=k8s-02-oci-02
```

**[Execute ONLY on the control plane node (172.16.0.1)]**

After worker node 02 joins, patch it with its specific CIDR:

```bash
# Patch worker node 02
kubectl patch node k8s-02-oci-02 -p '{"spec":{"podCIDR":"10.10.2.0/24","podCIDRs":["10.10.2.0/24"]}}'
```

**[Execute on worker node 03 (172.16.0.3)]**

```bash
# Join the cluster with the node name parameter
# Replace with the actual join command from the previous step
kubeadm join 172.16.0.1:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --node-name=k8s-03-htg-01
```

**[Execute ONLY on the control plane node (172.16.0.1)]**

After worker node 03 joins, patch it with its specific CIDR:

```bash
# Patch worker node 03
kubectl patch node k8s-03-htg-01 -p '{"spec":{"podCIDR":"10.10.3.0/24","podCIDRs":["10.10.3.0/24"]}}'
```

## 4.4 Verify Network Configuration

**[Execute ONLY on the control plane node (172.16.0.1)]**

Verify that the nodes have the correct CIDR ranges assigned:

```bash
# Verify node CIDRs
kubectl get nodes -o custom-columns=NAME:.metadata.name,INTERNAL-IP:.status.addresses[0].address,POD-CIDR:.spec.podCIDR
```

All nodes should now be in Ready state. Let's deploy test pods to verify network connectivity:

```bash
# Deploy test pods
kubectl run test-pod-1 --image=nginx --labels="test=network" -n default
kubectl run test-pod-2 --image=nginx --labels="test=network" -n default

# Check pod IPs to confirm they're in the correct ranges
kubectl get pods -l test=network -o wide

# Test connectivity by executing a command in the first pod to ping the second pod
POD_2_IP=$(kubectl get pod test-pod-2 -o jsonpath='{.status.podIP}')
kubectl exec -it test-pod-1 -- ping -c 4 $POD_2_IP
```

## 4.5 Network Policy with Flannel and Optional Add-ons

By default, Flannel itself does not provide network policy enforcement. If you need network policies, you have two main options:

### 4.5.1 Option 1: Deploy NetworkPolicy API Implementation

You can deploy an additional component to handle network policies while keeping Flannel for basic networking:

```bash
# Option 1: Install Calico for policy only (while using Flannel for networking)
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico-policy-only.yaml
```

### 4.5.2 Option 2: Use Kubernetes Network Policies with a Network Policy Engine

If you prefer a simpler approach, you can use a lightweight network policy engine:

```bash
# Option 2: Install NetworkPolicy controller
kubectl apply -f https://github.com/antrea-io/antrea/releases/download/v1.12.0/antrea-policy-only.yml
```

After installing a network policy implementation, you can define policies:

```bash
# Create a namespace for testing
kubectl create namespace network-policy-test

# Label the namespace
kubectl label namespace network-policy-test purpose=network-policy-testing

# Create a default deny all ingress traffic policy
cat > default-deny-ingress.yaml << EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: network-policy-test
spec:
  podSelector: {}
  policyTypes:
  - Ingress
EOF

# Apply the policy
kubectl apply -f default-deny-ingress.yaml
```

## 4.6 Multi-cluster Networking Options

For multi-cloud Kubernetes deployments, you might need to establish communication between clusters. Here are some options:

1. **Submariner**: A project focused on connecting multiple Kubernetes clusters, compatible with Flannel.

2. **Service Mesh (Istio/Linkerd)**: Implement a service mesh for cross-cluster service discovery and communication.

3. **Multi-cluster Services**:
   - Use a multi-cluster service discovery mechanism
   - Implement Kubernetes federation

4. **VPN Tunnels**:
   - Create VPN tunnels between clusters
   - Configure routing to allow pod-to-pod communication

For our multi-cloud setup, we've already established VPN connectivity between nodes across different cloud providers, which forms the foundation for multi-cluster communication.

---

**Next**: [Chapter 5: Scheduling and Cron Jobs](0500-Chapter_5-Scheduling_and_Cron_Jobs.md)
