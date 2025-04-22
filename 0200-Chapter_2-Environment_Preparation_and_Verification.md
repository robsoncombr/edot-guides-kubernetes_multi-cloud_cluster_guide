# Chapter 2: Environment Preparation and Verification

## 2.1 Operating System and Hardware Requirements

- Check Ubuntu version
```bash
lsb_release -a
```

## 2.1 Docker Configuration for Kubernetes Compatibility

- Validate Docker installation
```bash
docker --version
```

## 2.3 WireGuard VPN Confirmation and Testing

- Check VPN IP
```bash
ip addr show | grep 172.16.0
```

### 2.4 Disable Swap

**[Execute on ALL nodes: control plane and worker nodes]**

Execute on each node or use SSH to run these commands on all nodes:

```bash
# Option 1: Run on each node individually
# Disable swap immediately
sudo swapoff -a

# Disable swap permanently by commenting out swap entries in /etc/fstab
sudo sed -i '/ swap / s/^/#/' /etc/fstab

# Verify swap is disabled
free -h
```

Alternatively, use SSH to execute on all nodes from the control plane:

```bash
# Option 2: Run on all nodes from the control plane
# Create a script to disable swap
cat > disable_swap.sh << 'EOF'
#!/bin/bash
# Disable swap immediately
swapoff -a

# Disable swap permanently
sed -i '/ swap / s/^/#/' /etc/fstab

# Verify
echo "Swap status on $(hostname):"
free -h | grep -i swap
EOF

# Make the script executable
chmod +x disable_swap.sh

# Execute on all nodes
# Control plane node
bash ./disable_swap.sh

# Worker nodes
for NODE in 172.16.0.2 172.16.0.3; do
  scp disable_swap.sh root@$NODE:/tmp/
  ssh root@$NODE "bash /tmp/disable_swap.sh"
done
```

---

**Next**: [Chapter 3: Kubernetes Installation and Basic Configuration](0300-Chapter_3-Kubernetes_Installation_and_Basic_Configuration.md)
