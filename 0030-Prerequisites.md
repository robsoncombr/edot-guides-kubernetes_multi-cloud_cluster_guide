# Prerequisites

## Not included in this guide

- 3 VPS instances with Ubuntu 24.04, fully upgraded and ready
  - The specific cloud provider is not relevant to this guide
  - Only hardware configuration (CPU, RAM, Storage - refer to [Kubernetes's Official Documentation](https://kubernetes.io/docs/)), Hostnames (for node names), and VPN IPs are relevant
- VPN will be configured using [WireGuard](https://www.wireguard.com/) with network 172.16.0.0/16
  - Control plane: 172.16.0.1
  - Worker node 1: 172.16.0.2
  - Worker node 2: 172.16.0.3
  - All inter-node communication must occur through the VPN
- [Docker CE](https://docs.docker.com/engine/install/ubuntu/) installed and operational (followed APT method)
  - Kubernetes will be configured to use Docker's container service
  - Docker daemon file needs configuration to work properly with Kubernetes
  - Ability to run Docker containers in parallel with Kubernetes

## Tools and Third-Party Software

### All dependencies are preferably to be Fully Open-Source and Free Commercially Licensed

### Next - [Table of Contents](0040-Table_of_Contents.md)
