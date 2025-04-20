#!/bin/bash

# ============================================================================
# 004-Join_Worker_Nodes.sh - Script to join worker nodes to the Kubernetes cluster
# ============================================================================
# 
# DESCRIPTION:
#   This script joins a worker node to an existing Kubernetes cluster and 
#   automatically configures the Flannel CNI network settings with the 
#   appropriate pod CIDR. It also automatically patches the node on the control
#   plane with the correct pod CIDR allocation.
#
# USAGE:
#   ./004-Join_Worker_Nodes.sh 'kubeadm join ... --token ... --discovery-token-ca-cert-hash ...'
#
# ARGUMENTS:
#   $1 - The 'kubeadm join' command to use for joining the cluster
#
# ORDER OF USE:
#   1. Run Chapter 3 master node initialization script first
#   2. Run CNI setup script on control plane (001-CNI_Setup.sh)
#   3. Run this script on each worker node with the join command
#   4. Verify with 'kubectl get nodes' on control plane after joining
#
# CIDR ALLOCATIONS:
#   - Service CIDR: 10.1.0.0/16 (defined during kubeadm init)
#   - Pod CIDR: 10.10.0.0/16 (used by Flannel)
#   - Node-specific pod CIDRs:
#     - Node 01 (k8s-01-oci-01): 10.10.1.0/24
#     - Node 02 (k8s-02-oci-02): 10.10.2.0/24
#     - Node 03 (k8s-03-htg-01): 10.10.3.0/24
#
# NOTES:
#   - The script automatically handles both local Flannel subnet configuration
#     and remote CIDR patching on the control plane
#   - Node numbers are extracted from hostnames to determine proper CIDR
#   - Requires root privileges to run
#   - Requires password-less SSH access to the control plane (172.16.0.1)
# ============================================================================

echo "======================================================================"
echo "Joining Worker Nodes to Kubernetes Cluster"
echo "======================================================================"

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# Check if join command is provided
if [ -z "$1" ]; then
    echo "Error: No join command provided."
    echo "Usage: $0 'kubeadm join ... --token ... --discovery-token-ca-cert-hash ...'"
    exit 1
fi

JOIN_COMMAND="$1"

echo "Joining this node to the Kubernetes cluster..."
echo "Using command: $JOIN_COMMAND"

# Execute the join command
$JOIN_COMMAND

if [ $? -ne 0 ]; then
    echo "Error: Failed to join the cluster. Check the join command and try again."
    exit 1
fi

echo "Node joined successfully!"

# Get the node name that just joined
NODE_NAME=$(hostname)

# Extract the node number from hostname using improved pattern matching
if [[ $NODE_NAME =~ k8s-([0-9]+)[-] ]]; then
    NODE_NUM=${BASH_REMATCH[1]}
    # Remove any leading zeros
    NODE_NUM=$(echo $NODE_NUM | sed 's/^0*//')
