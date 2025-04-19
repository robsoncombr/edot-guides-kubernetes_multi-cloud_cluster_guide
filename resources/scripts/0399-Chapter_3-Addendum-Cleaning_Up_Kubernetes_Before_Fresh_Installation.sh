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

# Text colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Function to print status messages
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
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
echo -e "Are you absolutely sure you want to proceed? (y/N): "
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
        print_warning "No kubeconfig found. Skipping cluster node cleanup."
        return
    fi
    
    # Try to get nodes - if this fails, the cluster may not be accessible
    if ! kubectl get nodes &> /dev/null; then
        print_warning "Unable to access the Kubernetes API. Cluster may be down or unreachable."
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
            kubectl drain "$NODE" --delete-emptydir-data --force --ignore-daemonsets || print_warning "Failed to drain $NODE"
            
            print_status "Removing node: $NODE from cluster"
            kubectl delete node "$NODE" || print_warning "Failed to delete $NODE"
        done
        
        # If this is the control plane, drain it last
        if [ -n "$CONTROL_PLANE" ]; then
            print_status "Draining control plane node: $CONTROL_PLANE"
            kubectl drain "$CONTROL_PLANE" --delete-emptydir-data --force --ignore-daemonsets || print_warning "Failed to drain $CONTROL_PLANE"
        fi
    else
        print_warning "No nodes found in the cluster or unable to retrieve node information"
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
NC='\033[0m' # No Color

echo -e "${GREEN}[INFO]${NC} Starting node cleanup on $(hostname)"

# Reset kubeadm
echo -e "${GREEN}[INFO]${NC} Resetting kubeadm..."
kubeadm reset -f || echo -e "${YELLOW}[WARNING]${NC} kubeadm reset failed, continuing anyway"

# Clean up CNI configurations
echo -e "${GREEN}[INFO]${NC} Removing CNI configurations..."
rm -rf /etc/cni/net.d/* 2>/dev/null || echo -e "${YELLOW}[WARNING]${NC} Failed to remove CNI configurations"

# Clean up IPVS tables if installed
if command -v ipvsadm &> /dev/null; then
    echo -e "${GREEN}[INFO]${NC} Clearing IPVS tables..."
    ipvsadm -C 2>/dev/null || echo -e "${YELLOW}[WARNING]${NC} Failed to clear IPVS tables"
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
systemctl stop kubelet 2>/dev/null || echo -e "${YELLOW}[WARNING]${NC} Failed to stop kubelet"
systemctl disable kubelet 2>/dev/null || echo -e "${YELLOW}[WARNING]${NC} Failed to disable kubelet"

# Clean up docker containers if docker is installed
if command -v docker &> /dev/null; then
    echo -e "${GREEN}[INFO]${NC} Cleaning up Docker..."
    docker rm -f $(docker ps -aq) 2>/dev/null || echo -e "${YELLOW}[WARNING]${NC} No containers to remove or Docker not running"
    docker system prune -af --volumes 2>/dev/null || echo -e "${YELLOW}[WARNING]${NC} Failed to prune Docker system"
fi

# Clean up containerd if installed
if command -v crictl &> /dev/null; then
    echo -e "${GREEN}[INFO]${NC} Cleaning up containerd..."
    crictl rm $(crictl ps -aq) 2>/dev/null || echo -e "${YELLOW}[WARNING]${NC} No containerd containers to remove"
fi

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
    apt-get purge -y kubeadm kubectl kubelet kubernetes-cni 2>/dev/null || echo -e "${YELLOW}[WARNING]${NC} Failed to remove some packages"
    apt-get autoremove -y 2>/dev/null
    echo -e "${GREEN}[INFO]${NC} All Kubernetes packages have been removed."
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
print_status "Do you want to remove all Kubernetes packages from all nodes? (y/n)"
read -r remove_packages
REMOVE_PACKAGES_ARG=""
if [ "$remove_packages" = "y" ] || [ "$remove_packages" = "Y" ]; then
    REMOVE_PACKAGES_ARG="remove_packages"
fi

# Run cleanup on worker nodes first via SSH
for NODE in "${WORKER_NODES[@]}"; do
    print_status "Cleaning up worker node: $NODE"
    
    # Copy the cleanup script to the worker node
    scp -o StrictHostKeyChecking=no /tmp/node_cleanup.sh ${SSH_USER}@${NODE}:/tmp/ &>/dev/null || {
        print_error "Failed to copy cleanup script to $NODE"
        continue
    }
    
    # Execute the cleanup script on the worker node
    ssh -o StrictHostKeyChecking=no ${SSH_USER}@${NODE} "bash /tmp/node_cleanup.sh $REMOVE_PACKAGES_ARG" || {
        print_error "Failed to execute cleanup script on $NODE"
    }
    
    print_status "Worker node $NODE cleanup completed"
}

# Run cleanup on the control plane node (current host)
print_status "Cleaning up control plane node (local)..."
bash /tmp/node_cleanup.sh $REMOVE_PACKAGES_ARG

# Ask about rebooting nodes
print_status "Do you want to reboot all nodes now? (Recommended) (y/n)"
read -r reboot_nodes

if [ "$reboot_nodes" = "y" ] || [ "$reboot_nodes" = "Y" ]; then
    # Reboot worker nodes first
    for NODE in "${WORKER_NODES[@]}"; do
        print_status "Rebooting worker node: $NODE"
        ssh -o StrictHostKeyChecking=no ${SSH_USER}@${NODE} "reboot" &>/dev/null || {
            print_error "Failed to reboot worker node $NODE"
        }
    done
    
    # Finally reboot the control plane node
    print_status "All worker nodes have been instructed to reboot."
    print_status "Rebooting control plane node in 5 seconds..."
    sleep 5
    reboot
else
    print_status "Cleanup completed. Please reboot all nodes manually when convenient."
fi

# The cleanup_temp_files function will be called automatically on exit due to the trap
exit 0
