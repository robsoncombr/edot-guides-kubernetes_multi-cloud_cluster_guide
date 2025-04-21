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
# USAGE:
#   ./002-DNS_Setup.sh
#
# NOTES:
#   - Run this script on the control plane node after CNI setup
#   - Helps ensure DNS resolution works across all nodes in multi-cloud setup
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

# Create a temporary directory for manifests
MANIFEST_DIR="/tmp/coredns-manifests"
mkdir -p $MANIFEST_DIR

# Check current CoreDNS status
echo "Checking current CoreDNS status..."
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide
echo ""

# Get CoreDNS version and image
echo "Getting CoreDNS details..."
COREDNS_IMAGE=$(kubectl -n kube-system get deployment coredns -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "registry.k8s.io/coredns/coredns:v1.10.1")
echo "Current CoreDNS image: $COREDNS_IMAGE"

# Check the service account
echo "Checking CoreDNS service account..."
if ! kubectl -n kube-system get serviceaccount coredns > /dev/null 2>&1; then
    echo "Creating CoreDNS service account..."
    kubectl -n kube-system create serviceaccount coredns
fi

# Step 1: Create/update the CoreDNS ConfigMap
echo "Creating CoreDNS ConfigMap..."
cat > $MANIFEST_DIR/coredns-configmap.yaml << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
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
        forward . /etc/resolv.conf
        cache 30
        loop
        reload
        loadbalance
    }
EOF

kubectl apply -f $MANIFEST_DIR/coredns-configmap.yaml
check_status "CoreDNS ConfigMap creation"

# Step 2: Create/update CoreDNS deployment
echo "Creating CoreDNS deployment..."

cat > $MANIFEST_DIR/coredns-deployment.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: coredns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
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
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: kubernetes.io/hostname
                operator: In
                values:
                - k8s-01-oci-01
                - k8s-02-oci-02
      tolerations:
        - key: CriticalAddonsOnly
          operator: Exists
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
        - key: node-role.kubernetes.io/master
          operator: Exists
          effect: NoSchedule
        - key: "node.kubernetes.io/not-ready"
          operator: "Exists"
        - key: "node.kubernetes.io/unreachable"
          operator: "Exists"
      nodeSelector:
        kubernetes.io/os: linux
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
      volumes:
      - name: config-volume
        configMap:
          name: coredns
          items:
          - key: Corefile
            path: Corefile
      dnsPolicy: Default
EOF

kubectl apply -f $MANIFEST_DIR/coredns-deployment.yaml
check_status "CoreDNS deployment creation"

# Step 3: Ensure CoreDNS service is configured correctly
echo "Ensuring CoreDNS service is configured correctly..."

cat > $MANIFEST_DIR/coredns-service.yaml << EOF
apiVersion: v1
kind: Service
metadata:
  name: kube-dns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
    kubernetes.io/name: "CoreDNS"
spec:
  selector:
    k8s-app: kube-dns
  clusterIP: ${DNS_SERVICE_IP:-"10.1.0.10"}
  ports:
  - name: dns
    port: 53
    protocol: UDP
  - name: dns-tcp
    port: 53
    protocol: TCP
  - name: metrics
    port: 9153
    protocol: TCP
EOF

kubectl apply -f $MANIFEST_DIR/coredns-service.yaml
check_status "CoreDNS service creation"

# Wait for CoreDNS pods to be running
echo "Waiting for CoreDNS pods to become ready..."
kubectl rollout status deployment/coredns -n kube-system --timeout=120s || true

# Verify DNS pods are running
echo "Current CoreDNS pod status:"
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide

# Test DNS resolution using a test pod
echo "Creating test pod for DNS verification..."
cat > $MANIFEST_DIR/dns-test-pod.yaml << EOF
apiVersion: v1
kind: Pod
metadata:
  name: dns-test
  namespace: default
spec:
  containers:
  - name: dns-test
    image: busybox:1.28
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

# Run DNS resolution tests
echo "Testing DNS resolution..."
sleep 5  # Give the pod a moment to initialize

# Test kubernetes service
DNS_TEST_RESULT=0
if kubectl exec -i dns-test -- nslookup kubernetes.default > /dev/null 2>&1; then
    echo "✅ DNS test successful - able to resolve kubernetes.default"
    DNS_TEST_RESULT=1
else
    echo "❌ DNS test failed - unable to resolve kubernetes.default"
fi

# Test external domain
if kubectl exec -i dns-test -- nslookup google.com > /dev/null 2>&1; then
    echo "✅ DNS test successful - able to resolve external domain (google.com)"
    DNS_TEST_RESULT=$((DNS_TEST_RESULT + 1))
else
    echo "❌ DNS test failed - unable to resolve external domain (google.com)"
fi

# Clean up test pod and temporary files
echo "Cleaning up test resources..."
kubectl delete pod dns-test --force --grace-period=0 --ignore-not-found=true
rm -rf $MANIFEST_DIR

echo "======================================================================"
echo "CoreDNS setup complete! Current status:"
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide
echo ""
kubectl get service -n kube-system -l k8s-app=kube-dns
echo ""

echo "Node status after DNS setup:"
kubectl get nodes -o custom-columns=NAME:.metadata.name,INTERNAL-IP:.status.addresses[0].address,STATUS:.status.conditions[-1].type
echo ""

if [ $DNS_TEST_RESULT -ge 1 ]; then
    echo "✅ CoreDNS is now functioning correctly for basic DNS resolution!"
else
    echo "⚠️ CoreDNS setup completed but DNS tests failed. Further debugging may be needed."
fi
echo "======================================================================"
