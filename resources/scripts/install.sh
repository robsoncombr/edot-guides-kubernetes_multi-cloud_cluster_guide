#!/bin/bash

# ============================================================================
# install.sh - Master Installation Script for Kubernetes Multi-Cloud Cluster
# ============================================================================
# 
# DESCRIPTION:
#   This script provides a guided installation process for setting up a 
#   Kubernetes multi-cloud cluster by invoking all necessary scripts in
#   the correct order with appropriate user interaction.
#
# USAGE:
#   ./install.sh [--auto] [--control-plane|--worker|--all]
#
# OPTIONS:
#   --auto            Run in automated mode with minimal prompts
#   --control-plane   Install only control plane components
#   --worker          Install only worker node components
#   --all             Install complete cluster (default)
#
# ============================================================================

set -e

# Script base directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Extract version information from install.md
if [ -f "${SCRIPT_DIR}/install.md" ]; then
    SCRIPT_VERSION=$(grep -A 10 "Script Version Details" "${SCRIPT_DIR}/install.md" | grep -i "Version:" | head -n 1 | sed -E 's/.*\*\*Version:\*\* ([0-9]+\.[0-9]+\.[0-9]+).*/\1/' | xargs)
    LAST_UPDATED=$(grep -A 10 "Script Version Details" "${SCRIPT_DIR}/install.md" | grep -i "Last Updated:" | head -n 1 | sed -E 's/.*\*\*Last Updated:\*\* ([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1/' | xargs)
    COMPATIBLE_K8S=$(grep -A 10 "Script Version Details" "${SCRIPT_DIR}/install.md" | grep -i "Compatible With:" | head -n 1 | sed -E 's/.*\*\*Compatible With:\*\* (Kubernetes v[0-9]+\.[0-9]+\.[0-9]+).*/\1/' | xargs)
    
    if [ -z "$SCRIPT_VERSION" ]; then
        SCRIPT_VERSION="1.0.0"  # Default version if not found
    fi
else
    echo "Warning: install.md not found, using default version"
    SCRIPT_VERSION="1.0.0"  # Default version
    LAST_UPDATED="Unknown"
    COMPATIBLE_K8S="Unknown"
fi

# Show version information
echo "Script version: $SCRIPT_VERSION (Updated: $LAST_UPDATED, Compatible with: $COMPATIBLE_K8S)"

# Parse arguments
AUTO_MODE=false
INSTALL_MODE="all"

for arg in "$@"; do
    case $arg in
        --auto)
            AUTO_MODE=true
            shift
            ;;
        --control-plane)
            INSTALL_MODE="control-plane"
            shift
            ;;
        --worker)
            INSTALL_MODE="worker"
            shift
            ;;
        --all)
            INSTALL_MODE="all"
            shift
            ;;
        *)
            echo "Unknown argument: $arg"
            echo "Usage: $0 [--auto] [--control-plane|--worker|--all]"
            exit 1
            ;;
    esac
done

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# Print banner
clear
echo "======================================================================"
echo "                 KUBERNETES MULTI-CLOUD CLUSTER SETUP                  "
echo "                        Version: $SCRIPT_VERSION                       "
echo "======================================================================"
echo ""
echo "This installer will guide you through setting up a Kubernetes cluster"
echo "across multiple cloud environments with proper networking configuration."
echo ""
echo "Installation mode: $INSTALL_MODE"
echo "Auto mode: $(if $AUTO_MODE; then echo "Enabled"; else echo "Disabled"; fi)"
echo ""

# Confirm before proceeding
if [[ "$AUTO_MODE" != "true" ]]; then
    read -p "Do you want to proceed with the installation? (y/n): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Installation cancelled."
        exit 0
    fi
fi

# Function to run a script and check its exit status
run_script() {
    local script="$1"
    local description="$2"
    local required="$3"
    local script_path="${SCRIPT_DIR}/${script}"
    
    echo "======================================================================"
    echo "STEP: $description"
    echo "======================================================================"
    
    # Check for alternate script name formats (hyphen vs underscore)
    if [[ ! -f "$script_path" ]]; then
        # Try alternate naming format
        local alt_script_path="${script_path//-/_}"
        if [[ -f "$alt_script_path" ]]; then
            script_path="$alt_script_path"
        else
            alt_script_path="${script_path//_/-}"
            if [[ -f "$alt_script_path" ]]; then
                script_path="$alt_script_path"
            else
                echo "Error: Script not found: $script_path"
                echo "Also tried: ${script_path//-/_}"
                echo "And: ${script_path//_/-}"
                if [[ "$required" == "required" ]]; then
                    echo "This is a required script. Cannot continue."
                    exit 1
                else
                    echo "This is an optional script. Continuing without it."
                    return 0
                fi
            fi
        fi
    fi
    
    if [[ "$AUTO_MODE" != "true" ]]; then
        read -p "Execute this step? (y/n/s): " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Ss]$ ]]; then
            echo "Step skipped."
            return 0
        elif [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Installation stopped by user."
            exit 0
        fi
    fi
    
    echo "Executing $script_path..."
    chmod +x "$script_path"
    "$script_path"
    
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "Error: Script $script failed with exit code $exit_code"
        if [[ "$required" == "required" ]]; then
            echo "This is a required script. Cannot continue."
            exit $exit_code
        else
            echo "This is an optional script. Continuing despite the error."
        fi
    else
        echo "Script $script completed successfully."
    fi
    
    # Special verification for specific scripts
    if [[ "$script" == "0600-Chapter_6-Storage_Configuration/001-Configure_Default_local-storage.sh" ]]; then
        verify_local_storage_configuration
    fi
    
    echo ""
    if [[ "$AUTO_MODE" != "true" ]]; then
        read -p "Press Enter to continue..."
    fi
}

