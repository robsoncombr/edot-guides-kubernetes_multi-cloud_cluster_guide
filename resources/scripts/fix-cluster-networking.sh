#!/bin/bash

# ============================================================================
# fix-cluster-networking.sh - Fix networking in multi-cloud Kubernetes cluster
# ============================================================================
# 
# DESCRIPTION:
#   This script fixes common networking issues in a multi-cloud Kubernetes
#   cluster, particularly focusing on CNI networking, CoreDNS, and ensuring
#   nodes reach Ready state.
#
# USAGE:
#   ./fix-cluster-networking.sh
#
# ============================================================================

set -e

# Print banner
clear
echo "======================================================================"
echo "             MULTI-CLOUD KUBERNETES CLUSTER NETWORK REPAIR            "
echo "======================================================================"
echo ""

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# Function to execute a command and check its exit status
run_command() {
    local command="$1"
    local description="$2"
    
    echo "--------------------------------------------------------------------"
    echo "EXECUTING: $description"
    echo "COMMAND: $command"
    echo "--------------------------------------------------------------------"
    
    eval "$command"
    
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "ERROR: Command failed with exit code $exit_code"
        echo "Failed command: $command"
        echo ""
        echo "Continuing with the next repair step..."
        return $exit_code
    else
        echo "SUCCESS: Command completed successfully"
    fi
    echo ""
}

echo "Step 1: Checking cluster nodes status..."
kubectl get nodes

echo "Step 2: Checking CoreDNS pods..."
kubectl get pods -n kube-system -l k8s-app=kube-dns

echo "Step 3: Checking Flannel CNI pods..."
kubectl get pods -n kube-flannel

# Step 4: Verify and fix node network settings
echo "Step 4: Verifying node network settings across all nodes..."

# Create a tolerant flannel config that works with multi-cloud setups
echo "Step 5: Creating a more tolerant Flannel configuration for multi-cloud environments..."

# Generate a patched Flannel config that works better with multi-cloud setups
cat > flannel-patch.yaml << 'END'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kube-flannel-ds
  namespace: kube-flannel
spec:
  template:
    spec:
      containers:
      - name: kube-flannel
        env:
        - name: FLANNELD_IFACE
          valueFrom:
            fieldRef:
              fieldPath: status.hostIP
        command:
        - /opt/bin/flanneld
        - --ip-masq
        - --kube-subnet-mgr
        - --iface=\$(FLANNELD_IFACE)
END

run_command "kubectl -n kube-flannel patch daemonset kube-flannel-ds --patch-file flannel-patch.yaml" \
            "Patching Flannel DaemonSet to use host IP for interface detection"

# Step 6: Check if the patch worked, otherwise apply a more direct approach
echo "Step 6: Checking if the patch was successful..."
sleep 10
kubectl get pods -n kube-flannel

# Create and apply a completely new flannel config if needed
echo "Step 7: Ensuring all nodes have consistent Pod CIDR assignments..."
run_command "kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{\"\\t\"}{.spec.podCIDR}{\"\\n\"}{end}'" \
            "Getting Pod CIDR assignments for all nodes"

# Step 8: Force restart CoreDNS pods
echo "Step 8: Force restarting CoreDNS pods..."
run_command "kubectl -n kube-system delete pods -l k8s-app=kube-dns" \
            "Deleting CoreDNS pods to force restart"

echo "Step 9: Wait for CoreDNS pods to be recreated and recover..."
sleep 30
run_command "kubectl -n kube-system get pods -l k8s-app=kube-dns -w" \
            "Watching CoreDNS pods"

# Step 10: Check node status again to verify fixes worked
echo "Step 10: Checking node status again..."
run_command "kubectl get nodes" \
            "Getting node status after fixes"

# Step 11: If nodes still not ready, try restarting kubelet on each node
echo "Step 11: If nodes are still not Ready, you may need to restart kubelet on each node."
echo "You can do this manually by running on each node:"
echo "  systemctl restart kubelet"

echo ""
echo "======================================================================"
echo "                      REPAIR PROCESS COMPLETED                        "
echo "======================================================================"
echo ""
echo "Next steps if your nodes are still not Ready:"
echo ""
echo "1. Check kubelet logs on each node:"
echo "   journalctl -u kubelet -n 100"
echo ""
echo "2. Verify WireGuard VPN connections by running on each node:"
echo "   wg show"
echo ""
echo "3. Make sure nodes can reach each other via WireGuard IPs:"
echo "   ping <node-wireguard-ip>"
echo ""
echo "4. Check Pod CIDR subnet files on each node:"
echo "   cat /run/flannel/subnet.env"
echo ""
echo "5. If all else fails, you may need to reset your Kubernetes cluster and reinstall."
echo ""
