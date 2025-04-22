# Chapter 3: Kubernetes Installation and Basic Configuration

This chapter covers the installation and basic configuration of Kubernetes components on Linux-based systems. Before proceeding, ensure that you have completed the prerequisites covered in Chapter 2, including OS preparation and container runtime installation.

## Cluster Node Information

For this guide, we will use the following cluster configuration:

| Role | Hostname | IP Address |
|------|----------|------------|
| Control Plane | k8s-01-oci-01 | 172.16.0.1 |
| Worker | k8s-02-oci-02 | 172.16.0.2 |
| Worker | k8s-03-htg-01 | 172.16.0.3 |

All servers can reach each other via these VPN IPs using SSH with root access, as configured in the Prerequisites.

## 3.1 Installing Kubernetes Components (kubelet, kubeadm, kubectl)

Before installing Kubernetes components, we need to install various dependencies and prepare the system.

### 3.1.1 Essential System Dependencies

**[Execute on ALL nodes: control plane and worker nodes]**

You can run these commands on each node individually or use SSH to execute them on all nodes from your control machine:

```bash
# Option 1: Run on each node individually
# Network & Debugging Tools
sudo apt-get update
sudo apt-get install -y \
  apt-transport-https \
  curl \
  wget \
  zip \
  unzip \
  bzip2 \
  net-tools \
  netcat-openbsd \
  socat \
  iputils-ping \
  telnet \
  traceroute \
  dnsutils \
  nmap \
  tcpdump

# System Tools and Monitoring
sudo apt-get install -y \
  nfs-kernel-server \
  tmux \
  htop \
  iftop \
  iotop \
  conntrack \
  ebtables \
  ipset \
  lsof

# Development Tools
sudo apt-get install -y \
  vim \
  git \
  build-essential \
  ca-certificates \
  gnupg \
  lsb-release \
  libpcap0.8
```

Alternatively, you can execute these commands on all nodes from your control plane node using SSH:

```bash
# Option 2: Run on all nodes from the control plane
# Create a simple script to install dependencies
cat > install_dependencies.sh << 'EOF'
#!/bin/bash
# Update package lists
apt-get update

# Install Network & Debugging Tools
apt-get install -y \
  apt-transport-https \
  curl \
  wget \
  zip \
  unzip \
  bzip2 \
  net-tools \
  netcat-openbsd \
  socat \
  iputils-ping \
  telnet \
  traceroute \
  dnsutils \
  nmap \
  tcpdump

# Install System Tools and Monitoring
apt-get install -y \
  nfs-kernel-server \
  tmux \
  htop \
  iftop \
  iotop \
  conntrack \
  ebtables \
  ipset \
  lsof

# Install Development Tools
apt-get install -y \
  vim \
  git \
  build-essential \
  ca-certificates \
  gnupg \
  lsb-release \
  libpcap0.8

echo "Dependencies installation completed on $(hostname)"
EOF

# Make the script executable
chmod +x install_dependencies.sh

# Execute the script on all nodes
# Control plane node
bash ./install_dependencies.sh

# Worker node 1
scp install_dependencies.sh root@172.16.0.2:/tmp/
ssh root@172.16.0.2 "bash /tmp/install_dependencies.sh"

# Worker node 2
scp install_dependencies.sh root@172.16.0.3:/tmp/
ssh root@172.16.0.3 "bash /tmp/install_dependencies.sh"
```

### 3.1.2 Add Kubernetes Repository

**[Execute on ALL nodes: control plane and worker nodes]**

```bash
# Option 1: Run on each node individually
# Create the keyrings directory
sudo mkdir -p /etc/apt/keyrings

# Add Kubernetes GPG key
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-archive-keyring.gpg

# Add Kubernetes apt repository
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-archive-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

# Update package listings
sudo apt-get update
```

Alternatively, use SSH to execute on all nodes from the control plane:

