#!/bin/bash

# Run commands locally first
echo "--- Local Node Results ---"
lsb_release -a && docker --version && ip addr show | grep -A 2 "172.16.0"

# Loop through remote nodes
for i in {1..3}; do
  echo -e "\n--- Node 172.16.0.$i Results ---"
  ssh -o ConnectTimeout=5 root@172.16.0.$i "lsb_release -a && docker --version && ip addr show | grep -A 2 '172.16.0'" || echo "Connection failed to 172.16.0.$i"
done
