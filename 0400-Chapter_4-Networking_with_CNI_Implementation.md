# Chapter 4: Networking with CNI Implementation

This chapter covers the implementation of Container Network Interface (CNI) in our Kubernetes cluster. We'll use Calico as our CNI plugin with custom CIDR allocation for each node.

## 4.1 CNI Overview and Selection Criteria

Container Network Interface (CNI) is a specification and set of libraries for configuring network interfaces in Linux containers. CNI is essential for Kubernetes as it:

1. Enables pod-to-pod communication across nodes
2. Provides network isolation and security through network policies
3. Supports advanced features like IP address management (IPAM)

Several CNI plugins are available, each with their own advantages:

| CNI Plugin | Key Features | Best For |
|------------|--------------|----------|
| Calico     | - Network policies<br>- VXLAN or BGP routing<br>- Fine-grained security controls | Production environments requiring security and flexibility |
| Flannel    | - Simple setup<br>- VXLAN encapsulation<br>- Lightweight | Development or simpler deployments |
| Cilium     | - eBPF-based<br>- Deep packet inspection<br>- Layer 7 policies | Advanced use cases with security focus |
| Weave Net  | - Mesh overlay network<br>- Encryption<br>- DNS integration | Multi-cloud environments |

For our multi-cloud Kubernetes cluster, we're using Calico for its robust security features and flexibility in network configuration.

## 4.2 Installing and Configuring Calico with Custom Pod CIDR Allocation

In Chapter 3, we initialized our Kubernetes cluster with the following CIDR ranges:
- Service CIDR: 10.1.0.0/16
- Pod CIDR: 10.10.0.0/16

Now we'll configure Calico to assign specific pod CIDR ranges to each node:
- Node 01 (k8s-01-oci-01): 10.10.1.0/24
- Node 02 (k8s-02-oci-02): 10.10.2.0/24
- Node 03 (k8s-03-htg-01): 10.10.3.0/24

### 4.2.1 Patch Nodes with Specific CIDRs

**[Execute ONLY on the control plane node (172.16.0.1)]**

First, we need to patch the nodes to assign specific CIDR ranges:

```bash
# Patch the control plane node
kubectl patch node k8s-01-oci-01 -p '{"spec":{"podCIDR":"10.10.1.0/24"}}'

# If worker nodes have already joined the cluster (which they shouldn't have yet),
# patch them as well
# kubectl patch node k8s-02-oci-02 -p '{"spec":{"podCIDR":"10.10.2.0/24"}}'
# kubectl patch node k8s-03-htg-01 -p '{"spec":{"podCIDR":"10.10.3.0/24"}}'
```

### 4.2.2 Install Calico Operator

**[Execute ONLY on the control plane node (172.16.0.1)]**

```bash
# Download the Calico operator manifest
curl -O https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/tigera-operator.yaml

# Apply the operator manifest
kubectl apply -f tigera-operator.yaml
```

### 4.2.3 Configure Calico Installation with Custom CIDR

**[Execute ONLY on the control plane node (172.16.0.1)]**

Create a custom installation configuration for Calico:

```bash
# Create custom Calico installation configuration
cat > calico-installation.yaml << EOF
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - blockSize: 24
      cidr: 10.10.0.0/16
      encapsulation: VXLAN
      natOutgoing: true
      nodeSelector: all()
  nodeMetricsPort: 9091
EOF

# Apply the custom installation
kubectl apply -f calico-installation.yaml
```

### 4.2.4 Verify Calico Installation

**[Execute ONLY on the control plane node (172.16.0.1)]**

Wait for all Calico pods to be in the Running state:

```bash
# Check Calico pod status
kubectl get pods -n calico-system -w
```

Once all pods are running, verify the node status:

```bash
# Verify nodes are in Ready state
kubectl get nodes

# Check Calico IPAM configuration
kubectl get ippool -o yaml
```

## 4.3 Joining Worker Nodes with Specific CIDRs

Now that Calico is installed and configured, we can join worker nodes to the cluster.

### 4.3.1 Prepare Worker Nodes for Joining

**[Execute on each worker node (172.16.0.2 and 172.16.0.3)]**

Create a kubelet configuration file on each worker node:

```bash
# Worker node 02 (172.16.0.2)
cat > /etc/kubernetes/kubelet-config.yaml << EOF
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF

# Worker node 03 (172.16.0.3)
# Same command as above
```

### 4.3.2 Generate Join Token on Control Plane

**[Execute ONLY on the control plane node (172.16.0.1)]**

```bash
# Generate a join token
JOIN_COMMAND=$(kubeadm token create --print-join-command)
echo "$JOIN_COMMAND"
```

### 4.3.3 Join Worker Nodes

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
kubectl patch node k8s-02-oci-02 -p '{"spec":{"podCIDR":"10.10.2.0/24"}}'
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
kubectl patch node k8s-03-htg-01 -p '{"spec":{"podCIDR":"10.10.3.0/24"}}'
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

## 4.5 Network Policy Setup and Configuration

With Calico installed, we can now implement network policies to control traffic between pods. Network policies are crucial for enforcing security in your Kubernetes cluster.

### 4.5.1 Basic Default Deny Policy

**[Execute ONLY on the control plane node (172.16.0.1)]**

First, let's create a namespace for testing network policies:

```bash
# Create a namespace for testing
kubectl create namespace network-policy-test

# Label the namespace
kubectl label namespace network-policy-test purpose=network-policy-testing
```

Create a default deny policy to block all ingress traffic:

```bash
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

### 4.5.2 Allow Specific Traffic

Now, let's create a more specific policy to allow traffic between pods with certain labels:

```bash
# Create a policy to allow traffic between specific pods
cat > allow-specific-traffic.yaml << EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-specific-traffic
  namespace: network-policy-test
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: api
    ports:
    - protocol: TCP
      port: 80
EOF

# Apply the policy
kubectl apply -f allow-specific-traffic.yaml
```

## 4.6 Multi-cluster Networking Options

For multi-cloud Kubernetes deployments, you might need to establish communication between clusters. Here are some options:

1. **Cluster Mesh with Calico**: Calico Enterprise offers Cluster Mesh to connect multiple Kubernetes clusters.

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