```bash
# Option 2: Run on all nodes from the control plane
# Create a script to add Kubernetes repository
cat > add_kube_repo.sh << 'EOF'
#!/bin/bash
# Create the keyrings directory
mkdir -p /etc/apt/keyrings

# Add Kubernetes GPG key
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-archive-keyring.gpg

# Add Kubernetes apt repository
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-archive-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list

# Update package listings
apt-get update

echo "Kubernetes repository added on $(hostname)"
EOF

# Make the script executable
chmod +x add_kube_repo.sh

# Execute on all nodes
# Control plane
bash ./add_kube_repo.sh

# Worker nodes
for NODE in 172.16.0.2 172.16.0.3; do
  scp add_kube_repo.sh root@$NODE:/tmp/
  ssh root@$NODE "bash /tmp/add_kube_repo.sh"
done
```

### 3.1.3 Install Kubernetes Components

**[Execute on ALL nodes: control plane and worker nodes]**

```bash
# Option 1: Run on each node individually
# Install kubelet, kubeadm, and kubectl
sudo apt-get install -y kubelet kubeadm kubectl etcd-client containernetworking-plugins

# Pin the installed packages at their current versions to prevent automatic updates
sudo apt-mark hold kubelet kubeadm kubectl
```

Alternatively, use SSH to execute on all nodes from the control plane:

```bash
# Option 2: Run on all nodes from the control plane
# Create a script to install Kubernetes components
cat > install_kube.sh << 'EOF'
#!/bin/bash
# Install Kubernetes components
apt-get install -y kubelet kubeadm kubectl etcd-client containernetworking-plugins

# Pin packages
apt-mark hold kubelet kubeadm kubectl

echo "Kubernetes components installed on $(hostname)"
EOF

# Make the script executable
chmod +x install_kube.sh

# Execute on all nodes
# Control plane
bash ./install_kube.sh

# Worker nodes
for NODE in 172.16.0.2 172.16.0.3; do
  scp install_kube.sh root@$NODE:/tmp/
  ssh root@$NODE "bash /tmp/install_kube.sh"
done
```

## 3.2 Initializing the Control Plane

### 3.2.1 Configure Container Runtime 

**[Execute on ALL nodes: control plane and worker nodes]**

> **Note:** While both Docker and containerd are supported, containerd is recommended for newer Kubernetes versions.

Ensure your container runtime is properly configured as outlined in Chapter 2. The key requirements are:
- Using systemd as the cgroup driver
- Proper configuration of the container runtime

### 3.2.2 Enable Required Kernel Modules and System Settings

**[Execute on ALL nodes: control plane and worker nodes]**

```bash
# Option 1: Run on each node individually
# Enable and load required kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Set required sysctl parameters
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

# Apply sysctl params without reboot
sudo sysctl --system
```

Alternatively, use SSH to execute on all nodes from the control plane:

```bash
# Option 2: Run on all nodes from the control plane
# Create a script to configure kernel modules and sysctl settings
cat > configure_kernel.sh << 'EOF'
#!/bin/bash
# Enable and load required kernel modules
cat > /etc/modules-load.d/k8s.conf << MODULES
overlay
br_netfilter
MODULES

modprobe overlay
modprobe br_netfilter

# Set required sysctl parameters
cat > /etc/sysctl.d/k8s.conf << SYSCTL
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYSCTL

# Apply sysctl params without reboot
sysctl --system

echo "Kernel modules and sysctl settings configured on $(hostname)"
EOF

# Make the script executable
chmod +x configure_kernel.sh

# Execute on all nodes
# Control plane
bash ./configure_kernel.sh

# Worker nodes
for NODE in 172.16.0.2 172.16.0.3; do
  scp configure_kernel.sh root@$NODE:/tmp/
  ssh root@$NODE "bash /tmp/configure_kernel.sh"
done
```

### 3.2.3 Initialize the Control Plane Node

**[Execute ONLY on the control plane node (172.16.0.1)]**

With all prerequisites in place, we'll create a custom configuration file for the Kubernetes control plane initialization to specify our network architecture:

```bash
# Create a kubeadm configuration file with custom network settings
cat > kubeadm-config.yaml << EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
nodeRegistration:
  name: k8s-01-oci-01
  kubeletExtraArgs:
    node-ip: 172.16.0.1
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
networking:
  serviceSubnet: "10.1.0.0/16"  # CIDR for Kubernetes services
  podSubnet: "10.10.0.0/16"     # CIDR for pods across all nodes
controlPlaneEndpoint: "172.16.0.1:6443"
apiServer:
  certSANs:
  - "172.16.0.1"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF
```

