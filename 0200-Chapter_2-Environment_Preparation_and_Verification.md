# Chapter 2: Environment Preparation and Verification

## Operating System and Hardware Requirements

- Check Ubuntu version
```bash
lsb_release -a
```

## Docker Configuration for Kubernetes Compatibility

- Validate Docker installation
```bash
docker --version
```

## WireGuard VPN Confirmation and Testing

- Check VPN IP
```bash
ip addr show | grep 172.16.0
```
---

**Next**: [Chapter 3: Kubernetes Installation and Basic Configuration](0300-Chapter_3-Kubernetes_Installation_and_Basic_Configuration.md)