# Function to verify local storage configuration
verify_local_storage_configuration() {
    echo "Verifying local storage configuration..."
    
    # Check if we have kubectl available (control plane node)
    if command -v kubectl &> /dev/null; then
        # Check if the local-storage StorageClass exists
        if kubectl get storageclass local-storage &> /dev/null; then
            echo "✅ Local storage configuration verified: StorageClass 'local-storage' exists"
            
            # Check if PersistentVolumes were created
            local pv_count=$(kubectl get pv --selector=storage.kubernetes.io/local-volume -o name | wc -l)
            if [ "$pv_count" -gt 0 ]; then
                echo "✅ Found $pv_count local PersistentVolumes configured"
            else
                echo "⚠️ No local PersistentVolumes found. This might be expected if no volumes were configured."
            fi
            
            # Check if the local-path-provisioner deployment exists (if using that approach)
            if kubectl get deployment -n kube-system local-path-provisioner &> /dev/null; then
                echo "✅ Local Path Provisioner is deployed and running"
                
                # Check if pods are running
                local pod_status=$(kubectl get pods -n kube-system -l app=local-path-provisioner -o jsonpath='{.items[0].status.phase}')
                echo "   Pod status: $pod_status"
            fi
        else
            echo "❌ Local storage configuration could not be verified: StorageClass 'local-storage' not found"
            echo "   If you skipped the storage configuration or it failed, this is expected."
        fi
    else
        echo "ℹ️ Cannot verify local storage configuration on this node: kubectl not available"
        echo "   Please check on the control plane node with: kubectl get storageclass local-storage"
    fi
}

# Detect current hostname to determine node type
CURRENT_HOSTNAME=$(hostname)

# Source environment config to get node details
source "${SCRIPT_DIR}/0100-Chapter_1/001-Environment_Config.sh" > /dev/null 2>&1 || {
    echo "Error: Environment configuration not found or contains errors"
    exit 1
}

# Try to determine if this is a control plane or worker node based on environment config
IS_CONTROL_PLANE=false
IS_WORKER=false

for NODE_CONFIG in "${ALL_NODES[@]}"; do
    NODE_NAME=$(get_node_property "$NODE_CONFIG" 0)
    NODE_ROLE=$(get_node_property "$NODE_CONFIG" 4)
    
    if [[ "$NODE_NAME" == "$CURRENT_HOSTNAME" ]]; then
        if [[ "$NODE_ROLE" == "control-plane" ]]; then
            IS_CONTROL_PLANE=true
        else
            IS_WORKER=true
        fi
        break
    fi
done

echo "Detected node type:"
if [[ "$IS_CONTROL_PLANE" == "true" ]]; then
    echo "- This appears to be a control plane node"
elif [[ "$IS_WORKER" == "true" ]]; then
    echo "- This appears to be a worker node"
else
    echo "- Unable to determine node type from environment config"
    echo "  Make sure this node is properly configured in the environment config"
    
    # If in auto mode, exit; otherwise ask for user input
    if [[ "$AUTO_MODE" == "true" ]]; then
        exit 1
    else
        echo ""
        echo "Please select node type for installation:"
        echo "1. Control Plane Node"
        echo "2. Worker Node"
        read -p "Enter your choice (1 or 2): " node_choice
        
        case $node_choice in
            1)
                IS_CONTROL_PLANE=true
                ;;
            2)
                IS_WORKER=true
                ;;
            *)
                echo "Invalid choice. Exiting."
                exit 1
                ;;
        esac
    fi
fi

# Installation for all modes
echo ""
echo "======================================================================"
echo "Starting Installation Process"
echo "======================================================================"
echo ""

# Chapter 1: Environment Configuration
echo "Chapter 1: Environment Configuration"
run_script "0100-Chapter_1/001-Environment_Config.sh" "Setting up environment configuration" "required"

