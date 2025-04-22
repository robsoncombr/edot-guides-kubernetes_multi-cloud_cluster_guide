#!/bin/bash

# Create a script to fix duplicate entries
cat > /tmp/fix_duplicate_entries.sh << 'EOF'
#!/bin/bash
echo "Checking for duplicate repository entries..."

# Check if ubuntu-mirrors.list exists on this node
if [ -f /etc/apt/sources.list.d/ubuntu-mirrors.list ]; then
  echo "Found ubuntu-mirrors.list - creating backup and fixing duplicates"
  
  # Create backup
  sudo cp /etc/apt/sources.list.d/ubuntu-mirrors.list /etc/apt/sources.list.d/ubuntu-mirrors.list.bak
  
  # Use awk to remove duplicate lines
  awk '!seen[$0]++' /etc/apt/sources.list.d/ubuntu-mirrors.list.bak | sudo tee /etc/apt/sources.list.d/ubuntu-mirrors.list > /dev/null
  
  echo "Fixed duplicate entries in ubuntu-mirrors.list on $(hostname)"
else
  echo "No ubuntu-mirrors.list found on $(hostname) - nothing to fix"
fi

# Update package lists
sudo apt-get update
EOF

# Make the script executable
chmod +x /tmp/fix_duplicate_entries.sh

# Execute on all nodes
echo "Fixing duplicate repository entries on 172.16.0.1 ..."
bash /tmp/fix_duplicate_entries.sh

for NODE in 172.16.0.2 172.16.0.3; do
  echo "Fixing duplicate repository entries on $NODE..."
  scp /tmp/fix_duplicate_entries.sh root@$NODE:/tmp/
  ssh root@$NODE "bash /tmp/fix_duplicate_entries.sh && rm -f /tmp/fix_duplicate_entries.sh"
done
rm -f /tmp/fix_duplicate_entries.sh
