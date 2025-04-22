#!/bin/bash

# ============================================================================
# 002-DNS_Setup.sh - Script to configure CoreDNS for a multi-cloud cluster
# ============================================================================
# 
# DESCRIPTION:
#   This script configures and verifies CoreDNS in a multi-cloud Kubernetes
#   cluster. It ensures CoreDNS pods are deployed correctly for DNS resolution
#   across all nodes in the cluster.
#
#   The script now automatically detects and fixes common DNS issues without
#   requiring separate fix scripts.
#
# USAGE:
#   ./002-DNS_Setup.sh
#
# NOTES:
#   - Run this script on the control plane node after CNI setup
#   - Helps ensure DNS resolution works across all nodes in multi-cloud setup
#   - Integrates automatic detection and fixes for common multi-cloud DNS issues
# ============================================================================

# Source the environment configuration
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
ENV_CONFIG_PATH="$(realpath "$SCRIPT_DIR/../0100-Chapter_1/001-Environment_Config.sh")"

if [ ! -f "$ENV_CONFIG_PATH" ]; then
    echo "Error: Environment configuration file not found at $ENV_CONFIG_PATH"
    echo "Creating a minimal environment configuration for DNS setup"
    # Create a default configuration if the environment config doesn't exist
    mkdir -p "$(dirname "$ENV_CONFIG_PATH")"
    cat > "$ENV_CONFIG_PATH" << EOF
#!/bin/bash
# Default environment configuration with DNS settings
DNS_SERVICE_IP="10.1.0.10"
EOF
fi

source "$ENV_CONFIG_PATH"

echo "======================================================================"
echo "Setting up CoreDNS for multi-cloud Kubernetes cluster"
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