# Chapter 2: Environment Preparation (all nodes)
echo "Chapter 2: Environment Preparation"
run_script "0200-Chapter_2/001-Environment_Verification.sh" "Verifying environment requirements" "required"
run_script "0200-Chapter_2/002-Install-Dependencies.sh" "Installing required dependencies" "required"
run_script "0200-Chapter_2/003-Disable-Swap.sh" "Disabling swap (required for Kubernetes)" "required"

# Double-check swap is still disabled after Chapter 2
echo "Double-checking swap is still disabled..."
SWAP_STATUS=$(free | grep -i swap | awk '{print $2}')
if [ "$SWAP_STATUS" != "0" ]; then
    echo "Warning: Swap still appears to be enabled ($SWAP_STATUS). Attempting more aggressive disabling..."
    swapoff -a
    mount | grep -i swap | awk '{print $1}' | xargs -r swapoff
    sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab
    
    # Check again with the same method
    SWAP_STATUS=$(free | grep -i swap | awk '{print $2}')
    if [ "$SWAP_STATUS" != "0" ]; then
        echo "Error: Failed to disable swap after multiple attempts. Installation may fail."
        echo "Consider running: swapoff -a && sed -i '/swap/s/^\(.*\)$/#\1/g' /etc/fstab"
        echo "Then reboot the system before continuing."
        
        if [[ "$AUTO_MODE" != "true" ]]; then
            read -p "Continue anyway? (y/n): " -n 1 -r
            echo ""
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo "Installation cancelled."
                exit 1
            fi
        else
            echo "Auto mode: continuing despite swap issue."
        fi
    else
        echo "Swap successfully disabled."
    fi
else
    echo "Swap is disabled (value: $SWAP_STATUS). Proceeding with installation."
fi

# Chapter 3: Kubernetes Installation
echo "Chapter 3: Kubernetes Installation"
run_script "0300-Chapter_3/001-Add_Kubernetes_Repositories_and_Install.sh" "Adding Kubernetes repositories and installing components" "required"
run_script "0300-Chapter_3/002-Enable_Required_Kernel_Modules_and_System_Settings.sh" "Enabling required kernel modules" "required"

# Install control plane if this is a control plane node or selected mode
if [[ "$IS_CONTROL_PLANE" == "true" || "$INSTALL_MODE" == "control-plane" || "$INSTALL_MODE" == "all" ]]; then
    echo "Installing Control Plane Components"
    
    run_script "0300-Chapter_3/003-Initialize_the_Control_Plane_Node.sh" "Initializing Kubernetes control plane" "required"
    
    # Ask if user wants to setup CNI with Flannel
    CNI_SKIPPED=false
    if run_script "0400-Chapter_4/001-CNI_Setup.sh" "Setting up Flannel CNI networking" "optional"; then 
        # If we get here, the script either completed successfully or was skipped
        if [[ "$REPLY" =~ ^[Ss]$ ]]; then
            CNI_SKIPPED=true
            echo "CNI setup was skipped. Network plugins will need to be installed manually."
        fi
    else
        CNI_SKIPPED=true
        echo "CNI setup failed. Network plugins will need to be fixed manually."
    fi
    
    # If in all mode, join worker nodes from control plane
    if [[ "$INSTALL_MODE" == "all" ]]; then
        # Print a note about automatic Pod CIDR assignment
        echo "Note: Worker nodes will join with automatic Pod CIDR assignment"
        
        # Only apply CNI fixes if CNI wasn't skipped
        JOIN_WORKER_SKIPPED=false
        if [[ "$CNI_SKIPPED" == "false" ]]; then
            echo "======================================================================"
            echo "Applying pre-join CNI fixes to ensure proper network initialization..."
            echo "======================================================================"
            
            # Create the /etc/cni/net.d directory if it doesn't exist
            mkdir -p /etc/cni/net.d
            
            # Create the flannel CNI configuration directly
            cat > /etc/cni/net.d/10-flannel.conflist << EOF
{
  "name": "cbr0",
  "cniVersion": "0.3.1",
  "plugins": [
    {
      "type": "flannel",
      "delegate": {
        "hairpinMode": true,
        "isDefaultGateway": true
      }
    },
    {
      "type": "portmap",
      "capabilities": {
        "portMappings": true
      }
    }
  ]
}
EOF
            
            # Create /run/flannel directory if it doesn't exist
            mkdir -p /run/flannel
            
            # Create subnet.env file with appropriate configuration
            # Extract the POD_CIDR prefix from environment config
            POD_CIDR_PREFIX=$(echo "$POD_CIDR" | cut -d '.' -f 1-2)
            NODE_INTERFACE=$(get_current_node_property "interface")
            HOSTNAME=$(get_current_hostname)
            
            # Get node CIDR or default to a value based on hostname number
            NODE_CIDR=$(kubectl get node $HOSTNAME -o jsonpath='{.spec.podCIDR}' 2>/dev/null)
            if [ -z "$NODE_CIDR" ]; then
                NODE_NUM=$(echo "$HOSTNAME" | grep -oE '[0-9]+$' || echo "0")
                NODE_CIDR="${POD_CIDR_PREFIX}.${NODE_NUM}.0/24"
            fi
            
            # Create the subnet.env file
            cat > /run/flannel/subnet.env << EOF
