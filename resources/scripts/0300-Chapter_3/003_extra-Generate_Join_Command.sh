#!/bin/bash

# Script to generate a join command for worker nodes
# This should be run on the control plane node if needs
#   to be re-generated or if the token has expired

echo "Generating new join token and command for worker nodes..."

# Generate a new join token and command
JOIN_COMMAND=$(kubeadm token create --print-join-command)

# Save the join command to a file for later use
echo "$JOIN_COMMAND" > /tmp/kubeadm-join-command.txt

echo ""
echo "==========================================================================="
echo "Join command generated successfully!"
echo ""
echo "Worker node join command:"
echo "$JOIN_COMMAND"
echo ""
echo "The join command has been saved to: /tmp/kubeadm-join-command.txt"
echo ""
echo "IMPORTANT:"
echo "- This command contains a token that is valid for 24 hours"
echo "- Do *not* join worker nodes until you've installed a CNI plugin (Chapter 4)"
echo "- Remember to secure this token information"
echo "==========================================================================="