# Function to detect and fix service CIDR mismatches
detect_fix_service_cidr_mismatch() {
    echo "Checking for service CIDR configuration and DNS service IP mismatch..."
    
    # Try different methods to get the service CIDR
    SERVICE_CIDR=$(kubectl get cm -n kube-system kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' 2>/dev/null | grep "serviceSubnet" | awk '{print $2}')
    
    if [ -z "$SERVICE_CIDR" ]; then
        # Try finding from API server configuration
        MASTER_NODE=$(kubectl get nodes | grep control-plane | awk '{print $1}')
        if [ -n "$MASTER_NODE" ]; then
            SERVICE_CIDR=$(ssh $MASTER_NODE "grep -r service-cluster-ip-range /etc/kubernetes/" 2>/dev/null | head -n 1 | grep -o 'service-cluster-ip-range=[^ ]*' | cut -d= -f2)
        fi
    fi
    
    if [ -z "$SERVICE_CIDR" ]; then
        echo "⚠️ Could not determine service CIDR from standard locations, using configured DNS_SERVICE_IP=$DNS_SERVICE_IP"
        return 0
    fi
    
    echo "Detected service CIDR: $SERVICE_CIDR"
    
    # Get current DNS service IP if it exists
    CURRENT_DNS_IP=$(kubectl get svc -n kube-system kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    
    if [ -n "$CURRENT_DNS_IP" ]; then
        echo "Current kube-dns Service IP: $CURRENT_DNS_IP"
        
        # Check if service CIDR and DNS IP match
        BASE_IP=$(echo $SERVICE_CIDR | cut -d'/' -f1 | cut -d'.' -f1,2)
        CURRENT_BASE=$(echo $CURRENT_DNS_IP | cut -d'.' -f1,2)
        
        if [[ "$BASE_IP" != "$CURRENT_BASE" ]]; then
            echo "⚠️ Mismatch detected between service CIDR ($SERVICE_CIDR) and DNS service IP ($CURRENT_DNS_IP)"
            echo "Will recreate DNS service with correct IP after deleting existing resources."
            
            # Calculate the proper DNS service IP based on service CIDR
            NEW_DNS_IP="${BASE_IP}.0.10"
            DNS_SERVICE_IP="$NEW_DNS_IP"
            echo "Updated DNS service IP to match service CIDR: $DNS_SERVICE_IP"
            
            # We'll delete the service in the cleanup phase, so return now
            return 0
        else
            echo "✅ DNS service IP correctly matches service CIDR"
        fi
    else
        # No existing DNS service, extract base IP for new service
        BASE_IP=$(echo $SERVICE_CIDR | cut -d'/' -f1 | cut -d'.' -f1,2)
        NEW_DNS_IP="${BASE_IP}.0.10"
        
        if [[ "$DNS_SERVICE_IP" != "$NEW_DNS_IP" ]]; then
            echo "⚠️ Configured DNS service IP ($DNS_SERVICE_IP) doesn't match service CIDR ($SERVICE_CIDR)"
            DNS_SERVICE_IP="$NEW_DNS_IP"
            echo "Updated DNS service IP to match service CIDR: $DNS_SERVICE_IP"
        fi
    fi
}

# Function to check if we should enable hostNetwork mode
should_enable_host_network() {
    # Look for signs that we're in a multi-cloud environment
    NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
    UNIQUE_SUBNETS=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' | tr ' ' '\n' | cut -d'.' -f1,2 | sort | uniq | wc -l)
    
    if [[ $NODE_COUNT -gt 1 && $UNIQUE_SUBNETS -gt 1 ]]; then
        echo "Detected multiple network subnets in a multi-node cluster."
        echo "This is likely a multi-cloud setup that needs hostNetwork for reliable DNS."
        return 0  # true in bash
    fi
    
    # Check if we have nodelocaldns setup
    if kubectl get daemonset -n kube-system nodelocaldns > /dev/null 2>&1; then
        echo "Detected nodelocaldns DaemonSet. Enabling hostNetwork won't be needed."
        return 1  # false in bash
    fi
    
    # Check for cross-subnet pod communication issues
    echo "Testing cross-node pod communication..."
    NODES=$(kubectl get nodes -o name | cut -d'/' -f2)
    HAS_CONNECTION_ISSUES=0
    
    for NODE in $NODES; do
        # Skip if this is a control plane node with NoSchedule taint
        if kubectl get node $NODE -o jsonpath='{.spec.taints[*].effect}' | grep -q "NoSchedule"; then
            echo "Skipping control plane node $NODE for communication test"
            continue
        fi
        
        # Check if we can run a quick test pod on this node
        echo "Testing network from node $NODE..."
        cat > /tmp/test-pod-$NODE.yaml << EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-net-$NODE
  namespace: default
spec:
  nodeName: $NODE
  containers:
  - name: network-test
    image: busybox:latest
    command:
      - sleep
      - "60"
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
EOF
        
        kubectl apply -f /tmp/test-pod-$NODE.yaml > /dev/null
        
        # Wait for pod to be running
        for i in {1..10}; do
            if kubectl get pod test-net-$NODE | grep -q Running; then
                break
            fi
            sleep 3
        done
        
        # Check if pod can ping DNS IP or other known service
        if ! kubectl exec -i test-net-$NODE -- ping -c 2 -W 5 $DNS_SERVICE_IP > /dev/null 2>&1; then
            echo "⚠️ Pod on node $NODE cannot reach DNS service IP directly."
            HAS_CONNECTION_ISSUES=1
        fi
        
        # Cleanup test pod
        kubectl delete pod test-net-$NODE --force --grace-period=0 > /dev/null
        rm -f /tmp/test-pod-$NODE.yaml
    done
    
    if [ $HAS_CONNECTION_ISSUES -eq 1 ]; then
        echo "Detected cross-node networking issues that may impact DNS. Will enable hostNetwork."
        return 0  # true in bash
    fi
    
    # Default to not using host network
    return 1  # false in bash
}

# Create a temporary directory for manifests
MANIFEST_DIR="/tmp/coredns-manifests"
mkdir -p $MANIFEST_DIR

# ============================================================================
# STEP 1: Verify CNI is working properly and detect potential DNS issues
# ============================================================================
echo "Verifying that CNI is working properly before DNS setup..."

# Check if any nodes are not ready
NOT_READY_NODES=$(kubectl get nodes --no-headers | grep -v " Ready " | wc -l)
if [[ "$NOT_READY_NODES" -gt 0 ]]; then
    echo "⚠️ Warning: $NOT_READY_NODES nodes are not in Ready state."
    echo "This may cause issues with DNS setup. Consider running CNI troubleshooting first."
    
    # Continue anyway with a warning
    echo "Proceeding with DNS setup, but it may fail if CNI issues persist."
else
    echo "✅ All nodes are in Ready state. CNI appears to be working properly."
fi

# Proactively check for service CIDR and DNS IP mismatches
detect_fix_service_cidr_mismatch

# Check current CoreDNS status
echo "Checking current CoreDNS status..."
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide
echo ""

# Get CoreDNS version and image
echo "Getting CoreDNS details..."
COREDNS_IMAGE=$(kubectl -n kube-system get deployment coredns -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "registry.k8s.io/coredns/coredns:v1.11.3")
echo "Current CoreDNS image: $COREDNS_IMAGE"

# Determine if we should use hostNetwork mode
USE_HOST_NETWORK=false
if should_enable_host_network; then
    echo "Enabling CoreDNS hostNetwork mode for better multi-cloud compatibility"
    USE_HOST_NETWORK=true
else
    echo "Standard CoreDNS networking mode will be used"
fi

# ============================================================================
# STEP 2: Remove any existing problematic DNS configuration
# ============================================================================
echo "Removing existing CoreDNS resources for clean setup..."

# Wait for any modifications in progress to complete
sleep 5

# Delete any existing CoreDNS resources in a specific order
kubectl delete pods -n kube-system -l k8s-app=kube-dns --grace-period=0 --force --ignore-not-found=true
kubectl delete deployment coredns -n kube-system --ignore-not-found=true
kubectl delete configmap coredns -n kube-system --ignore-not-found=true
kubectl delete service kube-dns -n kube-system --ignore-not-found=true

# Wait for everything to be cleaned up
sleep 10

# Check the service account
echo "Checking CoreDNS service account..."
if ! kubectl -n kube-system get serviceaccount coredns > /dev/null 2>&1; then
    echo "Creating CoreDNS service account..."
    kubectl -n kube-system create serviceaccount coredns
    check_status "CoreDNS service account creation"
fi

# Set up proper RBAC permissions for CoreDNS
echo "Setting up RBAC permissions for CoreDNS..."
cat > $MANIFEST_DIR/coredns-rbac.yaml << EOF
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: system:coredns
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
rules:
- apiGroups:
  - ""
  resources:
  - endpoints
  - services
  - pods
  - namespaces
  verbs:
  - list
  - watch
- apiGroups:
  - discovery.k8s.io
  resources:
  - endpointslices
  verbs:
  - list
  - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:coredns
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:coredns
subjects:
- kind: ServiceAccount
  name: coredns
  namespace: kube-system
EOF

kubectl apply -f $MANIFEST_DIR/coredns-rbac.yaml
check_status "CoreDNS RBAC configuration"

# ============================================================================
# STEP 3: Set up CoreDNS components
# ============================================================================

# Step 1: Create CoreDNS ConfigMap with optimized configuration for multi-cloud
echo "Creating CoreDNS ConfigMap with port adjustments to avoid conflicts with host DNS..."
cat > $MANIFEST_DIR/coredns-configmap.yaml << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
    kubernetes.io/cluster-service: "true"
data:
  Corefile: |
    .:9053 {
        errors
        health {
            lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
            pods insecure
            fallthrough in-addr.arpa ip6.arpa
            ttl 30
        }
        prometheus :9153
        forward . 1.1.1.1 8.8.8.8 {
            max_concurrent 1000
            prefer_udp
        }
        cache 30
        loop
        reload
        loadbalance
        hosts {
            fallthrough
        }
    }
EOF

kubectl apply -f $MANIFEST_DIR/coredns-configmap.yaml
check_status "CoreDNS ConfigMap creation"

# Step 2: Create CoreDNS service with port adjustments
echo "Creating CoreDNS service with port adjustments..."

# Get current cluster service CIDR from the API server configuration
CLUSTER_SERVICE_CIDR=$(kubectl get cm -n kube-system kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' 2>/dev/null | grep "serviceSubnet" | awk '{print $2}')

# Default to 10.1.0.0/16 if not found and not already set by our detection function
if [ -z "$CLUSTER_SERVICE_CIDR" ]; then
    CLUSTER_SERVICE_CIDR="10.1.0.0/16"
    echo "Using default service CIDR: $CLUSTER_SERVICE_CIDR"
else
    echo "Found service CIDR from cluster configuration: $CLUSTER_SERVICE_CIDR"
fi

# Calculate DNS IP if not specified (typically 10th address in service CIDR)
if [ -z "$DNS_SERVICE_IP" ]; then
    # Extract base IP from CIDR
    BASE_IP=$(echo $CLUSTER_SERVICE_CIDR | cut -d '/' -f1)
    
    # Split the IP address into octets
    IFS='.' read -r -a IP_OCTETS <<< "$BASE_IP"
    
    # Set DNS IP to x.x.0.10 where x.x is from the base service CIDR
    DNS_SERVICE_IP="${IP_OCTETS[0]}.${IP_OCTETS[1]}.0.10"
    echo "Calculated DNS service IP: $DNS_SERVICE_IP"
fi

echo "Using DNS Service IP: $DNS_SERVICE_IP"

cat > $MANIFEST_DIR/coredns-service.yaml << EOF
apiVersion: v1
kind: Service
metadata:
  name: kube-dns
  namespace: kube-system
  annotations:
    prometheus.io/port: "9153"
    prometheus.io/scrape: "true"
  labels:
    k8s-app: kube-dns
    kubernetes.io/cluster-service: "true"
    kubernetes.io/name: "CoreDNS"
spec:
  selector:
    k8s-app: kube-dns
  clusterIP: ${DNS_SERVICE_IP}
  ports:
  - name: dns
    port: 53
    targetPort: 9053
    protocol: UDP
  - name: dns-tcp
    port: 53
    targetPort: 9053
    protocol: TCP
  - name: metrics
    port: 9153
    protocol: TCP
EOF

kubectl apply -f $MANIFEST_DIR/coredns-service.yaml
check_status "CoreDNS service creation"

# Step 3: Create CoreDNS deployment with 3 replicas and hostNetwork if needed
echo "Creating CoreDNS deployment..."

# Prepare the deployment YAML, conditionally setting hostNetwork
if [ "$USE_HOST_NETWORK" = true ]; then
    echo "Enabling hostNetwork mode for CoreDNS pods"
    HOST_NETWORK_LINE="      hostNetwork: true"
else
    HOST_NETWORK_LINE=""
fi

cat > $MANIFEST_DIR/coredns-deployment.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: coredns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
    kubernetes.io/cluster-service: "true"
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  selector:
    matchLabels:
      k8s-app: kube-dns
  template:
    metadata:
      labels:
        k8s-app: kube-dns
    spec:
      priorityClassName: system-cluster-critical
      serviceAccountName: coredns
${HOST_NETWORK_LINE}
      tolerations:
      - key: "CriticalAddonsOnly"
        operator: "Exists"
      - key: "node-role.kubernetes.io/control-plane"
        operator: "Exists"
        effect: "NoSchedule"
      - key: "node-role.kubernetes.io/master"
        operator: "Exists"
        effect: "NoSchedule"
      - key: "node.kubernetes.io/not-ready"
        operator: "Exists"
        effect: "NoSchedule"
      - key: "node.kubernetes.io/unreachable"
        operator: "Exists"
        effect: "NoSchedule"
      # Providing universal tolerance for better multi-cloud scheduling
      - operator: "Exists"
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            k8s-app: kube-dns
      containers:
      - name: coredns
        image: ${COREDNS_IMAGE}
        imagePullPolicy: IfNotPresent
        resources:
          limits:
            memory: 170Mi
          requests:
            cpu: 100m
            memory: 70Mi
        args: [ "-conf", "/etc/coredns/Corefile" ]
        volumeMounts:
        - name: config-volume
          mountPath: /etc/coredns
          readOnly: true
        ports:
        - containerPort: 53
          name: dns
          protocol: UDP
        - containerPort: 53
          name: dns-tcp
          protocol: TCP
        - containerPort: 9153
          name: metrics
          protocol: TCP
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            add:
            - NET_BIND_SERVICE
            drop:
            - all
          readOnlyRootFilesystem: true
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
            scheme: HTTP
          initialDelaySeconds: 60
          timeoutSeconds: 5
          successThreshold: 1
          failureThreshold: 5
        readinessProbe:
          httpGet:
            path: /ready
            port: 8181
            scheme: HTTP
          initialDelaySeconds: 10
          timeoutSeconds: 5
          successThreshold: 1
          failureThreshold: 3
      dnsPolicy: Default
      volumes:
      - name: config-volume
        configMap:
          name: coredns
          items:
          - key: Corefile
            path: Corefile
EOF

kubectl apply -f $MANIFEST_DIR/coredns-deployment.yaml
check_status "CoreDNS deployment creation"

# ============================================================================
# STEP 4: Verify DNS pod distribution and restart cluster DNS components if needed
# ============================================================================
echo "Waiting for CoreDNS pods to become ready..."
kubectl rollout status deployment/coredns -n kube-system --timeout=120s || true

# If the rollout isn't successful after 120s, try some diagnostic fixes
DNS_RUNNING_PODS=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --field-selector=status.phase=Running --no-headers | wc -l)
if [[ "$DNS_RUNNING_PODS" -lt 3 ]]; then
    echo "⚠️ Not all CoreDNS pods are running (Only $DNS_RUNNING_PODS out of 3). Trying to recover..."
    
    # Check pod status for more information
    kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide
    
    # Get detailed information about any non-running pods
    NON_RUNNING_PODS=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --field-selector=status.phase!=Running -o name)
    for POD in $NON_RUNNING_PODS; do
        echo "Checking pod $POD status:"
        kubectl describe $POD -n kube-system | grep -A 10 "Events:"
    done
    
    # Try removing the topology constraints if pods aren't scheduling
    echo "Removing topology spread constraints to allow better pod distribution..."
    kubectl patch deployment coredns -n kube-system --type=json -p='[{"op":"remove", "path":"/spec/template/spec/topologySpreadConstraints"}]'
    
    # Add universal tolerations to ensure pods can schedule on any node
    echo "Adding universal tolerations to ensure pods can schedule anywhere..."
    kubectl patch deployment coredns -n kube-system --type=json -p='[{"op":"add", "path":"/spec/template/spec/tolerations/-", "value":{"operator":"Exists"}}]'
    
    # Wait for recovery
    echo "Waiting for CoreDNS pods to recover..."
    kubectl rollout status deployment/coredns -n kube-system --timeout=60s || true
fi

# Show current CoreDNS pod status
echo "Current CoreDNS pod status:"
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide

# ============================================================================
# STEP 5: Verify DNS functionality with rigorous testing
# ============================================================================

# Test DNS resolution using a test pod
echo "Creating test pod for DNS verification..."
cat > $MANIFEST_DIR/dns-test-pod.yaml << EOF
apiVersion: v1
kind: Pod
metadata:
  name: dns-test
  namespace: default
spec:
  tolerations:
  - operator: "Exists"
  containers:
  - name: dns-test
    image: alpine:latest
    command:
      - sleep
      - "3600"
  terminationGracePeriodSeconds: 5
EOF

# Remove any existing test pod
kubectl delete pod dns-test --force --grace-period=0 --ignore-not-found=true
sleep 5

# Create new test pod
kubectl apply -f $MANIFEST_DIR/dns-test-pod.yaml
check_status "DNS test pod creation"

# Wait for the test pod to be running
echo "Waiting for DNS test pod to be ready..."
for i in $(seq 1 15); do
    if kubectl get pod dns-test | grep -q Running; then
        echo "✅ DNS test pod is now running"
        break
    fi
    echo "Waiting for DNS test pod to start... ($i/15)"
    sleep 5
    if [ $i -eq 15 ]; then
        echo "⚠️ DNS test pod did not start in time, but will proceed with tests"
    fi
done

# Run DNS resolution tests with a longer timeout
echo "Testing DNS resolution..."
sleep 10  # Give the pod a moment to initialize its DNS settings

# Show the pod's DNS configuration
echo "DNS test pod's resolv.conf:"
kubectl exec -i dns-test -- cat /etc/resolv.conf || true

# Install dig/nslookup tools in the pod if needed
kubectl exec -i dns-test -- apk add --no-cache bind-tools || true

# Test DNS functionality several times to ensure it's stable
echo "Running complete DNS resolution tests..."
DNS_TEST_RESULT=0

# Test kubernetes service
if kubectl exec -i dns-test -- nslookup kubernetes.default > /tmp/dns-test1.log 2>&1; then
    echo "✅ DNS test successful - able to resolve kubernetes.default"
    DNS_TEST_RESULT=$((DNS_TEST_RESULT + 1))
else
    echo "❌ DNS test failed - unable to resolve kubernetes.default"
    cat /tmp/dns-test1.log
fi

# Test cluster service resolution 
if kubectl exec -i dns-test -- nslookup kube-dns.kube-system.svc.cluster.local > /tmp/dns-test2.log 2>&1; then
    echo "✅ DNS test successful - able to resolve internal service (kube-dns.kube-system)"
    DNS_TEST_RESULT=$((DNS_TEST_RESULT + 1))
else
    echo "❌ DNS test failed - unable to resolve internal service"
    cat /tmp/dns-test2.log
fi

# Test external domain
if kubectl exec -i dns-test -- nslookup google.com > /tmp/dns-test3.log 2>&1; then
    echo "✅ DNS test successful - able to resolve external domain (google.com)"
    DNS_TEST_RESULT=$((DNS_TEST_RESULT + 1))
else
    echo "❌ DNS test failed - unable to resolve external domain (google.com)"
    cat /tmp/dns-test3.log
    
    # Try an alternative external domain
    if kubectl exec -i dns-test -- nslookup cloudflare.com > /tmp/dns-test4.log 2>&1; then
        echo "✅ DNS test successful - able to resolve alternative external domain (cloudflare.com)"
        DNS_TEST_RESULT=$((DNS_TEST_RESULT + 1))
    else
        cat /tmp/dns-test4.log
    fi
fi

# If there are DNS failures, perform deeper troubleshooting
if [ $DNS_TEST_RESULT -lt 3 ]; then
    echo "==== ADVANCED DNS TROUBLESHOOTING ===="
    
    # Check if CoreDNS pods are actually handling DNS requests
    echo "Checking if CoreDNS is responding to queries directly:"
    
    # Since package installation is unreliable, use what's available in the pod
    echo "Testing DNS with built-in tools..."
    
    # Check if DNS service is reachable directly with ping
    echo "Testing direct communication to kube-dns service (10.1.0.10):"
    kubectl exec -i dns-test -- ping -c 2 10.1.0.10 || echo "Cannot ping DNS service IP"
    
    # Try checking if external DNS works directly
    echo "Testing if external DNS is reachable:"
    kubectl exec -i dns-test -- ping -c 2 1.1.1.1 || echo "Cannot ping Cloudflare DNS (1.1.1.1)"
    kubectl exec -i dns-test -- ping -c 2 8.8.8.8 || echo "Cannot ping Google DNS (8.8.8.8)"
    
    # Test if host networking works better for DNS
    echo "Creating a test pod with host network to check DNS access:"
    cat > $MANIFEST_DIR/host-dns-test.yaml << EOF
apiVersion: v1
kind: Pod
metadata:
  name: host-dns-test
  namespace: default
spec:
  hostNetwork: true
  tolerations:
  - operator: "Exists"
  containers:
  - name: dns-test
    image: busybox:latest
    command:
      - sleep
      - "600"
  terminationGracePeriodSeconds: 5
EOF
    
    kubectl apply -f $MANIFEST_DIR/host-dns-test.yaml
    
    # Wait for the pod with host networking to be ready
    for i in $(seq 1 10); do
        if kubectl get pod host-dns-test | grep -q Running; then
            echo "✅ Host network test pod is now running"
            break
        fi
        echo "Waiting for host network test pod to start... ($i/10)"
        sleep 3
    done
    
    # Test DNS resolution from host network
    echo "Testing DNS resolution from host network:"
    kubectl exec -i host-dns-test -- cat /etc/resolv.conf
    kubectl exec -i host-dns-test -- nslookup kubernetes.default || echo "Cannot resolve kubernetes.default from host network"
    kubectl exec -i host-dns-test -- nslookup google.com || echo "Cannot resolve google.com from host network"
    
    # Check if there are any networking policies interfering
    echo "Checking for NetworkPolicies that might affect DNS traffic:"
    kubectl get networkpolicies --all-namespaces || echo "No NetworkPolicies found"
    
    # Check CoreDNS endpoints
    echo "Checking CoreDNS service endpoints:"
    kubectl get endpoints kube-dns -n kube-system -o yaml
    
    # Check kube-proxy status
    echo "Checking kube-proxy status for DNS service IP handling:"
    kubectl get pods -n kube-system -l k8s-app=kube-proxy -o wide
    
    # Attempt to fix common issues
    echo "Attempting to fix common DNS issues..."
    
    # Restart kube-proxy to refresh DNS service routing
    echo "Restarting kube-proxy pods to refresh iptables rules:"
    kubectl delete pods -n kube-system -l k8s-app=kube-proxy
    
    # Wait for kube-proxy to restart
    echo "Waiting for kube-proxy pods to restart..."
    sleep 10
    kubectl get pods -n kube-system -l k8s-app=kube-proxy
    
    # Modify CoreDNS configuration to use more reliable resolvers
    echo "Updating CoreDNS configuration to use more reliable upstream resolvers..."
    
    # Update CoreDNS configmap with improved forward configuration
    cat > $MANIFEST_DIR/improved-coredns-configmap.yaml << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
data:
  Corefile: |
    .:53 {
        errors
        health {
            lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
            pods insecure
            fallthrough in-addr.arpa ip6.arpa
        }
        prometheus :9153
        forward . 1.1.1.1 8.8.8.8 {
            prefer_udp
        }
        cache 30
        loop
        reload
        loadbalance
    }
EOF
    
    kubectl apply -f $MANIFEST_DIR/improved-coredns-configmap.yaml
    
    # Restart CoreDNS with simplified configuration
    echo "Restarting CoreDNS with optimized configuration..."
    kubectl rollout restart deployment coredns -n kube-system
    kubectl rollout status deployment coredns -n kube-system --timeout=60s
    
    # Create a test pod with a simple DNS policy
    echo "Creating a clean test pod with basic configuration..."
    kubectl delete pod dns-test --force --grace-period=0 --ignore-not-found=true
    kubectl delete pod host-dns-test --force --grace-period=0 --ignore-not-found=true
    
    cat > $MANIFEST_DIR/final-dns-test.yaml << EOF
apiVersion: v1
kind: Pod
metadata:
  name: dns-test
  namespace: default
spec:
  containers:
  - name: dns-test
    image: busybox:latest
    command:
      - sleep
      - "3600"
EOF
    
    kubectl apply -f $MANIFEST_DIR/final-dns-test.yaml
    
    # Wait for the test pod to be running
    echo "Waiting for final DNS test pod to be ready..."
    for i in $(seq 1 10); do
        if kubectl get pod dns-test | grep -q Running; then
            echo "✅ Final DNS test pod is now running"
            break
        fi
        echo "Waiting for DNS test pod to start... ($i/10)"
        sleep 3
    done
    
    # Final DNS test
    echo "Performing final DNS test..."
    sleep 5
    
    # Show the pod's DNS configuration
    echo "DNS test pod's resolv.conf:"
    kubectl exec -i dns-test -- cat /etc/resolv.conf || true
    
    # Try resolving kubernetes service again
    if kubectl exec -i dns-test -- nslookup kubernetes.default; then
        echo "✅ DNS resolution NOW WORKING with new configuration"
    else
        echo "❌ DNS resolution STILL FAILING after configuration updates"
        
        echo "Final emergency fix - patching CoreDNS deployment to use host network:"
        # Fix the patch syntax - this was causing the error in your original run
        kubectl patch deployment coredns -n kube-system --type=json -p='[{"op":"add", "path":"/spec/template/spec/hostNetwork", "value":true}]'
        sleep 15
        
        # Restart CoreDNS pods to ensure they pick up the host network setting
        kubectl rollout restart deployment coredns -n kube-system
        kubectl rollout status deployment coredns -n kube-system --timeout=60s
        
        echo "Testing one more time with CoreDNS on host network:"
        kubectl exec -i dns-test -- nslookup kubernetes.default || echo "Still failing after host network change"
        
        # If we're still failing, try creating a NodePort service as last resort
        if ! kubectl exec -i dns-test -- nslookup kubernetes.default > /dev/null 2>&1; then
            echo "Creating a NodePort service for DNS as last resort..."
            cat > $MANIFEST_DIR/coredns-nodeport.yaml << EOF
apiVersion: v1
kind: Service
metadata:
  name: coredns-nodeport
  namespace: kube-system
  labels:
    k8s-app: kube-dns-nodeport
spec:
  selector:
    k8s-app: kube-dns
  type: NodePort
  ports:
  - name: dns
    port: 53
    targetPort: 53
    protocol: UDP
    nodePort: 31053
  - name: dns-tcp
    port: 53
    targetPort: 53
    protocol: TCP
    nodePort: 31054
EOF
            kubectl apply -f $MANIFEST_DIR/coredns-nodeport.yaml
            
            # Update node resolv.conf to use the NodePort
            echo "Updating test pod to use NodePort for DNS..."
            NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}')
            
            # Create test pod with custom DNS
            cat > $MANIFEST_DIR/nodeport-dns-test.yaml << EOF
