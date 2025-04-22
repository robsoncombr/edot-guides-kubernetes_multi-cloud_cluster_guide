#!/bin/bash

# ============================================================================
# 002-Add_New_Node_Configuration.sh - Add a new node to the environment config
# ============================================================================
# 
# DESCRIPTION:
#   This script adds a new node configuration to the environment configuration 
#   file. It collects all necessary information about the new node and updates
#   the configuration file with the proper format and CIDR allocation.
#
# USAGE:
#   ./002-Add_New_Node_Configuration.sh
#
# NOTES:
#   - Run this script before attempting to join a new node to the cluster
#   - This updates the central environment configuration only
#   - After running this, you still need to prepare the node and join it
# ============================================================================

# Define environment configuration file path
ENV_CONFIG_PATH="/root/data/development/edot-guides-kubernetes_multi-cloud_cluster_guide/resources/scripts/0100-Chapter_1/001-Environment_Config.sh"

if [ ! -f "$ENV_CONFIG_PATH" ]; then
    echo "Error: Environment configuration file not found at $ENV_CONFIG_PATH"
    exit 1
fi

echo "======================================================================"
echo "Adding a New Node to Environment Configuration"
echo "======================================================================"

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# Source the environment config to get existing setup
source "$ENV_CONFIG_PATH"

# Display existing nodes
echo "Current node configuration:"
print_node_configs
echo ""

# Calculate the next node number
NEXT_NODE_NUM=$(( $(echo "${ALL_NODES[@]}" | tr ' ' '\n' | wc -l) + 1 ))
echo "Adding node #$NEXT_NODE_NUM to the configuration..."

# Collect information about the new node
read -p "Enter node hostname (e.g., k8s-04-aws-01): " NEW_NODE_HOSTNAME
read -p "Enter node IP address on VPN (e.g., 172.16.0.4): " NEW_NODE_VPN_IP
read -p "Enter network interface name (e.g., ens5, eth0, enp0s6): " NEW_NODE_INTERFACE
read -p "Enter node role (control-plane or worker): " NEW_NODE_ROLE
read -p "Enter node external IP or hostname: " NEW_NODE_EXTERNAL_IP

# Calculate the next CIDR block based on the pattern in existing nodes
NEW_NODE_POD_CIDR="10.10.${NEXT_NODE_NUM}.0/24"

echo "Setting Pod CIDR for new node: $NEW_NODE_POD_CIDR"

# Create the new node configuration string
NEW_NODE_CONFIG="${NEW_NODE_HOSTNAME}:${NEW_NODE_VPN_IP}:${NEW_NODE_POD_CIDR}:${NEW_NODE_INTERFACE}:${NEW_NODE_ROLE}:${NEW_NODE_EXTERNAL_IP}"

echo "New node configuration: $NEW_NODE_CONFIG"
echo ""

# Ask for confirmation
read -p "Add this node to the environment configuration? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Operation cancelled."
    exit 0
fi

# Create backup of the original file
BACKUP_FILE="${ENV_CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
cp "$ENV_CONFIG_PATH" "$BACKUP_FILE"
echo "Backup created at $BACKUP_FILE"

# Update the environment configuration file
if [[ "$NEW_NODE_ROLE" == "control-plane" ]]; then
    # Add as a control plane node
    NEW_NODE_VAR="NODE_CP${NEXT_NODE_NUM}"
    
    # Find the last control plane node line and add after it
    LINE_NUM=$(grep -n "NODE_CP[0-9]*=" "$ENV_CONFIG_PATH" | tail -1 | cut -d: -f1)
    if [ -z "$LINE_NUM" ]; then
        # If no existing control plane nodes, add after worker nodes
        LINE_NUM=$(grep -n "NODE_W[0-9]*=" "$ENV_CONFIG_PATH" | tail -1 | cut -d: -f1)
    fi
    
    # Add the new node definition
    sed -i "${LINE_NUM}a\\${NEW_NODE_VAR}=\"${NEW_NODE_CONFIG}\"" "$ENV_CONFIG_PATH"
else
    # Add as a worker node
    NEW_NODE_VAR="NODE_W${NEXT_NODE_NUM}"
    
    # Find the last worker node line and add after it
    LINE_NUM=$(grep -n "NODE_W[0-9]*=" "$ENV_CONFIG_PATH" | tail -1 | cut -d: -f1)
    if [ -z "$LINE_NUM" ]; then
        # If no existing worker nodes, add after control plane nodes
        LINE_NUM=$(grep -n "NODE_CP[0-9]*=" "$ENV_CONFIG_PATH" | tail -1 | cut -d: -f1)
    fi
    
    # Add the new node definition
    sed -i "${LINE_NUM}a\\${NEW_NODE_VAR}=\"${NEW_NODE_CONFIG}\"" "$ENV_CONFIG_PATH"
fi

# Update the ALL_NODES array to include the new node
ALL_NODES_LINE=$(grep -n "ALL_NODES=" "$ENV_CONFIG_PATH" | cut -d: -f1)
if [ -n "$ALL_NODES_LINE" ]; then
    # Remove closing parenthesis, add the new node variable, and close the parenthesis
    sed -i "${ALL_NODES_LINE}s/)/ \"\$${NEW_NODE_VAR}\")/" "$ENV_CONFIG_PATH"
else
    echo "Error: ALL_NODES array not found in configuration file."
    echo "Please manually add $NEW_NODE_VAR to the ALL_NODES array."
fi

echo "======================================================================"
echo "Node configuration added successfully!"
echo ""
echo "New environment configuration:"
source "$ENV_CONFIG_PATH"  # Re-source to get updated config
print_node_configs
echo ""
echo "Next steps:"
echo "1. Prepare the new node with base requirements (Chapter 2)"
echo "2. Install Kubernetes components on the new node"
echo "3. Join the node to the cluster using the join script"
echo "======================================================================"
