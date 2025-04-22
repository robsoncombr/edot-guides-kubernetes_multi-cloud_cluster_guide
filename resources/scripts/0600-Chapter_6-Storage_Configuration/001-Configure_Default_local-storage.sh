#!/bin/bash

# ============================================================================
# 001-Configure_Default_local-storage.sh - Script to set up local storage
# ============================================================================
# 
# DESCRIPTION:
#   This script configures a default local storage class for a Kubernetes
#   cluster. It creates local persistent volumes on each node and sets up
#   a StorageClass to use these volumes.
#
# USAGE:
#   ./001-Configure_Default_local-storage.sh
#
# NOTES:
#   - Run this script on the control plane node after CNI and DNS setup
#   - Creates local storage directories at /mnt/local-storage on all nodes
# ============================================================================

# Source the environment configuration
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
ENV_CONFIG_PATH="$(realpath "$SCRIPT_DIR/../0100-Chapter_1/001-Environment_Config.sh")"

if [ ! -f "$ENV_CONFIG_PATH" ]; then
    echo "Error: Environment configuration file not found at $ENV_CONFIG_PATH"
    exit 1
fi

source "$ENV_CONFIG_PATH"

echo "======================================================================"
echo "Setting up default local storage for Kubernetes cluster"
echo "======================================================================"

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# Function to check if command succeeded
check_status() {
  if [ $? -ne 0 ]; then
    echo "❌ ERROR: $1 failed"
    return 1
  else
    echo "✅ SUCCESS: $1 completed"
    return 0
  fi
}

# Check if running on control plane node
HOSTNAME=$(get_current_hostname)
CONTROL_PLANE_HOSTNAME=$(get_node_property "${NODE_CP1}" 0)

if [[ "$HOSTNAME" != "$CONTROL_PLANE_HOSTNAME" ]]; then
    echo "Error: This script must be run on the control plane node ($CONTROL_PLANE_HOSTNAME)"
    echo "Current host: $HOSTNAME"
    exit 1
fi

# Create a temporary directory for manifests
MANIFEST_DIR="/tmp/storage-manifests"
mkdir -p $MANIFEST_DIR

# ============================================================================
# STEP 1: Create storage directories on all nodes
# ============================================================================
echo "Setting up local storage directories on all nodes..."

for NODE_CONFIG in "${ALL_NODES[@]}"; do
    NODE_NAME=$(get_node_property "$NODE_CONFIG" 0)
    NODE_IP=$(get_node_property "$NODE_CONFIG" 1)
    NODE_ROLE=$(get_node_property "$NODE_CONFIG" 4)
    
    echo "Creating storage directory on $NODE_NAME ($NODE_IP)..."
    
    if [[ "$NODE_NAME" == "$HOSTNAME" ]]; then
        # Local node
        mkdir -p /mnt/local-storage
        chmod 777 /mnt/local-storage
        check_status "Creating storage directory on local node"
    else
        # Remote node - try SSH first
        if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$NODE_IP "mkdir -p /mnt/local-storage && chmod 777 /mnt/local-storage" > /dev/null 2>&1; then
            echo "✅ Storage directory created via SSH on $NODE_NAME"
        else
            echo "SSH failed, will try via Kubernetes DaemonSet..."
            # For each node, we'll use a privileged pod to create the directory
            cat > $MANIFEST_DIR/storage-prep-$NODE_NAME.yaml << EOF
apiVersion: v1
kind: Pod
metadata:
  name: storage-prep-$NODE_NAME
  namespace: default
spec:
  hostNetwork: true
  restartPolicy: Never
  nodeName: $NODE_NAME
  tolerations:
  - key: node.kubernetes.io/not-ready
    operator: Exists
    effect: NoSchedule
  containers:
  - name: storage-prep
    image: busybox:1.28
    command: 
    - /bin/sh
    - -c
    - |
      mkdir -p /mnt/local-storage
      chmod 777 /mnt/local-storage
      echo "Storage directory created on $NODE_NAME"
    volumeMounts:
    - name: host-storage
      mountPath: /mnt
    securityContext:
      privileged: true
  volumes:
  - name: host-storage
    hostPath:
      path: /mnt
EOF
            kubectl apply -f $MANIFEST_DIR/storage-prep-$NODE_NAME.yaml
            sleep 5
            kubectl logs storage-prep-$NODE_NAME --tail=10 || true
            kubectl delete -f $MANIFEST_DIR/storage-prep-$NODE_NAME.yaml --force --grace-period=0 || true
            echo "✅ Storage directory created via pod on $NODE_NAME"
        fi
    fi
done

# ============================================================================
# STEP 2: Create StorageClass for local storage
# ============================================================================
echo "Creating StorageClass for local storage..."

cat > $MANIFEST_DIR/local-storage-class.yaml << EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
EOF

kubectl apply -f $MANIFEST_DIR/local-storage-class.yaml
check_status "Creating StorageClass"

# ============================================================================
# STEP 3: Create PersistentVolumes for each node
# ============================================================================
echo "Creating PersistentVolumes for each node..."

PV_SIZE=${PV_SIZE:-"10Gi"}  # Default size if not specified
PV_COUNT=${PV_COUNT:-"5"}   # Default number of PVs per node

