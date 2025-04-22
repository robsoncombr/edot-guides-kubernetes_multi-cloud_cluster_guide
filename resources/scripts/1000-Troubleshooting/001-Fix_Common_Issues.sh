#!/bin/bash

# ============================================================================
# 001-Fix_Common_Issues.sh - Comprehensive troubleshooting and repair script
# ============================================================================
# 
# DESCRIPTION:
#   This script diagnoses and fixes common issues in the Kubernetes multi-cloud
#   cluster, including network interfaces, Pod CIDRs, CNI configuration, etc.
#
# USAGE:
#   ./001-Fix_Common_Issues.sh [--help|--check-only|--fix-network|--fix-all]
#
# OPTIONS:
#   --help          Show this help message
#   --check-only    Only check for issues without fixing them
#   --fix-network   Fix only network-related issues
#   --fix-all       Fix all detected issues (default)
#
# ============================================================================

# Source the environment configuration
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
ENV_CONFIG_PATH="/root/data/development/edot-guides-kubernetes_multi-cloud_cluster_guide/resources/scripts/0100-Chapter_1/001-Environment_Config.sh"

if [ ! -f "$ENV_CONFIG_PATH" ]; then
    echo "Error: Environment configuration file not found at $ENV_CONFIG_PATH"
    exit 1
fi

source "$ENV_CONFIG_PATH"

# Parse arguments
CHECK_ONLY=false
FIX_NETWORK=false
FIX_ALL=true

if [[ "$1" == "--help" ]]; then
    echo "Usage: $0 [--help|--check-only|--fix-network|--fix-all]"
    echo ""
    echo "Options:"
    echo "  --help          Show this help message"
    echo "  --check-only    Only check for issues without fixing them"
    echo "  --fix-network   Fix only network-related issues"
    echo "  --fix-all       Fix all detected issues (default)"
    exit 0
elif [[ "$1" == "--check-only" ]]; then
    CHECK_ONLY=true
    FIX_ALL=false
elif [[ "$1" == "--fix-network" ]]; then
    FIX_NETWORK=true
    FIX_ALL=false
fi

echo "======================================================================"
echo "Kubernetes Multi-Cloud Cluster Troubleshooting"
echo "======================================================================"

# Check 1: Verify environment configuration
echo "[CHECK] Verifying environment configuration..."
if [[ "$POD_CIDR" == *"X"* ]]; then
    echo "  [ISSUE] Invalid Pod CIDR found in environment config: $POD_CIDR"
    if [[ "$CHECK_ONLY" == "false" ]] && ([[ "$FIX_NETWORK" == "true" ]] || [[ "$FIX_ALL" == "true" ]]); then
        echo "  [FIX] Updating Pod CIDR to valid value: 10.10.0.0/16"
        sed -i 's/POD_CIDR="10.10.X.0\/16"/POD_CIDR="10.10.0.0\/16"/' "$ENV_CONFIG_PATH"
        echo "  [DONE] Environment configuration updated."
    else
        echo "  [SUGGESTION] Run with --fix-network or --fix-all to fix this issue"
    fi
else
    echo "  [OK] Environment configuration looks good."
fi

# Check 2: Verify node connectivity
echo "[CHECK] Verifying node connectivity..."
for NODE_CONFIG in "${ALL_NODES[@]}"; do
    NODE_NAME=$(get_node_property "$NODE_CONFIG" 0)
    NODE_IP=$(get_node_property "$NODE_CONFIG" 1)
    
    if ping -c 1 -W 2 "$NODE_IP" &>/dev/null; then
        echo "  [OK] Node $NODE_NAME ($NODE_IP) is reachable."
    else
        echo "  [ISSUE] Cannot reach node $NODE_NAME ($NODE_IP)"
        echo "  [SUGGESTION] Check network connectivity and WireGuard configuration"
    fi
done

# Check 3: Verify Kubernetes node status
echo "[CHECK] Verifying Kubernetes node status..."
if ! command -v kubectl &>/dev/null; then
    echo "  [ISSUE] kubectl not found or not in PATH"
    echo "  [SUGGESTION] Ensure Kubernetes is properly installed"