Initialize the Kubernetes control plane using this configuration:

```bash
# Initialize the Kubernetes control plane with the config file
sudo kubeadm init --config=kubeadm-config.yaml --upload-certs

# If you're setting up a multi-cloud environment with VPN and have additional IPs,
# you might need to add:
# --apiserver-cert-extra-sans=<VPN_IP>,<PUBLIC_IP>
```

After successful initialization, you'll see output with commands to:
1. Set up kubeconfig for the admin user
2. Instructions to install a CNI network plugin
3. Join worker nodes to the cluster

> **Important:** Do not join worker nodes until you've installed a CNI plugin as detailed in Chapter 4. The control plane node will remain in NotReady state until networking is configured.

## 3.3 Setting up kubectl Configuration

**[Execute ONLY on the control plane node (172.16.0.1)]**

Configure kubectl for the regular user:

```bash
# Create .kube directory for the user
mkdir -p $HOME/.kube

# Copy admin kubeconfig file 
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config

# Set proper ownership
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

Verify the cluster status:

```bash
# Check node status (will show NotReady until CNI is configured in Chapter 4)
kubectl get nodes

# Check system pods
kubectl get pods -n kube-system
```

> **Note:** At this point, the control plane node will show as "NotReady" because we haven't installed a Container Network Interface (CNI) plugin yet. This will be addressed in Chapter 4: Networking with CNI Implementation.

## 3.4 Joining Worker Nodes to the Cluster

### 3.4.1 CIDR Allocations

To ensure proper node-to-node communication, we've designed our Kubernetes network with specific CIDR ranges:

- **Service CIDR**: 10.1.0.0/16 (defined during kubeadm init)
- **Pod CIDR**: 10.10.0.0/16 (used by Flannel)
- **Node-specific pod CIDRs**:
  - Node 01 (k8s-01-oci-01): 10.10.1.0/24
  - Node 02 (k8s-02-oci-02): 10.10.2.0/24
  - Node 03 (k8s-03-htg-01): 10.10.3.0/24

These CIDR ranges will be used when configuring the Flannel CNI in Chapter 4. We'll ensure each node uses its assigned subnet for pod networking.

### 3.4.2 Joining Worker Nodes

**[Execute on the control plane node (172.16.0.1) to get the join command]**

After initializing the control plane, you'll receive a join command. If you need to generate a new one:

```bash
# Generate a new join token
JOIN_COMMAND=$(kubeadm token create --print-join-command)
echo "$JOIN_COMMAND"
```

You can execute the join command directly on each worker node or use SSH to run it remotely from the control plane:

**[Option 1: Execute the join command directly on each worker node]**

```bash
# Example join command (the actual token and hash will be different)
sudo kubeadm join 172.16.0.1:6443 --token <TOKEN> \
    --discovery-token-ca-cert-hash sha256:<HASH>
```

**[Option 2: Execute the join command remotely from the control plane]**

```bash
# Generate token and join command
JOIN_COMMAND=$(kubeadm token create --print-join-command)

# Join worker node 1 (172.16.0.2)
ssh root@172.16.0.2 "$JOIN_COMMAND"

# Join worker node 2 (172.16.0.3)
ssh root@172.16.0.3 "$JOIN_COMMAND"
```

**[Execute on the control plane node (172.16.0.1) to verify]**

After joining, verify on the control plane that the nodes have joined successfully:

```bash
# Check node status
kubectl get nodes
```

> **Note:** Nodes will remain in NotReady state until a CNI plugin is installed. Installation of management interfaces and dashboards will be covered in Chapter 7: Advanced Cluster Configuration.

## Next

[Addendums](./0399-Chapter_3-Addendums.md):

- Cleaning_Up_Kubernetes_Before_Fresh_Installation

---

**Next**: [Chapter 3 Addendums](0399-Chapter_3-Addendums.md)
