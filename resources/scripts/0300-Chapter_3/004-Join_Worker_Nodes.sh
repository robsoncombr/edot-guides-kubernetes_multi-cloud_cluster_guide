#!/bin/bash

# ============================================================================
# 004-Join_Worker_Nodes.sh - Script to join worker nodes to the Kubernetes cluster
# ============================================================================
# 
# DESCRIPTION:
#   This script joins worker nodes to an existing Kubernetes cluster and 
#   automatically configures the Flannel CNI network settings with the 
#   appropriate pod CIDR. It also automatically patches the node on the control
#   plane with the correct pod CIDR allocation.
#
# USAGE:
#   ./004-Join_Worker_Nodes.sh 
#
# ARGUMENTS:
#   None - The script automatically retrieves the join command from the control plane
#
# ORDER OF USE:
#   1. Run Chapter 3 master node initialization script first
#   2. Run CNI setup script on control plane (001-CNI_Setup.sh)
#   3. Run this script on the control plane to join all worker nodes
#   4. Verify with 'kubectl get nodes' on control plane after joining
# ============================================================================

# Source the environment configuration
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
ENV_CONFIG_PATH="$(realpath "$SCRIPT_DIR/../0100-Chapter_1/001-Environment_Config.sh")"

if [ ! -f "$ENV_CONFIG_PATH" ]; then
    echo "Error: Environment configuration file not found at $ENV_CONFIG_PATH"
    exit 1
fi

source "$ENV_CONFIG_PATH"

echo "======================================================================"
echo "Joining Worker Nodes to Kubernetes Cluster"
echo "======================================================================"

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# Check if running on control plane node
HOSTNAME=$(get_current_hostname)
CONTROL_PLANE_HOSTNAME=$(get_node_property "${NODE_CP1}" 0)

if [[ "$HOSTNAME" != "$CONTROL_PLANE_HOSTNAME" ]]; then
    echo "Error: This script must be run on the control plane node ($CONTROL_PLANE_HOSTNAME)"
    echo "Current host: $HOSTNAME"
    exit 1
fi

# Get the kubeadm join command correctly for worker nodes
echo "Generating fresh worker node join token..."
JOIN_CMD=$(kubeadm token create --print-join-command)

# Exit if we couldn't get a join command
if [ -z "$JOIN_CMD" ]; then
    echo "Error: Could not generate a valid join command"
    exit 1
fi

echo "Join command: $JOIN_CMD"

# Create node join and setup script template
echo "Creating node join and network setup script template..."
cat > /tmp/join_template.sh << 'EOF'
#!/bin/bash
set -e

# Environment variables will be replaced dynamically
NODE_NAME="__NODE_NAME__"
NODE_IP="__NODE_IP__"
NODE_POD_CIDR="__NODE_POD_CIDR__"
NODE_INTERFACE="__NODE_INTERFACE__"
JOIN_CMD="__JOIN_CMD__"

echo "======================================================================"
echo "Joining worker node ${NODE_NAME} to Kubernetes cluster"
echo "======================================================================"

# Configure kubelet to use the correct node IP
echo "Setting kubelet node IP configuration..."
mkdir -p /etc/default
cat > /etc/default/kubelet << EOL
KUBELET_EXTRA_ARGS="--node-ip=${NODE_IP} --cluster-dns=__DNS_SERVICE_IP__"
EOL

# Set up proper Flannel subnet configuration BEFORE joining
echo "Configuring Flannel subnet for ${NODE_NAME} with CIDR ${NODE_POD_CIDR}..."
mkdir -p /run/flannel
cat > /run/flannel/subnet.env << EOL
FLANNEL_NETWORK=__POD_CIDR__
FLANNEL_SUBNET=${NODE_POD_CIDR}
FLANNEL_MTU=1450
FLANNEL_IPMASQ=true
FLANNEL_IFACE=${NODE_INTERFACE}
EOL