FLANNEL_NETWORK=${POD_CIDR}
FLANNEL_SUBNET=${NODE_CIDR}
FLANNEL_MTU=1450
FLANNEL_IPMASQ=true
FLANNEL_IFACE=${NODE_INTERFACE}
EOF
            
            # Restart containerd and kubelet to pick up the new CNI configuration
            systemctl restart containerd
            sleep 3
            systemctl restart kubelet
            sleep 5
            
            echo "CNI fixes applied. Proceeding with worker node join..."
        else
            echo "Skipping CNI fixes as Flannel CNI setup was skipped."
        fi
        
        # Ask to join worker nodes 
        if run_script "0300-Chapter_3/004-Join_Worker_Nodes.sh" "Joining worker nodes to the cluster" "optional"; then
            # If we get here, the script either completed successfully or was skipped
            if [[ "$REPLY" =~ ^[Ss]$ ]]; then
                JOIN_WORKER_SKIPPED=true
                echo "Worker node joining was skipped."
            fi
        else
            JOIN_WORKER_SKIPPED=true
            echo "Worker node joining failed."
        fi
        
        # Only check CNI initialization if Flannel wasn't skipped and workers were joined
        if [[ "$CNI_SKIPPED" == "false" && "$JOIN_WORKER_SKIPPED" == "false" ]]; then
            echo "Ensuring CNI is properly initialized across all nodes before continuing..."
            
            # Check if we need to run a detailed troubleshooting step
            NODE_STATUSES=$(kubectl get nodes --no-headers | grep -v "Ready" 2>/dev/null)
            if [[ -n "$NODE_STATUSES" ]]; then
                echo "Some nodes are not in Ready state. Running CNI troubleshooting..."
                run_script "0400-Chapter_4/003-CNI_Troubleshooting.sh" "Troubleshooting and fixing CNI issues" "optional"
                
                # Wait a bit for any fixes to take effect
                echo "Waiting for CNI fixes to propagate..."
                sleep 30
            fi
        else
            echo "Skipping CNI initialization check as either Flannel or worker joining was skipped."
        fi
        
        # Configure DNS for the cluster
        echo "Configuring DNS for the cluster..."
        run_script "0400-Chapter_4/002-DNS_Setup.sh" "Setting up CoreDNS for multi-cloud configuration" "required"

        # Configure local storage for all nodes
        echo "Setting up local storage configuration..."
        run_script "0600-Chapter_6-Storage_Configuration/001-Configure_Default_local-storage.sh" "Setting up default local storage on all nodes" "optional"
    fi
    
    echo ""
    echo "Control plane setup completed!"
    echo ""
    echo "You can check the status of your nodes with:"
    echo "  kubectl get nodes -o wide"
    echo ""
    echo "And the status of pods with:"
    echo "  kubectl get pods --all-namespaces"
fi

# Install worker components if this is a worker node or selected mode
if [[ "$IS_WORKER" == "true" || "$INSTALL_MODE" == "worker" ]]; then
    echo "Installing Worker Node Components"
    
    # When running on a worker node directly, there's no automatic join
    # Instead, we provide instructions to get the join command from the control plane
    echo ""
    echo "To join this worker node to the cluster, you need to:"
    echo ""
    echo "1. On the control plane node, run:"
    echo "   kubeadm token create --print-join-command"
    echo ""
    echo "2. Take the output from that command and run it on this worker node (as root)"
    echo ""
    echo "3. The Pod CIDR will be automatically assigned by Kubernetes"
    echo ""
    
    if [[ "$AUTO_MODE" != "true" ]]; then
        read -p "Have you run the join command on this worker node? (y/n): " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo ""
            echo "Worker node setup completed!"
            echo ""
            echo "You can check the status of your node on the control plane with:"
            echo "  kubectl get nodes -o wide"
        else
            echo "Please join the worker node to the cluster first."
        fi
    fi
fi

# Final verification and troubleshooting
echo ""
echo "======================================================================"
echo "Installation Complete"
echo "======================================================================"
echo ""
echo "If you encounter any issues, use the troubleshooting scripts:"
echo "  ${SCRIPT_DIR}/1000-Troubleshooting/001-Fix_Common_Issues.sh"
echo "  ${SCRIPT_DIR}/1000-Troubleshooting/002-Network_Connectivity_Test.sh"
echo ""
