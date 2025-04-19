#!/bin/bash

# Fixes for installing dependencies on Ubuntu 22.04 for Kubernetes cluster setup
./002_fix-Duplicate_Repository_Entries.sh
./002_fix-Helm_GPG_Key_Issue.sh

# Create a dependencies installation script
cat > /tmp/install_dependencies.sh << 'EOF'
#!/bin/bash
# Update package lists
apt-get update

# Install Network & Debugging Tools
apt-get install -y apt-transport-https curl wget zip unzip bzip2 net-tools \
  netcat-openbsd socat iputils-ping telnet traceroute dnsutils nmap tcpdump

# Install System Tools and Monitoring
apt-get install -y nfs-kernel-server tmux htop iftop iotop conntrack \
  ebtables ipset lsof

# Install Development Tools
apt-get install -y vim git build-essential ca-certificates gnupg \
  lsb-release libpcap0.8

echo "Dependencies installation completed on $(hostname)"
EOF

# Make the script executable
chmod +x /tmp/install_dependencies.sh

# Execute on all nodes
echo "Installing dependencies locally..."
bash /tmp/install_dependencies.sh
for NODE in 172.16.0.2 172.16.0.3; do
  echo "Installing dependencies on $NODE..."
  scp /tmp/install_dependencies.sh root@$NODE:/tmp/
  ssh root@$NODE "bash /tmp/install_dependencies.sh && rm -f /tmp/install_dependencies.sh"
done
rm -f /tmp/install_dependencies.sh
