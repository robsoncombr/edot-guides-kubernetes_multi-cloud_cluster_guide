#!/bin/bash

# ============================================================================
# 002-Network_Connectivity_Test.sh - Test pod-to-pod and cross-node networking
# ============================================================================
# 
# DESCRIPTION:
#   This script tests the networking connectivity between pods across different
#   nodes in the Kubernetes multi-cloud cluster. It creates test pods on each 
#   node and verifies they can communicate with each other and access services.
#
# USAGE:
#   ./002-Network_Connectivity_Test.sh [--cleanup]
#
# OPTIONS:
#   --cleanup       Remove test pods and services after testing
#
# NOTES:
#   - Run this script after CNI setup and adding all nodes
#   - Requires kubectl access to the cluster
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
CLEANUP=false
if [[ "$1" == "--cleanup" ]]; then
    CLEANUP=true
fi

echo "======================================================================"
echo "Kubernetes Multi-Cloud Cluster Network Connectivity Test"
echo "======================================================================"

# Check prerequisites
if ! command -v kubectl &>/dev/null; then
    echo "Error: kubectl not found or not in PATH"
    echo "Please ensure Kubernetes is properly installed and configured"
    exit 1
fi

if ! kubectl get nodes &>/dev/null; then
    echo "Error: Cannot connect to Kubernetes API server"
    echo "Please check if control plane is running and KUBECONFIG is set correctly"
    exit 1
fi

# Create network test namespace if it doesn't exist
if ! kubectl get namespace network-test &>/dev/null; then
    echo "Creating test namespace..."
    kubectl create namespace network-test
else
    echo "Using existing network-test namespace"
fi

# Clean up existing resources if --cleanup is specified or before running tests
if [[ "$CLEANUP" == "true" ]]; then
    echo "Cleaning up existing test resources..."
    kubectl delete --namespace network-test deployments nettest-dep &>/dev/null
    kubectl delete --namespace network-test services nettest-svc &>/dev/null
    kubectl delete --namespace network-test pods nettest-standalone &>/dev/null
    
    echo "Waiting for resources to be deleted..."
    sleep 5
    
    if [[ "$1" == "--cleanup" ]]; then
        echo "Cleanup completed"
        kubectl delete namespace network-test &>/dev/null
        exit 0
    fi
fi

# Get node information
echo "Fetching node information..."
NODES=$(kubectl get nodes -o name | cut -d/ -f2)
NODE_COUNT=$(echo "$NODES" | wc -l)

echo "Found $NODE_COUNT nodes in the cluster:"
kubectl get nodes -o custom-columns=NAME:.metadata.name,INTERNAL-IP:.status.addresses[0].address,POD-CIDR:.spec.podCIDR,STATUS:.status.conditions[-1].type

# Create a deployment with pods on each node
echo "Creating test deployment with pod replicas for each node..."
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nettest-dep
  namespace: network-test
spec:
  replicas: $NODE_COUNT
  selector:
    matchLabels:
      app: nettest
  template:
    metadata:
      labels:
        app: nettest
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app
                  operator: In
                  values:
                  - nettest
              topologyKey: kubernetes.io/hostname
      containers:
      - name: nettest
        image: busybox:1.28
        command:
          - sleep
          - "3600"
        ports:
        - containerPort: 8080
