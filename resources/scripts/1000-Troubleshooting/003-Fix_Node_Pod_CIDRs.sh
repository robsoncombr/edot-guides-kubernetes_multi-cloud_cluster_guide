#!/bin/bash

# ============================================================================
# 003-Fix_Node_Pod_CIDRs.sh - Fix Pod CIDR assignments for nodes
# ============================================================================
# 
# DESCRIPTION:
#   This script corrects the Pod CIDR assignments for each node in the cluster
#   to match the expected configuration in the environment config file.
#
# USAGE:
#   ./003-Fix_Node_Pod_CIDRs.sh
#
# ============================================================================

# Function to get formatted timestamp for logging
get_timestamp() {
    date "+%y%m%d-%H%M%S"
}

# Log with timestamp and hostname prefix
log_message() {
    echo "[$(hostname): $(get_timestamp)] $1"
}

log_message "Starting Pod CIDR correction for nodes..."

# Source the environment configuration
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
BASE_DIR=$(realpath "$SCRIPT_DIR/../..")
ENV_CONFIG_PATH="$BASE_DIR/0100-Chapter_1/001-Environment_Config.sh"

if [ ! -f "$ENV_CONFIG_PATH" ]; then
    log_message "Error: Environment configuration file not found at $ENV_CONFIG_PATH"
    log_message "Searching for Environment_Config.sh..."
    
    # Try to find the environment config file
    ENV_CONFIG_PATH=$(find "$BASE_DIR" -name "001-Environment_Config.sh" | head -n 1)
    
    if [ -z "$ENV_CONFIG_PATH" ]; then
        log_message "Error: Could not find Environment_Config.sh in the workspace"
        exit 1
    else
        log_message "Found environment config at: $ENV_CONFIG_PATH"
    fi
fi

log_message "Using environment configuration from: $ENV_CONFIG_PATH"
source "$ENV_CONFIG_PATH"

