#!/bin/bash

# Create a script to configure kernel modules and sysctl settings
cat > /tmp/configure_kernel.sh << 'EOF'
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
chmod +x /tmp/configure_kernel.sh

# Execute on all nodes
echo "Configuring kernel modules on 172.16.0.1 ..."
bash /tmp/configure_kernel.sh
for NODE in 172.16.0.2 172.16.0.3; do
  echo "Configuring kernel modules on $NODE..."
  scp /tmp/configure_kernel.sh root@$NODE:/tmp/
  ssh root@$NODE "bash /tmp/configure_kernel.sh && rm -f /tmp/configure_kernel.sh"
done
rm -f /tmp/configure_kernel.sh
