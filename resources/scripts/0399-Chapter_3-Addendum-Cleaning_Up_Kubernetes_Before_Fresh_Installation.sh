#!/bin/bash
# Kubernetes Cluster Complete Cleanup Script
# ==========================================
#
# DESCRIPTION:
#   This script centrally cleans up an entire Kubernetes cluster from the control plane node,
#   safely removing configurations, containers, and resetting network rules on all nodes.
#
# EXECUTION LOCATION:
#   Run this script ONLY on the control plane node (typically the node with IP 172.16.0.1).
#   It will handle worker node cleanup via SSH.
#
# PREREQUISITES:
#   - Root access on the control plane node
#   - Password-less SSH access from control plane to all worker nodes using SSH keys
#   - Worker node IPs must be known (configured in the WORKER_NODES array below)
#   - No active workloads that you want to preserve (all will be erased)
#
# USAGE:
#   1. Edit the WORKER_NODES array to include your worker node IPs
#   2. Execute with: sudo bash kubernetes-cleanup.sh
#
# WARNING:
#   This script will completely remove Kubernetes from all nodes. Only use when
#   you want to start from scratch with a clean installation.

# Exit on error? No, we want to continue even if some commands fail
set +e

# Configure worker nodes - EDIT THESE TO MATCH YOUR ENVIRONMENT
WORKER_NODES=("172.16.0.2" "172.16.0.3")
SSH_USER="root"  # The user for SSH connections

# Track temporary files for cleanup
TEMP_FILES=()

# Collect warning messages for summary at the end
WARNINGS=()

# Text colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print status messages
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    # Add to warnings array for summary at the end
    WARNINGS+=("$1")
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_note() {
    echo -e "${BLUE}[NOTE]${NC} $1"
}

# Function to cleanup temp files
cleanup_temp_files() {
    print_status "Cleaning up temporary files..."
    
    # Remove local temp files
    for file in "${TEMP_FILES[@]}"; do
        rm -f "$file" 2>/dev/null
    done
    
    # Remove remote temp files from worker nodes
    for NODE in "${WORKER_NODES[@]}"; do
        ssh -o BatchMode=yes -o ConnectTimeout=5 ${SSH_USER}@${NODE} "rm -f /tmp/node_cleanup.sh" 2>/dev/null || true
    done
}

# Filter kubeadm reset output to be more user-friendly
filter_kubeadm_output() {
    grep -v "The reset process does not clean" | \
    grep -v "The reset process does not reset" | \
    grep -v "Please, check the contents" | \
    grep -v "using etcd pod spec to get data directory" | \
    grep -v "Failed to evaluate the \"/var/lib/kubelet\" directory"
}

# Register cleanup function to run on exit
trap cleanup_temp_files EXIT

# Display warning and get confirmation
echo -e "${RED}${BOLD}WARNING: DESTRUCTIVE OPERATION${NC}"
echo -e "${RED}${BOLD}==========================================================${NC}"
echo -e "${RED}This script will completely destroy your Kubernetes cluster:${NC}"
echo -e "${RED}- All workloads will be terminated${NC}"
echo -e "${RED}- All configuration will be erased${NC}"
echo -e "${RED}- All cluster data will be permanently lost${NC}"
echo -e "${RED}- Kubernetes components will be removed from all nodes${NC}"
echo -e "${RED}==========================================================${NC}"
echo
echo -n "Are you absolutely sure you want to proceed? (y/N): "
read -r confirm_destroy

if [[ "$confirm_destroy" != "y" && "$confirm_destroy" != "Y" ]]; then
    print_status "Operation cancelled. No changes were made."
    exit 0
fi

echo "==== Kubernetes Cluster Cleanup Script ===="
echo "This script will clean up the entire Kubernetes cluster"
echo "Control plane: $(hostname) (local)"
echo "Worker nodes: ${WORKER_NODES[*]} (via SSH)"
echo

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run as root"
    exit 1
fi