# Execute join command
echo "Executing join command: ${JOIN_CMD}"
${JOIN_CMD}

if [ $? -ne 0 ]; then
    echo "Error: Failed to join the cluster. Please check the join command and try again."
    exit 1
fi

# Restart kubelet to ensure all configurations are applied
echo "Restarting kubelet service..."
systemctl restart kubelet

echo "======================================================================"
echo "Worker node ${NODE_NAME} joined and network configured successfully!"
echo "Node IP: ${NODE_IP}"
echo "Pod CIDR: ${NODE_POD_CIDR}"
echo "Network Interface: ${NODE_INTERFACE}"
echo ""
echo "Note: It may take a minute for the node to become Ready"
echo "======================================================================"
EOF

# Process each worker node
for NODE_CONFIG in "${NODE_W1}" "${NODE_W2}"; do
    NODE_NAME=$(get_node_property "$NODE_CONFIG" 0)
    NODE_IP=$(get_node_property "$NODE_CONFIG" 1)
    NODE_POD_CIDR=$(get_node_property "$NODE_CONFIG" 2)
    NODE_INTERFACE=$(get_node_property "$NODE_CONFIG" 3)
    
    echo "Preparing to join worker node: $NODE_NAME"
    echo "Node IP: $NODE_IP"
    echo "Pod CIDR: $NODE_POD_CIDR"
    echo "Network Interface: $NODE_INTERFACE"
    
    # Create a customized join script for this node
    JOIN_SCRIPT="/tmp/join_${NODE_NAME}.sh"
    cp /tmp/join_template.sh "$JOIN_SCRIPT"
    
    # Replace placeholder values with actual values
    sed -i "s|__NODE_NAME__|${NODE_NAME}|g" "$JOIN_SCRIPT"
    sed -i "s|__NODE_IP__|${NODE_IP}|g" "$JOIN_SCRIPT"
    sed -i "s|__NODE_POD_CIDR__|${NODE_POD_CIDR}|g" "$JOIN_SCRIPT"
    sed -i "s|__NODE_INTERFACE__|${NODE_INTERFACE}|g" "$JOIN_SCRIPT"
    sed -i "s|__JOIN_CMD__|${JOIN_CMD}|g" "$JOIN_SCRIPT"
    sed -i "s|__POD_CIDR__|${POD_CIDR}|g" "$JOIN_SCRIPT"
    sed -i "s|__DNS_SERVICE_IP__|${DNS_SERVICE_IP}|g" "$JOIN_SCRIPT"
    
    chmod +x "$JOIN_SCRIPT"
    
    # Copy and execute the join script on the worker node
    echo "Copying and executing join script on ${NODE_NAME} (${NODE_IP})..."
    if scp -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$JOIN_SCRIPT" "root@${NODE_IP}:/tmp/"; then
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@${NODE_IP}" "bash /tmp/join_${NODE_NAME}.sh && rm -f /tmp/join_${NODE_NAME}.sh"; then
            echo "Worker node ${NODE_NAME} joined successfully"
            
            # Wait for the node to appear in the cluster
            echo "Waiting for node ${NODE_NAME} to appear in the cluster..."
            ATTEMPTS=0
            MAX_ATTEMPTS=30
            while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
                if kubectl get node "${NODE_NAME}" &>/dev/null; then
                    echo "Node ${NODE_NAME} detected in the cluster."
                    break
                fi
                echo "Waiting for node ${NODE_NAME}... (${ATTEMPTS}/${MAX_ATTEMPTS})"
                sleep 5
                ATTEMPTS=$((ATTEMPTS+1))
            done
            
            if [ $ATTEMPTS -eq $MAX_ATTEMPTS ]; then
                echo "Warning: Node ${NODE_NAME} did not appear in the cluster after waiting"
            else
                # Let Kubernetes assign the Pod CIDR automatically - don't force it
                echo "Kubernetes will assign Pod CIDR for node ${NODE_NAME} automatically."
                
                # Check current CIDR
                CURRENT_CIDR=$(kubectl get node "${NODE_NAME}" -o jsonpath='{.spec.podCIDR}' 2>/dev/null || echo "")
                
                if [ -z "$CURRENT_CIDR" ]; then
                    echo "Note: Pod CIDR is not yet assigned to node ${NODE_NAME}. Kubernetes will assign it shortly."
                else
                    echo "Node ${NODE_NAME} has been assigned Pod CIDR: ${CURRENT_CIDR}"
                    
                    # If CIDR is different from expected, update the Flannel subnet configuration to match
                    if [ "$CURRENT_CIDR" != "$NODE_POD_CIDR" ]; then
                        echo "Note: Kubernetes assigned ${CURRENT_CIDR} instead of expected ${NODE_POD_CIDR}"
                        echo "Updating Flannel subnet configuration to match the Kubernetes-assigned CIDR..."
                        
                        # Create script to update Flannel config to match whatever Kubernetes assigned
                        FLANNEL_UPDATE_SCRIPT="/tmp/update_flannel_${NODE_NAME}.sh"
                        cat > "$FLANNEL_UPDATE_SCRIPT" << EOF
