#!/bin/bash

# Create kubeadm configuration file
cat > /tmp/kubeadm-config.yaml << EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
nodeRegistration:
  name: k8s-01-oci-01
  kubeletExtraArgs:
    node-ip: "172.16.0.1"
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v1.32.3
networking:
  serviceSubnet: "10.1.0.0/16"
  podSubnet: "10.10.0.0/16"
controlPlaneEndpoint: "172.16.0.1:6443"
apiServer:
  certSANs:
  - "172.16.0.1"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF

# Initialize the Kubernetes control plane
echo "Initializing Kubernetes control plane..."
kubeadm init --config=/tmp/kubeadm-config.yaml --upload-certs --v=5 | tee /tmp/kubeadm-init.log

# Set up kubeconfig for the root user
echo "Setting up kubeconfig for root user..."
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# Display kubeconfig setup message
echo ""
echo "==========================================================================="
echo "kubectl configuration set up successfully for admin user!"
echo ""
echo "Testing kubectl configuration:"
echo ""
kubectl get nodes
echo ""
echo "Checking system pods:"
echo ""
kubectl get pods -n kube-system
echo ""
echo "NOTE: At this point, the control plane node will show as 'Pending' or 'NotReady'"
echo "This is expected because we haven't installed a CNI plugin yet."
echo "==========================================================================="

# Display join command for worker nodes
echo ""
echo "==========================================================================="
echo "Control plane initialization complete!"
echo ""
echo "To join other control-plane node, run the following command on that node:"
grep -B 2 "\--control-plane" /tmp/kubeadm-init.log
echo "To join worker nodes to this cluster, run the following command on each node:"
tail -n 2 /tmp/kubeadm-init.log
echo ""
echo "IMPORTANT:"
echo "- A full log of this command was saved to:"
echo "  > $(ls -ls /tmp/kubeadm-init.log)"
echo "- The log contains the join secrets, be sure you delete it or move to a safe place"
echo "- Do *not* join worker nodes until you've installed a CNI plugin (Chapter 4)"
echo "==========================================================================="

echo ""
echo "NEXT STEP:"
echo "1. Install a CNI plugin (Chapter 4) to enable networking in the cluster."
echo "2. After installing the CNI plugin, you can back (Chapter 3) to join worker nodes."
echo ""

# Clean up
rm -f /tmp/kubeadm-config.yaml