# Verify that the environment configuration was loaded correctly
if [ -z "$POD_CIDR" ] || [ -z "$K8S_VERSION" ] || [ ${#ALL_NODES[@]} -eq 0 ]; then
    log_message "Error: Environment configuration not loaded correctly"
    log_message "POD_CIDR: $POD_CIDR"
    log_message "K8S_VERSION: $K8S_VERSION"
    log_message "ALL_NODES: ${#ALL_NODES[@]} items"
    exit 1
fi

log_message "Environment configuration loaded successfully"
log_message "Kubernetes Version: $K8S_VERSION"
log_message "Pod CIDR: $POD_CIDR"
log_message "Service CIDR: $SERVICE_CIDR"

# Display current node status and CIDR assignments
log_message "Current node status and CIDR assignments:"
kubectl get nodes -o custom-columns=NAME:.metadata.name,INTERNAL-IP:.status.addresses[?\(@.type==\"InternalIP\"\)].address,POD-CIDR:.spec.podCIDR,STATUS:.status.conditions[-1].type

# Print node configurations from the environment file
log_message "Expected node configurations from environment file:"
print_node_configs

# Function to create Flannel subnet file content
create_flannel_subnet_env() {
    local pod_cidr="$1"
    local net_conf="{\"Network\":\"$POD_CIDR\",\"SubnetLen\":24,\"SubnetMin\":\"$(echo $pod_cidr | cut -d'/' -f1 | sed 's/\.[0-9]*$/\.0/')\",\"SubnetMax\":\"$(echo $pod_cidr | cut -d'/' -f1 | sed 's/\.[0-9]*$/\.0/')\",\"Backend\":{\"Type\":\"vxlan\"}}"
    echo "$net_conf"
}

# Verify each node and update its Pod CIDR if needed
for NODE_CONFIG in "${ALL_NODES[@]}"; do
    NODE_NAME=$(get_node_property "$NODE_CONFIG" 0)
    NODE_IP=$(get_node_property "$NODE_CONFIG" 1)
    NODE_POD_CIDR=$(get_node_property "$NODE_CONFIG" 2)
    NODE_INTERFACE=$(get_node_property "$NODE_CONFIG" 3)
    
    log_message "Checking node $NODE_NAME ($NODE_IP)..."
    log_message "Expected Pod CIDR: $NODE_POD_CIDR"
    log_message "Network Interface: $NODE_INTERFACE"
    
    # Get current Pod CIDR
    CURRENT_CIDR=$(kubectl get node "$NODE_NAME" -o jsonpath='{.spec.podCIDR}' 2>/dev/null)
    if [ -z "$CURRENT_CIDR" ]; then
        log_message "Warning: Could not retrieve current Pod CIDR for $NODE_NAME"
        CURRENT_CIDR="unknown"
    fi
    log_message "Current Pod CIDR: $CURRENT_CIDR"
    
    if [ "$CURRENT_CIDR" != "$NODE_POD_CIDR" ]; then
        log_message "Pod CIDR mismatch. Updating..."
        
        # Update the node's Pod CIDR
        kubectl patch node "$NODE_NAME" -p "{\"spec\":{\"podCIDR\":\"$NODE_POD_CIDR\",\"podCIDRs\":[\"$NODE_POD_CIDR\"]}}"
        
        if [ $? -eq 0 ]; then
            log_message "Successfully updated Pod CIDR for $NODE_NAME"
        else
            log_message "Failed to update Pod CIDR for $NODE_NAME"
        fi
    else
        log_message "Pod CIDR is already correct for $NODE_NAME"
    fi
done

# Create a script to update Flannel subnet configuration
log_message "Creating Flannel subnet update script..."

cat > /tmp/update_flannel_subnet.sh << 'EOL'
#!/bin/bash

# Function to get formatted timestamp for logging
get_timestamp() {
    date "+%y%m%d-%H%M%S"
}

# Log with timestamp and hostname prefix
log_message() {
    echo "[$(hostname): $(get_timestamp)] $1"
}

# Get the node name
NODE_NAME=$(hostname)
log_message "Updating Flannel subnet configuration for $NODE_NAME"

# Get the node's Pod CIDR from parameters
NODE_POD_CIDR="$1"
POD_CIDR="$2"

if [ -z "$NODE_POD_CIDR" ] || [ -z "$POD_CIDR" ]; then
    log_message "Error: Missing required parameters"
    log_message "Usage: $0 NODE_POD_CIDR POD_CIDR"
    exit 1
fi

log_message "Node Pod CIDR: $NODE_POD_CIDR"
log_message "Global Pod CIDR: $POD_CIDR"

# Create subnet.env content
NET_CONF="{\"Network\":\"$POD_CIDR\",\"SubnetLen\":24,\"SubnetMin\":\"$(echo $NODE_POD_CIDR | cut -d'/' -f1 | sed 's/\.[0-9]*$/\.0/')\",\"SubnetMax\":\"$(echo $NODE_POD_CIDR | cut -d'/' -f1 | sed 's/\.[0-9]*$/\.0/')\",\"Backend\":{\"Type\":\"vxlan\"}}"

# Update Flannel subnet configuration
log_message "Creating Flannel configuration..."
mkdir -p /run/flannel
echo "$NET_CONF" > /run/flannel/subnet.env

log_message "Flannel subnet configuration updated:"
cat /run/flannel/subnet.env

# Restart Flannel pods
log_message "Identifying Flannel pods to restart..."
FLANNEL_PODS=$(crictl pods --name flannel -q 2>/dev/null)
if [ -n "$FLANNEL_PODS" ]; then
    log_message "Restarting Flannel pods: $FLANNEL_PODS"
    crictl rmp -f $FLANNEL_PODS
    log_message "Flannel pods have been restarted"
else
    log_message "No Flannel pods found using crictl"
    
    # Try using kubectl as a fallback
    log_message "Attempting to restart Flannel pods using kubectl..."
    FLANNEL_PODS=$(kubectl get pods --all-namespaces -o wide --field-selector spec.nodeName=$NODE_NAME | grep flannel | awk '{print $2}')
    if [ -n "$FLANNEL_PODS" ]; then
        for pod in $FLANNEL_PODS; do
            log_message "Deleting Flannel pod $pod"
            kubectl delete pod $pod -n kube-flannel --force --grace-period=0
        done
        log_message "Flannel pods have been restarted with kubectl"
    else
        log_message "Warning: No Flannel pods found to restart"
    fi
fi

log_message "Restarting kubelet service..."
systemctl restart kubelet

log_message "Flannel subnet update completed for $NODE_NAME"
EOL

chmod +x /tmp/update_flannel_subnet.sh

# Apply the Flannel subnet update script to each node
for NODE_CONFIG in "${ALL_NODES[@]}"; do
    NODE_NAME=$(get_node_property "$NODE_CONFIG" 0)
    NODE_IP=$(get_node_property "$NODE_CONFIG" 1)
    NODE_POD_CIDR=$(get_node_property "$NODE_CONFIG" 2)
    
    log_message "Updating Flannel subnet configuration on $NODE_NAME ($NODE_IP)..."
    
    if [[ "$NODE_NAME" == "$(hostname)" ]]; then
        # Execute locally
        bash /tmp/update_flannel_subnet.sh "$NODE_POD_CIDR" "$POD_CIDR"
    else
        # Copy and execute on remote node
        scp /tmp/update_flannel_subnet.sh "root@$NODE_IP:/tmp/"
        ssh "root@$NODE_IP" "bash /tmp/update_flannel_subnet.sh '$NODE_POD_CIDR' '$POD_CIDR' && rm -f /tmp/update_flannel_subnet.sh"
    fi
done

rm -f /tmp/update_flannel_subnet.sh

# Wait for nodes to settle
log_message "Waiting for nodes to settle (60 seconds)..."
sleep 60

# Display final node status and CIDR assignments
log_message "Final node status and CIDR assignments:"
kubectl get nodes -o custom-columns=NAME:.metadata.name,INTERNAL-IP:.status.addresses[?\(@.type==\"InternalIP\"\)].address,POD-CIDR:.spec.podCIDR,STATUS:.status.conditions[-1].type

# Check if all nodes are in Ready state
READY_NODES=$(kubectl get nodes | grep -c "Ready")
TOTAL_NODES=$(kubectl get nodes | grep -v "NAME" | wc -l)

log_message "Ready nodes: $READY_NODES/$TOTAL_NODES"

if [ "$READY_NODES" -eq "$TOTAL_NODES" ]; then
    log_message "All nodes are in Ready state!"
else
    log_message "Warning: Not all nodes are in Ready state"
fi

log_message "Pod CIDR correction completed."

# Check if pod networking is working correctly
log_message "Testing pod networking..."
kubectl create namespace pod-network-test 2>/dev/null || true

cat << EOT | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: network-test
  namespace: pod-network-test
spec:
  replicas: 3
  selector:
    matchLabels:
      app: network-test
  template:
    metadata:
      labels:
        app: network-test
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchExpressions:
              - key: app
                operator: In
                values:
                - network-test
            topologyKey: kubernetes.io/hostname
      containers:
      - name: nginx
        image: nginx:stable-alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: network-test
  namespace: pod-network-test
spec:
  selector:
    app: network-test
  ports:
  - port: 80
    targetPort: 80
  type: ClusterIP
EOT

log_message "Waiting for test pods to start (60 seconds)..."
sleep 60

log_message "Test pod distribution:"
kubectl get pods -n pod-network-test -o wide

log_message "Testing pod-to-pod communication..."
TEST_POD=$(kubectl get pods -n pod-network-test -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "$TEST_POD" ]; then
    kubectl exec -n pod-network-test $TEST_POD -- wget -T 5 -qO- network-test.pod-network-test.svc.cluster.local
    
    if [ $? -eq 0 ]; then
        log_message "Pod-to-pod communication is working correctly!"
    else
        log_message "Warning: Pod-to-pod communication test failed"
    fi
else
    log_message "Warning: No test pods found"
fi

log_message "Pod CIDR troubleshooting and testing completed."