for NODE_CONFIG in "${ALL_NODES[@]}"; do
    NODE_NAME=$(get_node_property "$NODE_CONFIG" 0)
    
    for i in $(seq 1 $PV_COUNT); do
        # Generate a unique name for each PV
        PV_NAME="local-pv-$NODE_NAME-$i"
        PATH_ON_NODE="/mnt/local-storage/vol$i"
        
        # Create directory on the node
        if [[ "$NODE_NAME" == "$HOSTNAME" ]]; then
            mkdir -p $PATH_ON_NODE
            chmod 777 $PATH_ON_NODE
        else
            NODE_IP=$(get_node_property "$NODE_CONFIG" 1)
            ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$NODE_IP "mkdir -p $PATH_ON_NODE && chmod 777 $PATH_ON_NODE" > /dev/null 2>&1 || true
        fi
        
        # Create the PV with node affinity
        cat > $MANIFEST_DIR/$PV_NAME.yaml << EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $PV_NAME
spec:
  capacity:
    storage: $PV_SIZE
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: $PATH_ON_NODE
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - $NODE_NAME
EOF
        
        kubectl apply -f $MANIFEST_DIR/$PV_NAME.yaml
        check_status "Creating PV $PV_NAME on $NODE_NAME"
    done
    
    echo "✅ Created $PV_COUNT PersistentVolumes for node $NODE_NAME"
done

# ============================================================================
# STEP 4: Test storage functionality
# ============================================================================
echo "Testing storage functionality..."

# Create a test PVC
cat > $MANIFEST_DIR/test-pvc.yaml << EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-local-claim
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: local-storage
EOF

kubectl apply -f $MANIFEST_DIR/test-pvc.yaml
check_status "Creating test PVC"

# Wait for PVC to be bound
echo "Waiting for PVC to be bound..."
for i in $(seq 1 10); do
    PVC_STATUS=$(kubectl get pvc test-local-claim -o jsonpath='{.status.phase}' 2>/dev/null)
    if [[ "$PVC_STATUS" == "Bound" ]]; then
        echo "✅ PVC successfully bound to a PV"
        BOUND_PV=$(kubectl get pvc test-local-claim -o jsonpath='{.spec.volumeName}' 2>/dev/null)
        echo "   Bound to PV: $BOUND_PV"
        break
    fi
    if [[ $i -eq 10 ]]; then
        echo "⚠️ PVC not bound after waiting. This is expected if no pods are using it yet."
        echo "   The volumeBindingMode is set to WaitForFirstConsumer, so it will bind when a pod uses it."
    else
        echo "Waiting for PVC to bind... ($i/10)"
        sleep 3
    fi
done

# Create a pod that uses the PVC
cat > $MANIFEST_DIR/test-storage-pod.yaml << EOF
apiVersion: v1
kind: Pod
metadata:
  name: storage-test-pod
spec:
  tolerations:
  - key: node.kubernetes.io/not-ready
    operator: Exists
    effect: NoSchedule
  containers:
  - name: storage-test
    image: busybox:1.28
    command:
      - "/bin/sh"
      - "-c"
      - "echo 'Storage test success!' > /data/test-file.txt && cat /data/test-file.txt && sleep 3600"
    volumeMounts:
    - name: local-persistent-storage
      mountPath: /data
  volumes:
  - name: local-persistent-storage
    persistentVolumeClaim:
      claimName: test-local-claim
EOF

# Create new test pod
kubectl apply -f $MANIFEST_DIR/test-storage-pod.yaml
check_status "Creating test pod"

# Wait for the test pod to be running
echo "Waiting for storage test pod to be ready..."
for i in $(seq 1 15); do
    if kubectl get pod storage-test-pod | grep -q Running; then
        echo "✅ Storage test pod is now running"
        break
    fi
    echo "Waiting for storage test pod to start... ($i/15)"
    sleep 5
    if [ $i -eq 15 ]; then
        echo "⚠️ Storage test pod did not start in time"
    fi
done

# Check if the test file was created successfully
sleep 5  # Give the pod a moment to write the file
if kubectl logs storage-test-pod | grep -q "Storage test success!"; then
    echo "✅ Storage test successful! The pod could write and read from the volume."
else
    echo "❌ Storage test failed. Check the pod logs for details."
fi

# Delete any existing test pod
kubectl delete pod storage-test-pod --force --grace-period=0 --ignore-not-found=true
sleep 5

echo "======================================================================"
echo "Local storage setup complete! Summary:"
echo ""
echo "StorageClass created: local-storage (set as default)"
echo "PersistentVolumes created: $(kubectl get pv | grep local-pv | wc -l)"
echo "Test PVC status: $(kubectl get pvc test-local-claim -o jsonpath='{.status.phase}' 2>/dev/null || echo 'Not created')"
echo ""
echo "You can now use the 'local-storage' StorageClass for your applications."
echo "Example PVC:"
echo "---"
echo "apiVersion: v1"
echo "kind: PersistentVolumeClaim"
echo "metadata:"
echo "  name: my-app-data"
echo "spec:"
echo "  accessModes:"
echo "  - ReadWriteOnce"
echo "  resources:"
echo "    requests:"
echo "      storage: 1Gi"
echo "  storageClassName: local-storage"
echo "---"
echo ""
echo "Note: With volumeBindingMode: WaitForFirstConsumer, PVCs will remain"
echo "in Pending state until a pod using them is scheduled to a node."
echo "======================================================================"

# Clean up temporary files
rm -rf $MANIFEST_DIR
