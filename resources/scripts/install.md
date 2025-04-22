# Kubernetes Multi-Cloud Cluster Scripts - Version Information

## Script Version Details
- **Version:** 1.0.0
- **Last Updated:** 2025-04-20
- **Compatible With:** Kubernetes v1.32.3

## Overview
These scripts are designed to work together to create and manage a multi-cloud Kubernetes cluster with the following features:

- Control plane and worker nodes across different clouds/providers
- Flannel CNI for cross-cloud pod networking
- Node-specific network interface configuration
- Automated Pod CIDR management

## Script Execution Order

### Chapter 1: Environment Configuration
- `001-Environment_Config.sh` - Source of truth for all settings
- `002-Add_New_Node_Configuration.sh` - Helper to add new nodes

### Chapter 2: Environment Preparation
- `001-Environment_Verification.sh` - Check all nodes meet requirements
- `002-Install_Dependencies.sh` - Install required packages
- `003-Disable_Swap.sh` - Disable swap on all nodes

### Chapter 3: Kubernetes Installation
- `001-Add_Kubernetes_Repos.sh` - Add K8s repositories
- `002-Enable_Required_Modules.sh` - Enable kernel modules
- `003-Initialize_the_Control_Plane_Node.sh` - Set up control plane
- `004-Join_Worker_Nodes.sh` - Join worker nodes to cluster

### Chapter 4: Networking with CNI
- `001-CNI_Setup.sh` - Configure Flannel CNI networking

### Chapter 10: Troubleshooting
- `001-Fix_Common_Issues.sh` - Fix common cluster issues
- `002-Network_Connectivity_Test.sh` - Test cluster networking

---

For documentation and the latest updates, refer to the guide at:
`0010-Kubernetes_Multi-Cloud_Cluster_Guide.md`