else
    if ! kubectl get nodes &>/dev/null; then
        echo "  [ISSUE] Cannot connect to Kubernetes API server"
        echo "  [SUGGESTION] Check if control plane is running and KUBECONFIG is set correctly"
    else
        for NODE_CONFIG in "${ALL_NODES[@]}"; do
            NODE_NAME=$(get_node_property "$NODE_CONFIG" 0)
            NODE_POD_CIDR=$(get_node_property "$NODE_CONFIG" 2)
            NODE_INTERFACE=$(get_node_property "$NODE_CONFIG" 3)
            
            NODE_STATUS=$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "NotFound")
            if [[ "$NODE_STATUS" == "NotFound" ]]; then
                echo "  [ISSUE] Node $NODE_NAME not found in cluster"
                echo "  [SUGGESTION] Check if node was properly joined to the cluster"
            elif [[ "$NODE_STATUS" != "True" ]]; then
                echo "  [ISSUE] Node $NODE_NAME is not in Ready state (status: $NODE_STATUS)"
                if [[ "$CHECK_ONLY" == "false" ]] && ([[ "$FIX_NETWORK" == "true" ]] || [[ "$FIX_ALL" == "true" ]]); then
                    echo "  [FIX] Checking Flannel configuration on $NODE_NAME..."
                    
                    # For control plane node, fix locally
                    if [[ "$NODE_NAME" == "$(get_current_hostname)" ]]; then
                        mkdir -p /run/flannel
                        cat > /run/flannel/subnet.env << EOL
FLANNEL_NETWORK=$POD_CIDR
FLANNEL_SUBNET=$NODE_POD_CIDR
FLANNEL_MTU=1450
FLANNEL_IPMASQ=true
FLANNEL_IFACE=$NODE_INTERFACE
EOL
                        echo "  [FIX] Restarting kubelet on $NODE_NAME..."
                        systemctl restart kubelet
                    else
                        # For worker nodes, use SSH
                        echo "  [FIX] Setting up Flannel subnet configuration on $NODE_NAME via SSH..."
                        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "root@$NODE_IP" "mkdir -p /run/flannel && echo 'FLANNEL_NETWORK=$POD_CIDR' > /run/flannel/subnet.env && echo 'FLANNEL_SUBNET=$NODE_POD_CIDR' >> /run/flannel/subnet.env && echo 'FLANNEL_MTU=1450' >> /run/flannel/subnet.env && echo 'FLANNEL_IPMASQ=true' >> /run/flannel/subnet.env && echo 'FLANNEL_IFACE=$NODE_INTERFACE' >> /run/flannel/subnet.env && systemctl restart kubelet" || echo "  [ERROR] Failed to SSH to $NODE_NAME"
                    fi
                    echo "  [DONE] Flannel configuration updated on $NODE_NAME."
                else
                    echo "  [SUGGESTION] Run with --fix-network or --fix-all to fix this issue"
                fi
            else
                echo "  [OK] Node $NODE_NAME is Ready."
                
                # Check if Pod CIDR matches expected value
                CURRENT_CIDR=$(kubectl get node "$NODE_NAME" -o jsonpath='{.spec.podCIDR}' 2>/dev/null || echo "")
                if [[ "$CURRENT_CIDR" != "$NODE_POD_CIDR" ]]; then
                    echo "  [WARNING] Node $NODE_NAME has Pod CIDR $CURRENT_CIDR instead of $NODE_POD_CIDR"
                    echo "  [INFO] The Pod CIDR in Kubernetes API doesn't match configuration but this is handled by Flannel subnet config"
                    
                    # Still verify Flannel subnet.env has correct configuration
                    if [[ "$CHECK_ONLY" == "false" ]] && ([[ "$FIX_NETWORK" == "true" ]] || [[ "$FIX_ALL" == "true" ]]); then
                        echo "  [FIX] Ensuring Flannel subnet configuration is correct..."
                        
                        # For control plane node, fix locally
                        if [[ "$NODE_NAME" == "$(get_current_hostname)" ]]; then
                            if ! grep -q "FLANNEL_IFACE=$NODE_INTERFACE" /run/flannel/subnet.env 2>/dev/null; then
                                mkdir -p /run/flannel
                                cat > /run/flannel/subnet.env << EOL