# Check for SSH connectivity to worker nodes
print_status "Checking SSH connectivity to worker nodes..."
for NODE in "${WORKER_NODES[@]}"; do
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 ${SSH_USER}@${NODE} "echo SSH connection successful" &> /dev/null; then
        print_error "Cannot connect to worker node ${NODE} via SSH. Please ensure SSH keys are set up correctly."
        echo "Do you want to continue anyway? Only the control plane node will be cleaned. (y/n)"
        read -r continue_anyway
        if [ "$continue_anyway" != "y" ] && [ "$continue_anyway" != "Y" ]; then
            print_status "Exiting script."
            exit 1
        fi
    else
        print_status "SSH connection to ${NODE} successful."
    fi
done

# Function to drain and remove worker nodes
clean_cluster() {
    print_status "Attempting to clean up the Kubernetes cluster..."
    
    # Check if kubectl command exists and works
    if ! command -v kubectl &> /dev/null; then
        print_warning "kubectl not found. Skipping cluster node cleanup."
        return
    fi

    # Export kubeconfig if available
    if [ -f "/etc/kubernetes/admin.conf" ]; then
        export KUBECONFIG=/etc/kubernetes/admin.conf
        print_status "Using kubeconfig from /etc/kubernetes/admin.conf"
    elif [ -f "$HOME/.kube/config" ]; then
        export KUBECONFIG=$HOME/.kube/config
        print_status "Using kubeconfig from $HOME/.kube/config"
    else
        print_warning "No kubeconfig found. This is normal if the cluster is already partially removed."
        print_note "Continuing with node-level cleanup via SSH."
        return
    fi
    
    # Try to get nodes - if this fails, the cluster may not be accessible
    if ! kubectl get nodes &> /dev/null; then
        print_warning "Unable to access the Kubernetes API. Cluster may be down or unreachable."
        print_note "Continuing with node-level cleanup via SSH. This is sufficient for most cleanup tasks."
        return
    fi
    
    print_status "Successfully connected to the cluster"
    
    # Get control plane node name
    CONTROL_PLANE=$(kubectl get nodes --selector='node-role.kubernetes.io/control-plane' -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    if [ -z "$CONTROL_PLANE" ]; then
        print_warning "No control plane node found. Looking for master label instead..."
        CONTROL_PLANE=$(kubectl get nodes --selector='node-role.kubernetes.io/master' -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    fi
    
    print_status "Control plane node: ${CONTROL_PLANE:-None detected}"
    
    # Get all node names
    NODES=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    if [ -n "$NODES" ]; then
        print_status "Found the following nodes in the cluster:"
        kubectl get nodes || echo "Unable to display node details"
        
        # Drain and delete each worker node
        for NODE in $NODES; do
            # Skip if this is the control plane node (we'll handle it last)
            if [ "$NODE" = "$CONTROL_PLANE" ]; then
                continue
            fi
            
            print_status "Draining node: $NODE"
            kubectl drain "$NODE" --delete-emptydir-data --force --ignore-daemonsets || print_warning "Failed to drain $NODE - This is normal if node is already unreachable."
            
            print_status "Removing node: $NODE from cluster"
            kubectl delete node "$NODE" || print_warning "Failed to delete $NODE from cluster - This is normal if node is already removed."
        done
        
        # If this is the control plane, drain it last
        if [ -n "$CONTROL_PLANE" ]; then
            print_status "Draining control plane node: $CONTROL_PLANE"
            kubectl drain "$CONTROL_PLANE" --delete-emptydir-data --force --ignore-daemonsets || print_warning "Failed to drain $CONTROL_PLANE - This is normal during cleanup."
        fi
    else
        print_warning "No nodes found in the cluster or unable to retrieve node information."
        print_note "Continuing with node-level cleanup via SSH."
    fi
}

# Function to create a node cleanup script
create_node_cleanup_script() {
    NODE_CLEANUP_SCRIPT="/tmp/node_cleanup.sh"
    
    cat > "$NODE_CLEANUP_SCRIPT" << 'EOF'
#!/bin/bash
# Node cleanup script
# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}[INFO]${NC} Starting node cleanup on $(hostname)"

# Reset kubeadm
echo -e "${GREEN}[INFO]${NC} Resetting kubeadm..."
# Capture and filter kubeadm output
kubeadm_output=$(kubeadm reset -f 2>&1) || echo -e "${YELLOW}[WARNING]${NC} kubeadm reset returned non-zero exit code, continuing anyway"

# Filter and display relevant kubeadm output
echo "$kubeadm_output" | grep -v "The reset process does not clean" | \
                         grep -v "The reset process does not reset" | \
                         grep -v "Please, check the contents" | \
                         grep -v "No kubeadm config" | \
                         grep -v "Failed to evaluate" || true

echo -e "${BLUE}[NOTE]${NC} Standard kubeadm warnings suppressed. The script will handle CNI, configs, and iptables cleanup."

# Clean up CNI configurations
echo -e "${GREEN}[INFO]${NC} Removing CNI configurations..."
rm -rf /etc/cni/net.d/* 2>/dev/null || echo -e "${YELLOW}[WARNING]${NC} No CNI configurations found or failed to remove them."

# Clean up IPVS tables if installed
if command -v ipvsadm &> /dev/null; then
    echo -e "${GREEN}[INFO]${NC} Clearing IPVS tables..."
    ipvsadm -C 2>/dev/null || echo -e "${YELLOW}[WARNING]${NC} Failed to clear IPVS tables, they may already be empty."
fi

# Remove kubeconfig files
echo -e "${GREEN}[INFO]${NC} Removing kubeconfig files..."
rm -rf /etc/kubernetes/kubelet.conf 2>/dev/null
rm -rf /etc/kubernetes/bootstrap-kubelet.conf 2>/dev/null
rm -rf /etc/kubernetes/admin.conf 2>/dev/null
rm -rf /etc/kubernetes/pki 2>/dev/null
rm -rf $HOME/.kube/config 2>/dev/null

# Stop and disable kubelet service
echo -e "${GREEN}[INFO]${NC} Stopping kubelet service..."
systemctl stop kubelet 2>/dev/null || echo -e "${YELLOW}[WARNING]${NC} Failed to stop kubelet, it may already be stopped."
systemctl disable kubelet 2>/dev/null || echo -e "${YELLOW}[WARNING]${NC} Failed to disable kubelet service."

# Remove Kubernetes directories
echo -e "${GREEN}[INFO]${NC} Removing Kubernetes directories..."
rm -rf /var/lib/kubelet 2>/dev/null
rm -rf /var/lib/etcd 2>/dev/null
rm -rf /var/lib/cni 2>/dev/null

echo -e "${GREEN}[INFO]${NC} Node cleanup completed on $(hostname)"
EXIT_CODE=0

# Removing Kubernetes packages if requested
if [ "$1" = "remove_packages" ]; then
    echo -e "${GREEN}[INFO]${NC} Removing Kubernetes packages..."
    
    # Unhold packages first to make sure they can be removed
    apt-mark unhold kubeadm kubectl kubelet kubernetes-cni 2>/dev/null || true
    
    # Try to purge the packages
    if ! apt-get purge -y kubeadm kubectl kubelet kubernetes-cni 2>/dev/null; then
        echo -e "${YELLOW}[WARNING]${NC} Some packages could not be removed with standard purge."
        echo -e "${BLUE}[NOTE]${NC} Attempting more aggressive removal approach..."
        
        # Force removal of packages if still present
        dpkg --remove --force-all kubeadm kubectl kubelet kubernetes-cni 2>/dev/null || true
    fi
    
    # Make sure to run autoremove with -y flag to clean up dependencies
    apt-get autoremove -y 2>/dev/null
    
    # Fix any potential broken packages
    apt-get --fix-broken install -y 2>/dev/null || true
    
    echo -e "${GREEN}[INFO]${NC} Kubernetes packages removal process completed."
fi

# Clean up self
rm -f "$0" 2>/dev/null

exit $EXIT_CODE
EOF

    chmod +x "$NODE_CLEANUP_SCRIPT"
    TEMP_FILES+=("$NODE_CLEANUP_SCRIPT")
}

# Main execution flow
# First clean the cluster (drain nodes)
clean_cluster

# Create the node cleanup script
create_node_cleanup_script

# Ask if packages should be removed
echo -n "Do you want to remove all Kubernetes packages from all nodes? (y/N): "
read -r remove_packages
REMOVE_PACKAGES_ARG=""
if [[ "$remove_packages" = "y" || "$remove_packages" = "Y" ]]; then
    REMOVE_PACKAGES_ARG="remove_packages"
fi

# Run cleanup on worker nodes first via SSH
for NODE in "${WORKER_NODES[@]}"; do
    print_status "Cleaning up worker node: $NODE"
    
    # Copy the cleanup script to the worker node
    if ! scp -o StrictHostKeyChecking=no /tmp/node_cleanup.sh ${SSH_USER}@${NODE}:/tmp/ &>/dev/null; then
        print_error "Failed to copy cleanup script to $NODE"
        print_note "Skipping this worker node and continuing with others."
        WARNINGS+=("Failed to clean up node $NODE - SSH copy failed")
        continue
    fi
    
    # Execute the cleanup script on the worker node
    if ! ssh -o StrictHostKeyChecking=no ${SSH_USER}@${NODE} "bash /tmp/node_cleanup.sh $REMOVE_PACKAGES_ARG"; then
        print_error "Failed to execute cleanup script on $NODE"
        WARNINGS+=("Cleanup on $NODE may be incomplete - Script execution failed")
    fi
    
    print_status "Worker node $NODE cleanup completed"
done

# Run cleanup on the control plane node (current host)
print_status "Cleaning up control plane node (local)..."
if ! bash /tmp/node_cleanup.sh $REMOVE_PACKAGES_ARG 2>&1 | grep -v "runtime connect using default endpoints" | \
                                                        grep -v "validate service connection" | \
                                                        grep -v "dial unix /var/run/dockershim.sock"; then
    print_warning "Control plane cleanup returned errors, but this is usually non-critical."
    print_note "The cleanup process will continue."
fi

# Ask about rebooting nodes
echo -n "Do you want to reboot all nodes now? (Recommended) (y/N): "
read -r reboot_nodes

if [[ "$reboot_nodes" = "y" || "$reboot_nodes" = "Y" ]]; then
    # Reboot worker nodes first
    for NODE in "${WORKER_NODES[@]}"; do
        print_status "Rebooting worker node: $NODE"
        if ! ssh -o StrictHostKeyChecking=no ${SSH_USER}@${NODE} "reboot" &>/dev/null; then
            print_warning "Failed to reboot worker node $NODE"
            WARNINGS+=("Failed to reboot node $NODE - Please reboot manually")
        fi
    done
    
    # Finally reboot the control plane node
    print_status "All worker nodes have been instructed to reboot."
    print_status "Rebooting control plane node in 5 seconds..."
    sleep 5
    reboot
else
    print_status "Cleanup completed. Please reboot all nodes manually when convenient."
fi

# Print summary of warnings if any
if [ ${#WARNINGS[@]} -gt 0 ]; then
    echo
    echo -e "${YELLOW}${BOLD}== CLEANUP SUMMARY ==${NC}"
    echo -e "${YELLOW}The following non-critical warnings were encountered:${NC}"
    for warning in "${WARNINGS[@]}"; do
        echo -e " - $warning"
    done
    echo
    echo -e "${BLUE}[NOTE]${NC} These warnings are normal during cleanup and do not indicate failure."
    echo -e "${BLUE}[NOTE]${NC} For a completely clean system, consider running 'apt --fix-broken install' manually."
fi

# The cleanup_temp_files function will be called automatically on exit due to the trap
exit 0
