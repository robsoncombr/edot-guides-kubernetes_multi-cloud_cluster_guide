#!/bin/bash

# Create the swap disabling script
cat > /tmp/disable_swap.sh << 'EOF'
#!/bin/bash
# Disable swap immediately
swapoff -a

# Check for swapfile entries in /etc/fstab
SWAPFILES=$(grep -v "^#" /etc/fstab | grep -i "swap" | awk '{print $1}')

if [ -n "$SWAPFILES" ]; then
  echo "Found the following swapfiles configured in /etc/fstab:"
  echo "$SWAPFILES"
  
  for SWAPFILE in $SWAPFILES; do
    if [ -f "$SWAPFILE" ]; then
      echo -n "Delete swapfile $SWAPFILE from disk? (y/N): "
      read -r ANSWER
      
      if [[ "$ANSWER" =~ ^[yY]$ ]]; then
        echo "Deleting swapfile: $SWAPFILE"
        rm -f "$SWAPFILE"
      else
        echo "Skipping deletion of swapfile: $SWAPFILE"
      fi
    fi
  done
fi

# Disable swap permanently by commenting out swap entries in /etc/fstab
sed -i '/ swap / s/^/#/' /etc/fstab

# Verify swap is disabled
echo "Swap status on $(hostname):"
free -h | grep -i swap
EOF

# Make the script executable
chmod +x /tmp/disable_swap.sh

# Execute on all nodes
echo "Disabling swap on 172.16.0.1 ..."
bash /tmp/disable_swap.sh
for NODE in 172.16.0.2 172.16.0.3; do
  echo "Disabling swap on $NODE..."
  scp /tmp/disable_swap.sh root@$NODE:/tmp/
  ssh root@$NODE "bash /tmp/disable_swap.sh && rm -f /tmp/disable_swap.sh"
done
rm -f /tmp/disable_swap.sh
