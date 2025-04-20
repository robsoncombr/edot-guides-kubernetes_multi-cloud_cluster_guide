#!/bin/bash

# ============================================================================
# 0000-Version_Info.sh - Script Version Information
# ============================================================================
# 
# DESCRIPTION:
#   This script provides version information for the Kubernetes multi-cloud
#   cluster setup scripts. It helps ensure version compatibility and allows
#   tracking of changes across script versions.
#
# USAGE:
#   ./0000-Version_Info.sh
#
# ============================================================================

# Script suite version
SCRIPT_VERSION="1.0.0"
SCRIPT_LAST_UPDATED="2025-04-20"
SCRIPT_COMPATIBILITY="Kubernetes v1.32.3"

echo "======================================================================"
echo "Kubernetes Multi-Cloud Cluster Scripts - Version Information"
echo "======================================================================"
echo "Version:        $SCRIPT_VERSION"
echo "Last Updated:   $SCRIPT_LAST_UPDATED"
echo "Compatible With:$SCRIPT_COMPATIBILITY"
echo ""
echo "These scripts are designed to work together to create and manage a"
echo "multi-cloud Kubernetes cluster with the following features:"
echo ""
echo "- Control plane and worker nodes across different clouds/providers"
echo "- Flannel CNI for cross-cloud pod networking"
echo "- Node-specific network interface configuration"
echo "- Automated Pod CIDR management"
echo ""
echo "SCRIPT EXECUTION ORDER:"
echo "----------------------"
echo "Chapter 1: Environment Configuration"
echo "  - 001-Environment_Config.sh       # Source of truth for all settings"
echo "  - 002-Add_New_Node_Configuration.sh # Helper to add new nodes"
echo ""
echo "Chapter 2: Environment Preparation"
echo "  - 001-Environment_Verification.sh # Check all nodes meet requirements"
echo "  - 002-Install_Dependencies.sh     # Install required packages"
echo "  - 003-Disable_Swap.sh             # Disable swap on all nodes"
echo ""
echo "Chapter 3: Kubernetes Installation"
echo "  - 001-Add_Kubernetes_Repos.sh     # Add K8s repositories"
echo "  - 002-Enable_Required_Modules.sh  # Enable kernel modules"
echo "  - 003-Initialize_the_Control_Plane_Node.sh # Set up control plane"
echo "  - 004-Join_Worker_Nodes.sh        # Join worker nodes to cluster"
echo ""
echo "Chapter 4: Networking with CNI"
echo "  - 001-CNI_Setup.sh                # Configure Flannel CNI networking"
echo ""
echo "Chapter 10: Troubleshooting"
echo "  - 001-Fix_Common_Issues.sh        # Fix common cluster issues"
echo "  - 002-Network_Connectivity_Test.sh # Test cluster networking"
echo "======================================================================"
echo ""
echo "For documentation and the latest updates, refer to the guide at:"
echo "  0010-Kubernetes_Multi-Cloud_Cluster_Guide.md"
echo ""
