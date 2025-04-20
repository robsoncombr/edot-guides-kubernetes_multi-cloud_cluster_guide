#!/bin/bash
echo "====================================================================="
echo "Complete worker node reset and rejoin"
echo "====================================================================="

# Define worker nodes
WORKER_NODES=("k8s-02-oci-02:172.16.0.2" "k8s-03-htg-01:172.16.0.3")

# Reset each worker node
for node in "${WORKER_NODES[@]}"; do
    node_name=$(echo $node | cut -d: -f1)
    node_ip=$(echo $node | cut -d: -f2)
    
    echo "-------------------------------------------------------------------"
    echo "Resetting node $node_name ($node_ip)"
    
    # Remove node from cluster first
    kubectl delete node $node_name || true
    
    # Reset kubeadm on the worker node
    ssh -o StrictHostKeyChecking=no root@${node_ip} "kubeadm reset -f && \
        rm -rf /etc/cni/net.d/* && \
        ip link delete flannel.1 || true && \
        ip link delete cni0 || true && \
        systemctl stop kubelet && \
        systemctl daemon-reload"
    
    echo "Node $node_name reset completed"
done

# Generate a new join token
echo "-------------------------------------------------------------------"
echo "Generating new join token..."
JOIN_CMD=$(kubeadm token create --print-join-command)
echo "Join command: $JOIN_CMD"

# Join each worker node back to the cluster
for node in "${WORKER_NODES[@]}"; do
    node_name=$(echo $node | cut -d: -f1)
    node_ip=$(echo $node | cut -d: -f2)
    
    # Extract node number from name
    if [[ $node_name =~ k8s-([0-9]+) ]]; then
        NODE_NUM=${BASH_REMATCH[1]}
        # Remove any leading zeros
        NODE_NUM=$(echo $NODE_NUM | sed 's/^0*//')
    else
        echo "Error: Could not extract node number from $node_name"
        continue
    fi
    
    # Correct Pod CIDR for this node
    POD_CIDR="10.10.${NODE_NUM}.0/24"
    
    echo "-------------------------------------------------------------------"
    echo "Rejoining node $node_name ($node_ip) with CIDR $POD_CIDR"
    
    # Set up node IP configuration first
    ssh -o StrictHostKeyChecking=no root@${node_ip} "echo 'KUBELET_EXTRA_ARGS=\"--node-ip=${node_ip} --cluster-dns=10.1.0.10\"' > /etc/default/kubelet"
    
    # Set up Flannel subnet configuration
    ssh -o StrictHostKeyChecking=no root@${node_ip} "mkdir -p /run/flannel && \
        echo 'FLANNEL_NETWORK=10.10.0.0/16' > /run/flannel/subnet.env && \
        echo 'FLANNEL_SUBNET=${POD_CIDR}' >> /run/flannel/subnet.env && \
        echo 'FLANNEL_MTU=1450' >> /run/flannel/subnet.env && \
        echo 'FLANNEL_IPMASQ=true' >> /run/flannel/subnet.env"
    
    # Join the node to the cluster
    ssh -o StrictHostKeyChecking=no root@${node_ip} "$JOIN_CMD"
    
    echo "Node $node_name joined to the cluster"
    
    # Patch the node with the correct CIDR on the control plane
    echo "Patching node $node_name with CIDR $POD_CIDR"
    kubectl patch node $node_name -p '{"spec":{"podCIDR":"'$POD_CIDR'","podCIDRs":["'$POD_CIDR'"]}}' || true
done

echo "====================================================================="
echo "Node reset and rejoin process completed"
echo "Checking node status in 30 seconds..."
sleep 30
kubectl get nodes -o wide
echo "====================================================================="
