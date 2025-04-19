#!/bin/bash

# Create a script to fix Helm GPG key
cat > /tmp/fix_helm_gpg.sh << 'EOF'
#!/bin/bash
# Import Helm GPG key
echo "Importing Helm repository GPG key..."
# Add --batch and --yes flags to prevent interactive prompts
curl -fsSL https://baltocdn.com/helm/signing.asc | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/helm.gpg

# Configure repository correctly with the key
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | \
  sudo tee /etc/apt/sources.list.d/helm-stable-debian.list

# Update package lists
sudo apt-get update

echo "Helm GPG key has been imported on $(hostname)"
EOF

# Make the script executable
chmod +x /tmp/fix_helm_gpg.sh

# Execute on all nodes
echo "Fixing Helm GPG key locally..."
bash /tmp/fix_helm_gpg.sh
for NODE in 172.16.0.2 172.16.0.3; do
  echo "Fixing Helm GPG key on $NODE..."
  scp /tmp/fix_helm_gpg.sh root@$NODE:/tmp/
  ssh root@$NODE "bash /tmp/fix_helm_gpg.sh && rm -f /tmp/fix_helm_gpg.sh"
done
rm -f /tmp/fix_helm_gpg.sh
