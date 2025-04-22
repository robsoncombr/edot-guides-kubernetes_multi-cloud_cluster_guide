#!/bin/bash

# Script to implement NodeLocal DNSCache for reliable DNS in multi-cloud Kubernetes
echo "========================================================================"
echo "Setting up NodeLocal DNSCache for reliable DNS resolution"
echo "========================================================================"

# Create a manifest directory
MANIFEST_DIR="/tmp/dns-fix"
mkdir -p $MANIFEST_DIR

# Update CoreDNS configuration to work better with NodeLocal DNSCache
cat > $MANIFEST_DIR/coredns-configmap.yaml << 'EOFCM'
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
        forward . 8.8.8.8 1.1.1.1 {
            max_concurrent 1000
            prefer_udp
        }
        cache 30
        loop
        reload
        loadbalance
    }
EOFCM

kubectl apply -f $MANIFEST_DIR/coredns-configmap.yaml

# Wait for configmap to apply
sleep 5

# Create NodeLocal DNSCache DaemonSet
cat > $MANIFEST_DIR/nodelocaldns.yaml << 'EOFNL'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: node-local-dns
  namespace: kube-system
  labels:
    kubernetes.io/cluster-service: "true"
    addonmanager.kubernetes.io/mode: Reconcile
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: node-local-dns
  namespace: kube-system
data:
  Corefile: |
    cluster.local:53 {
        errors
        cache {
            success 9984 30
            denial 9984 5
        }
        reload
        loop
        bind 169.254.20.10
        forward . 10.1.0.10 {
            force_tcp
        }
        prometheus :9253
        health 169.254.20.10:9254
    }
    in-addr.arpa:53 {
        errors
        cache 30
        reload
        loop
        bind 169.254.20.10
        forward . 10.1.0.10 {
            force_tcp
        }
        prometheus :9253
    }
    ip6.arpa:53 {
        errors
        cache 30
        reload
        loop
        bind 169.254.20.10
        forward . 10.1.0.10 {
            force_tcp
        }
        prometheus :9253
    }
    .:53 {
        errors
        cache 30
        reload
        loop
        bind 169.254.20.10
        forward . 8.8.8.8 1.1.1.1 {
            max_concurrent 1000
        }
        prometheus :9253
        health 169.254.20.10:9254
    }
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-local-dns
  namespace: kube-system
  labels:
    k8s-app: node-local-dns
spec:
  updateStrategy:
    rollingUpdate:
      maxUnavailable: 10%
  selector:
    matchLabels:
      k8s-app: node-local-dns
  template:
    metadata:
      labels:
        k8s-app: node-local-dns
      annotations:
        prometheus.io/port: "9253"
        prometheus.io/scrape: "true"
    spec:
      priorityClassName: system-node-critical
      serviceAccountName: node-local-dns
      hostNetwork: true
      dnsPolicy: Default
      tolerations:
      - key: "CriticalAddonsOnly"
        operator: "Exists"
      - effect: "NoExecute"
        operator: "Exists"
      - effect: "NoSchedule"
        operator: "Exists"
      containers:
      - name: node-cache
        image: registry.k8s.io/dns/k8s-dns-node-cache:1.22.27
        resources:
          limits:
            memory: 170Mi
          requests:
            cpu: 100m
            memory: 70Mi
        args: [ "-localip", "169.254.20.10", "-conf", "/etc/Corefile", "-upstreamsvc", "kube-dns" ]
        securityContext:
          privileged: true
        ports:
        - containerPort: 53
          name: dns
          protocol: UDP
        - containerPort: 53
          name: dns-tcp
          protocol: TCP
        - containerPort: 9253
          name: metrics
          protocol: TCP
        livenessProbe:
          httpGet:
            host: 169.254.20.10
            path: /health
            port: 9254
          initialDelaySeconds: 60
          timeoutSeconds: 5
        volumeMounts:
        - mountPath: /run/xtables.lock
          name: xtables-lock
          readOnly: false
        - name: config-volume
          mountPath: /etc/Corefile
          subPath: Corefile
      volumes:
      - name: xtables-lock
        hostPath:
          path: /run/xtables.lock
          type: FileOrCreate
      - name: config-volume
        configMap:
          name: node-local-dns
          items:
          - key: Corefile
            path: Corefile
EOFNL

kubectl apply -f $MANIFEST_DIR/nodelocaldns.yaml

# Wait for the daemonset to start
echo "Waiting for NodeLocal DNSCache pods to start..."
sleep 10

# Update kubelet configuration to use NodeLocal DNSCache
echo "Updating kubelet configuration on all nodes..."

# Function to update kubelet config on a node
update_kubelet_config() {
  local NODE=$1
  local CONFIG_FILE="/var/lib/kubelet/config.yaml"
  
  if [ "$NODE" == "$(hostname)" ]; then
    # Local node
    if grep -q "clusterDNS:" $CONFIG_FILE; then
      # Update existing clusterDNS entry
      sed -i 's/clusterDNS:.*/clusterDNS: ["169.254.20.10"]/' $CONFIG_FILE
    else
      # Add clusterDNS entry
      sed -i '/kind: KubeletConfiguration/a clusterDNS: ["169.254.20.10"]' $CONFIG_FILE
    fi
    
    # Restart kubelet
    systemctl restart kubelet
    echo "✅ Updated kubelet on $NODE (local)"
  else
    # Remote node
    ssh $NODE "if grep -q 'clusterDNS:' $CONFIG_FILE; then \
      sed -i 's/clusterDNS:.*/clusterDNS: [\"169.254.20.10\"]/' $CONFIG_FILE; \
    else \
      sed -i '/kind: KubeletConfiguration/a clusterDNS: [\"169.254.20.10\"]' $CONFIG_FILE; \
    fi && \
    systemctl restart kubelet && \
    echo '✅ Updated kubelet on $NODE (remote)'" || echo "❌ Failed to update kubelet on $NODE"
  fi
}

# Get all nodes
NODES=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')

# Update each node
for NODE in $NODES; do
  echo "Updating $NODE..."
  update_kubelet_config $NODE
done

# Create a test pod for DNS verification
echo "Creating test pod to verify NodeLocal DNSCache..."
cat > $MANIFEST_DIR/dns-test.yaml << 'EOFTEST'
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
EOFTEST

# Remove any existing test pod
kubectl delete pod dns-test --force --grace-period=0 --ignore-not-found=true
sleep 5

# Create new test pod
kubectl apply -f $MANIFEST_DIR/dns-test.yaml

# Wait for the test pod to be running
echo "Waiting for DNS test pod to be ready..."
for i in $(seq 1 15); do
    if kubectl get pod dns-test | grep -q Running; then
        echo "✅ DNS test pod is now running"
        break
    fi
    echo "Waiting for DNS test pod to start... ($i/15)"
    sleep 5
done

# Test DNS resolution
echo "Testing DNS resolution with NodeLocal DNSCache..."
sleep 10  # Give the pod some time to initialize

# Show the pod's DNS configuration
echo "DNS test pod's resolv.conf:"
kubectl exec -i dns-test -- cat /etc/resolv.conf || true

# Test various DNS lookups
echo "Testing kubernetes.default resolution:"
kubectl exec -i dns-test -- nslookup kubernetes.default || echo "Failed to resolve kubernetes.default"

echo "Testing external domain resolution:"
kubectl exec -i dns-test -- nslookup google.com || echo "Failed to resolve google.com"

echo "========================================================================"
echo "NodeLocal DNSCache setup complete!"
echo "DNS resolution should now be more reliable in your multi-cloud cluster."
echo "========================================================================"
