# Cleaning Up Kubernetes Before Fresh Installation

This document outlines the steps to completely clean up an existing Kubernetes cluster before performing a fresh installation. These steps ensure all components are properly removed to prevent conflicts with the new installation. Useful for scenarios where you need to reset a previous cluster setup to start from scratch while learning phases.

Find the automation script for this process in scripts at:
[`0399-Chapter_3-Addendum-Cleaning_Up_Kubernetes_Before_Fresh_Installation.sh`](./resources/scripts/0399-Chapter_3-Addendum-Cleaning_Up_Kubernetes_Before_Fresh_Installation.sh)
<br>
*Note: Make sure you read the important notes below and the documentation inside the script before executing it.*

## Important Notes

- This cleanup process is destructive and will remove all Kubernetes data
- Always backup any important data before running this cleanup
- If you're using custom storage or networking solutions, you may need additional cleanup steps
- Some cloud provider-specific configurations may require additional cleanup

---

## Introduction

Before installing a new Kubernetes cluster, it's often necessary to completely remove any existing Kubernetes components to ensure a clean installation. This guide provides a step-by-step approach to cleaning up an existing Kubernetes installation across all nodes in your cluster.

## When to Use This Guide

Use this cleanup procedure in the following situations:
- When you want to completely start over with a fresh Kubernetes installation
- When your existing Kubernetes installation is corrupted or in an inconsistent state
- When switching between different Kubernetes distributions
- When upgrading from an older Kubernetes version and want a clean slate

## Prerequisites

- Root access to all nodes in your cluster
- SSH access from the control plane node to all worker nodes
- Basic knowledge of Linux command line operations

## Understanding the Cleanup Process

The cleanup process involves these key steps:
1. Properly draining and removing nodes from the cluster
2. Resetting Kubernetes components using `kubeadm reset`
3. Cleaning up network configurations, and CNI configurations
4. Removing Kubernetes directories and configuration files
5. Optionally removing Kubernetes packages
6. Rebooting all nodes to ensure a clean state

## Manual Cleanup Process

### Step 1: Drain and Remove Worker Nodes

On the control plane node (master), perform these steps to properly remove worker nodes from the cluster:

```bash
# List all nodes in the cluster
kubectl get nodes

# For each worker node in the cluster, run:
kubectl drain <node-name> --delete-emptydir-data --force --ignore-daemonsets

# Then delete each node from the cluster
kubectl delete node <node-name>
```

This process ensures that:
- Pods are safely evicted from the node
- The node is marked as unschedulable
- The node is cleanly removed from the cluster

### Step 2: Reset Kubernetes on All Nodes

On **each node** (control plane and all workers), run the kubeadm reset command to clean up Kubernetes components:

```bash
# Reset the Kubernetes installation
sudo kubeadm reset -f
```

This command:
- Stops and removes Kubernetes containers
- Removes most of the Kubernetes-related directories
- Resets the state of the kubelet service
- Removes cluster certificates

### Step 3: Clean Up Network Configuration

On **each node**, clean up network configurations that kubeadm doesn't handle:

```bash
# Remove CNI configurations
sudo rm -rf /etc/cni/net.d/*

# If your cluster used IPVS, clean it up too
sudo ipvsadm -C || true
```

These commands:
- Remove all CNI (Container Network Interface) configurations
- Clear IPVS tables if they were used

### Step 4: Clean Up Kubernetes Configuration Files

On **each node**, remove configuration files and directories:

```bash
# Remove kubelet configuration
sudo rm -rf /etc/kubernetes/kubelet.conf
sudo rm -rf /etc/kubernetes/bootstrap-kubelet.conf
sudo rm -rf /etc/kubernetes/admin.conf
sudo rm -rf /etc/kubernetes/pki

# Remove kubeconfig files
sudo rm -rf $HOME/.kube/config

# Stop and disable kubelet service
sudo systemctl stop kubelet
sudo systemctl disable kubelet

# Remove Kubernetes directories
sudo rm -rf /var/lib/kubelet
sudo rm -rf /var/lib/etcd
sudo rm -rf /var/lib/cni
```

These steps ensure that:
- All Kubernetes configuration files are removed
- Certificate authority files are removed
- The kubelet service is stopped
- Data directories used by Kubernetes are cleaned up

### Step 5: Optionally Remove Kubernetes Packages

If you want to completely remove all Kubernetes packages:

```bash
# Remove Kubernetes packages
sudo apt-get purge -y kubeadm kubectl kubelet kubernetes-cni

# Remove any dependencies that are no longer needed
sudo apt-get autoremove -y
```

This completely removes:
- The kubeadm tool
- The kubectl command-line utility
- The kubelet service
- Kubernetes CNI plugins

### Step 6: Reboot All Nodes

To ensure all changes take effect, reboot each node:

```bash
sudo reboot
```

Rebooting ensures that:
- All services are restarted with clean configurations
- Any in-memory state is cleared
- Kernel modules are reloaded

## Automated Cleanup Script

For convenience, we've created a script that automates the manual process described above. The script should be run from the control plane node and will handle cleaning up the entire cluster.

### Script Usage

TODO: mention script from resources, fix content below

1. Copy the script below to your control plane node
2. Edit the `WORKER_NODES` array to include your worker node IPs
3. Make the script executable: `chmod +x kubernetes-cleanup.sh`
4. Run the script as root: `sudo ./kubernetes-cleanup.sh`

The script automates all the steps described in the manual process above and includes:
- Warning and confirmation prompts to prevent accidental execution
- SSH connectivity checks to worker nodes
- Proper draining of nodes before removal
- Detailed cleanup on all nodes
- Removal of temporary files
- Options to remove packages and reboot nodes

## How the Script Works

TODO: validate the need of this section

The script performs these operations:
1. Asks for confirmation before proceeding with the destructive cleanup
2. Checks SSH connectivity to all worker nodes
3. Uses `kubectl` to properly drain and remove worker nodes
4. Creates a node cleanup script that implements the manual cleanup steps
5. Copies and executes the cleanup script on all worker nodes via SSH
6. Executes the same cleanup on the control plane node
7. Optionally reboots all nodes
8. Cleans up all temporary files

## Verifying the Cleanup

After completing the cleanup and rebooting, verify that Kubernetes has been fully removed:

```bash
# These commands should return "command not found" or similar
kubectl get nodes
kubeadm version

# Check that no Kubernetes processes are running
ps aux | grep kube
```

## Common Issues and Troubleshooting

### SSH Connectivity Issues

If the script fails to connect to worker nodes:
- Verify SSH keys are properly set up
- Check that the worker node IPs are correct
- Ensure the SSH user has sufficient permissions

### kubeadm Reset Failures

If `kubeadm reset` fails:
- Try running it with `--force` flag
- Manually stop Kubernetes services: `systemctl stop kubelet`
- Check for stuck processes: `ps aux | grep kube`

### Network Cleanup Issues

If you encounter network-related issues after cleanup:
- Check for lingering CNI configurations
- Verify network interface configurations

### Docker/Containerd Cleanup Issues

If container runtime cleanup fails:
- Manually stop Docker/Containerd: `systemctl stop docker containerd`
- Remove containers manually: `docker rm -f $(docker ps -aq)`
- Check for lingering socket files or configuration

## Next Steps

After completing the cleanup process, your systems should be ready for a fresh Kubernetes installation.