else
    # Fallback for alternative hostname formats
    NODE_NUM=${NODE_NAME##*-}
    # Remove any leading zeros
    NODE_NUM=$(echo $NODE_NUM | sed 's/^0*//')
fi

# Safety check to ensure we have a valid node number
if [[ ! $NODE_NUM =~ ^[0-9]+$ ]]; then
    echo "Error: Could not extract valid node number from hostname."
    echo "Please ensure hostname follows the expected format (k8s-XX-*)"
    exit 1
fi

# Define the pod CIDR based on node number
POD_CIDR="10.10.${NODE_NUM}.0/24"

# Path to the Flannel fix script from Chapter 4
FLANNEL_FIX_SCRIPT="$(dirname "$0")/../0400-Chapter_4/001_fix-Flannel_Subnet.sh"

# Apply Flannel subnet fix
echo "Applying Flannel subnet configuration fix..."
if [ -f "$FLANNEL_FIX_SCRIPT" ]; then
    # Execute the fix script
    echo "Using the centralized Flannel fix script..."
    bash "$FLANNEL_FIX_SCRIPT"
else
    echo "Error: Flannel fix script not found at $FLANNEL_FIX_SCRIPT"
    echo "Cannot configure Flannel networking properly. Please ensure the fix script exists."
    exit 1
fi

# Create a script to run on the control plane to patch this node
echo "Creating CIDR patching script for control plane..."
cat > /tmp/patch_node_cidr.sh << EOF
#!/bin/bash
# Wait for node to appear in the cluster
ATTEMPTS=0
MAX_ATTEMPTS=30
while [ \$ATTEMPTS -lt \$MAX_ATTEMPTS ]; do
    if kubectl get node $NODE_NAME &>/dev/null; then
        break
    fi
    echo "Waiting for node $NODE_NAME to appear in the cluster..."
    sleep 5
    ATTEMPTS=\$((ATTEMPTS+1))
done

if [ \$ATTEMPTS -eq \$MAX_ATTEMPTS ]; then
    echo "Error: Node $NODE_NAME did not appear in the cluster after waiting"
    exit 1
fi

# Check current CIDR before patching
CURRENT_CIDR=\$(kubectl get node $NODE_NAME -o jsonpath='{.spec.podCIDR}' 2>/dev/null || echo "")
if [ -z "\$CURRENT_CIDR" ]; then
    echo "Patching node $NODE_NAME with CIDR $POD_CIDR"
    kubectl patch node $NODE_NAME -p '{"spec":{"podCIDR":"$POD_CIDR","podCIDRs":["$POD_CIDR"]}}'
    echo "Node $NODE_NAME patched successfully with CIDR $POD_CIDR"
else
    echo "Node $NODE_NAME already has CIDR \$CURRENT_CIDR, skipping patch"
fi
EOF

# Try to send the script to the control plane and execute it
echo "Attempting to send and execute CIDR patching script on control plane..."
if scp -o StrictHostKeyChecking=no -o ConnectTimeout=5 /tmp/patch_node_cidr.sh root@172.16.0.1:/tmp/ >/dev/null 2>&1; then
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@172.16.0.1 "bash /tmp/patch_node_cidr.sh && rm -f /tmp/patch_node_cidr.sh"; then
        echo "CIDR patching completed successfully on control plane"
    else
        echo "Warning: SSH connection succeeded but CIDR patching on control plane failed"
        MANUAL_PATCH=true
    fi
else
    echo "Warning: Could not connect to control plane via SSH to apply CIDR patch"
    MANUAL_PATCH=true
fi

# If SSH fails, provide clear manual instructions
if [ "$MANUAL_PATCH" = true ]; then
    echo ""
    echo "===================================================================="
    echo "IMPORTANT: Manual Action Required on Control Plane Node"
    echo "===================================================================="
    echo "Please run the following commands on the control plane node (k8s-01-oci-01):"
    echo ""
    echo "# Wait for node to appear (might take a few seconds)"
    echo "kubectl get nodes | grep $NODE_NAME"
    echo ""
    echo "# Apply the correct Pod CIDR"
    echo "kubectl patch node $NODE_NAME -p '{\"spec\":{\"podCIDR\":\"$POD_CIDR\",\"podCIDRs\":[\"$POD_CIDR\"]}}'"
    echo ""
    echo "# Verify the CIDR was assigned correctly"
    echo "kubectl get node $NODE_NAME -o custom-columns=NAME:.metadata.name,POD-CIDR:.spec.podCIDR"
    echo "===================================================================="
fi

rm -f /tmp/patch_node_cidr.sh

echo "======================================================================"
echo "Worker node joined and network configured successfully!"
echo "Pod CIDR: $POD_CIDR"
echo "Local Flannel subnet configured"
if [ "$MANUAL_PATCH" != true ]; then
    echo "Control plane node patching completed"
else
    echo "Control plane node patching requires manual steps (see above)"
fi
echo ""
echo "To verify the configuration, run on the control plane:"
echo "  kubectl get nodes -o custom-columns=NAME:.metadata.name,INTERNAL-IP:.status.addresses[0].address,POD-CIDR:.spec.podCIDR"
echo ""
echo "Note: It may take a minute for the node to become Ready"
echo "======================================================================"