apiVersion: v1
kind: Pod
metadata:
  name: nodeport-dns-test
spec:
  containers:
  - name: dns-test
    image: busybox:latest
    command:
      - sleep
      - "3600"
    env:
    - name: NAMESERVER
      value: "${NODE_IP}:31053"
EOF
            kubectl apply -f $MANIFEST_DIR/nodeport-dns-test.yaml
            
            echo "Waiting for NodePort DNS test pod..."
            sleep 15
            
            echo "Testing NodePort-based DNS resolution:"
            kubectl exec -i nodeport-dns-test -- nslookup kubernetes.default "${NODE_IP}:31053" || \
              echo "NodePort DNS test failed too. Manual intervention required."
        fi
    fi
    
    # Clean up test pods
    kubectl delete pod host-dns-test --force --grace-period=0 --ignore-not-found=true
fi

# Show resolv.conf of a node for comparison
echo "Checking host DNS configuration for reference:"
cat /etc/resolv.conf | grep -v '^#'

# Clean up test pod and temporary files
echo "Cleaning up test resources..."
kubectl delete pod dns-test --force --grace-period=0 --ignore-not-found=true
rm -rf $MANIFEST_DIR
rm -f /tmp/dns-test*.log

echo "======================================================================"
echo "CoreDNS setup complete! Current status:"
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide
echo ""
kubectl get service -n kube-system -l k8s-app=kube-dns
echo ""