#!/bin/bash
# Update Flannel subnet configuration with the Kubernetes-assigned CIDR
ASSIGNED_CIDR="${CURRENT_CIDR}"
echo "Updating Flannel subnet configuration with Kubernetes-assigned CIDR: \${ASSIGNED_CIDR}"

mkdir -p /run/flannel
cat > /run/flannel/subnet.env << EOL
FLANNEL_NETWORK=${POD_CIDR}
FLANNEL_SUBNET=\${ASSIGNED_CIDR}
FLANNEL_MTU=1450
FLANNEL_IPMASQ=true
FLANNEL_IFACE=${NODE_INTERFACE}
EOL

# Restart the Flannel pod to apply changes
FLANNEL_PODS=\$(crictl pods --name flannel -q 2>/dev/null)
if [ -n "\$FLANNEL_PODS" ]; then
    echo "Restarting Flannel pods: \$FLANNEL_PODS"
    crictl rmp -f \$FLANNEL_PODS
else
    echo "No Flannel pods found using crictl, trying to restart kubelet"
    systemctl restart kubelet
fi

echo "Flannel subnet configuration updated to match Kubernetes-assigned CIDR: \${ASSIGNED_CIDR}"
EOF
                        chmod +x "$FLANNEL_UPDATE_SCRIPT"
                        scp -o StrictHostKeyChecking=no "$FLANNEL_UPDATE_SCRIPT" "root@${NODE_IP}:/tmp/"
                        ssh -o StrictHostKeyChecking=no "root@${NODE_IP}" "bash /tmp/update_flannel_${NODE_NAME}.sh && rm -f /tmp/update_flannel_${NODE_NAME}.sh"
                        
                        echo "Flannel subnet configuration updated on ${NODE_NAME} to match Kubernetes-assigned CIDR"
                    else
                        echo "Node ${NODE_NAME} was assigned the expected CIDR: ${CURRENT_CIDR}"
                    fi
                fi
            fi
        else
            echo "Error: Failed to execute join script on ${NODE_NAME}"
        fi
    else
        echo "Error: Failed to copy join script to ${NODE_NAME}"
    fi
done

# Clean up temporary files
rm -f /tmp/join_template.sh
rm -f /tmp/join_k8s-*.sh

echo "======================================================================"
echo "Worker node join process completed!"
echo ""
echo "Verifying node status and CIDR assignments:"
kubectl get nodes -o custom-columns=NAME:.metadata.name,INTERNAL-IP:.status.addresses[0].address,POD-CIDR:.spec.podCIDR,STATUS:.status.conditions[-1].type
echo ""
echo "Note: It may take a few minutes for all nodes to become Ready"
echo "======================================================================"
