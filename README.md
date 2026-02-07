# signalsurge-k8s

Single-command Kubernetes installer for on-prem servers. Takes a bare Ubuntu/Debian machine to a fully configured single-node K8s cluster with container registry, KEDA, and CI/CD service account.

## Install

```bash
echo "deb [trusted=yes] https://johan-ferguson-ai.github.io/signalsurge-k8s ./" | sudo tee /etc/apt/sources.list.d/signalsurge.list
sudo apt update
sudo apt install signalsurge-k8s
```

## Usage

```bash
# Install K8s cluster + registry + CI setup
sudo install-k8s --registry-port 30500

# Tear down everything for a clean re-install
sudo reset-k8s
```

## What `install-k8s` does

1. Preflight checks (root, OS, CPU, RAM, ports)
2. System prep (swap, kernel modules, sysctl)
3. Install containerd from Docker apt repo
4. Install kubeadm, kubelet, kubectl (latest)
5. Init cluster (kubeadm init)
6. Install Flannel CNI
7. Wait for node Ready
8. Install local-path-provisioner StorageClass
9. Install KEDA (pod monitoring + horizontal autoscaling)
10. Deploy registry:2 with PVC persistence
11. Configure containerd for insecure registry access
12. Create CI ServiceAccount + token
13. Output token, kubeconfig + generate `provision-remote.sh`

## Requirements

- Ubuntu or Debian (any recent release)
- 2+ CPUs, 2+ GB RAM
- Root access

## After install

Copy the generated `provision-remote.sh` to your local machine:

```bash
scp root@<server>:/usr/local/bin/provision-remote.sh .
./provision-remote.sh --project my-service
```

This sets the Gitea secrets automatically — no tokens or passwords to copy.