echo "Node status after DNS setup:"
kubectl get nodes -o custom-columns=NAME:.metadata.name,INTERNAL-IP:.status.addresses[0].address,STATUS:.status.conditions[-1].type
echo ""

if [ $DNS_TEST_RESULT -ge 2 ]; then
    echo "✅ CoreDNS is now functioning correctly for basic DNS resolution!"
    if [ $DNS_TEST_RESULT -lt 3 ]; then
        echo "⚠️ Internal DNS works but external DNS resolution had issues."
        echo "   This may indicate network connectivity problems to external DNS servers."
    fi
else
    echo "⚠️ CoreDNS setup completed but DNS tests failed. Further debugging may be needed."
    echo ""
    echo "Troubleshooting tips:"
    echo "1. Check if CoreDNS pods are running:"
    echo "   kubectl get pods -n kube-system -l k8s-app=kube-dns"
    echo ""
    echo "2. Check CoreDNS logs:"
    echo "   kubectl logs -n kube-system -l k8s-app=kube-dns"
    echo ""
    echo "3. Verify kube-dns service has the correct cluster IP:"
    echo "   kubectl get svc -n kube-system kube-dns"
    echo ""
    echo "4. Check if CNI is working properly (pods can communicate):"
    echo "   Run: ${SCRIPT_DIR}/003-CNI_Troubleshooting.sh"
fi
echo "======================================================================"