FLANNEL_NETWORK=$POD_CIDR
FLANNEL_SUBNET=$NODE_POD_CIDR
FLANNEL_MTU=1450
FLANNEL_IPMASQ=true
FLANNEL_IFACE=$NODE_INTERFACE
EOL
                                echo "  [FIX] Restarting kubelet and Flannel on $NODE_NAME..."
                                systemctl restart kubelet
                                kubectl -n kube-flannel delete pod -l app=flannel --field-selector spec.nodeName=$NODE_NAME
                            fi
                        else
                            # For worker nodes, use SSH
                            echo "  [FIX] Ensuring Flannel subnet configuration is correct on $NODE_NAME via SSH..."
                            ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "root@$NODE_IP" "mkdir -p /run/flannel && echo 'FLANNEL_NETWORK=$POD_CIDR' > /run/flannel/subnet.env && echo 'FLANNEL_SUBNET=$NODE_POD_CIDR' >> /run/flannel/subnet.env && echo 'FLANNEL_MTU=1450' >> /run/flannel/subnet.env && echo 'FLANNEL_IPMASQ=true' >> /run/flannel/subnet.env && echo 'FLANNEL_IFACE=$NODE_INTERFACE' >> /run/flannel/subnet.env && systemctl restart kubelet" || echo "  [ERROR] Failed to SSH to $NODE_NAME"
                            
                            # Restart Flannel pod on worker node
                            kubectl -n kube-flannel delete pod -l app=flannel --field-selector spec.nodeName=$NODE_NAME
                        fi
                        echo "  [DONE] Flannel configuration updated on $NODE_NAME."
                    fi
                fi
            fi
        done
    fi
fi

# Check 4: Verify Flannel pods are running
echo "[CHECK] Verifying Flannel pods status..."
FLANNEL_PODS=$(kubectl -n kube-flannel get pods -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
if [[ -z "$FLANNEL_PODS" ]]; then
    echo "  [ISSUE] No Flannel pods found in the kube-flannel namespace"
    echo "  [SUGGESTION] Check if CNI was properly installed, run Chapter 4 CNI setup script"
else
    for POD in $FLANNEL_PODS; do
        POD_STATUS=$(kubectl -n kube-flannel get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)
        if [[ "$POD_STATUS" != "Running" ]]; then
            echo "  [ISSUE] Flannel pod $POD is not running (status: $POD_STATUS)"
            if [[ "$CHECK_ONLY" == "false" ]] && ([[ "$FIX_NETWORK" == "true" ]] || [[ "$FIX_ALL" == "true" ]]); then
                echo "  [FIX] Restarting Flannel pod $POD..."
                kubectl -n kube-flannel delete pod "$POD"
                echo "  [DONE] Flannel pod $POD restarted."
            else
                echo "  [SUGGESTION] Run with --fix-network or --fix-all to fix this issue"
            fi
        else
            echo "  [OK] Flannel pod $POD is Running."
        fi
    done
fi

# Check 5: Verify CoreDNS is working
echo "[CHECK] Verifying CoreDNS status..."
COREDNS_PODS=$(kubectl -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
if [[ -z "$COREDNS_PODS" ]]; then
    echo "  [ISSUE] No CoreDNS pods found in the kube-system namespace"
    echo "  [SUGGESTION] Check if Kubernetes control plane is healthy"
else
    for POD in $COREDNS_PODS; do
        POD_STATUS=$(kubectl -n kube-system get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)
        if [[ "$POD_STATUS" != "Running" ]]; then
            echo "  [ISSUE] CoreDNS pod $POD is not running (status: $POD_STATUS)"
            if [[ "$CHECK_ONLY" == "false" ]] && [[ "$FIX_ALL" == "true" ]]; then
                echo "  [FIX] Restarting CoreDNS pod $POD..."
                kubectl -n kube-system delete pod "$POD"
                echo "  [DONE] CoreDNS pod $POD restarted."
            else
                echo "  [SUGGESTION] Run with --fix-all to fix this issue"
            fi
        else
            echo "  [OK] CoreDNS pod $POD is Running."
        fi
    done
fi

echo "======================================================================"
echo "Troubleshooting Summary:"
echo ""
echo "- Pod CIDR: $POD_CIDR"
echo "- Service CIDR: $SERVICE_CIDR"
echo "- Node Status:"
kubectl get nodes -o custom-columns=NAME:.metadata.name,INTERNAL-IP:.status.addresses[0].address,POD-CIDR:.spec.podCIDR,STATUS:.status.conditions[-1].type
echo ""
echo "- Flannel Pods:"
kubectl -n kube-flannel get pods -o wide
echo ""
echo "- CoreDNS Pods:"
kubectl -n kube-system get pods -l k8s-app=kube-dns
echo "======================================================================"

if [[ "$CHECK_ONLY" == "true" ]]; then
    echo "Checks completed. Run without --check-only to fix issues."
else
    echo "Checks and fixes completed. Cluster should be operational."
    echo "If issues persist, check individual node logs and connectivity."
fi
