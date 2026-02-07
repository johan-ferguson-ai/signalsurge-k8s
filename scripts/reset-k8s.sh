#!/bin/bash
# =============================================================================
# reset-k8s.sh
# Run this on the server to tear down everything install-k8s.sh created.
# After running this, install-k8s.sh can be re-run from scratch.
#
# Usage: sudo ./reset-k8s.sh
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}This script must be run as root (use sudo)${NC}"
    exit 1
fi

echo ""
echo "============================================"
echo -e "${RED} FULL K8s RESET${NC}"
echo " This will destroy the cluster and remove"
echo " all Kubernetes + containerd packages."
echo "============================================"
echo ""
read -p "Are you sure? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

log_step() {
    echo ""
    echo -e "${CYAN}[$1/7] $2${NC}"
}

log_ok() {
    echo -e "${GREEN}  ✓ $1${NC}"
}

# -------------------------------------------------------
# Step 1: Reset kubeadm
# -------------------------------------------------------
log_step 1 "Resetting kubeadm cluster"

if command -v kubeadm &>/dev/null; then
    kubeadm reset -f 2>/dev/null || true
    log_ok "kubeadm reset complete"
else
    echo "  kubeadm not found, skipping"
fi

# -------------------------------------------------------
# Step 2: Remove K8s packages
# -------------------------------------------------------
log_step 2 "Removing Kubernetes packages"

apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
apt-get purge -y kubelet kubeadm kubectl 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true
log_ok "Removed kubelet, kubeadm, kubectl"

rm -f /etc/apt/sources.list.d/kubernetes.list
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
log_ok "Removed K8s apt repo and keyring"

# -------------------------------------------------------
# Step 3: Remove containerd
# -------------------------------------------------------
log_step 3 "Removing containerd"

systemctl stop containerd 2>/dev/null || true
apt-get purge -y containerd.io 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true
log_ok "Removed containerd.io"

rm -f /etc/apt/sources.list.d/docker.list
rm -f /etc/apt/keyrings/docker.gpg
log_ok "Removed Docker apt repo and keyring"

# -------------------------------------------------------
# Step 4: Clean up config and data directories
# -------------------------------------------------------
log_step 4 "Cleaning up config and data"

rm -rf /etc/containerd
rm -rf /etc/kubernetes
rm -rf /var/lib/kubelet
rm -rf /var/lib/etcd
rm -rf /var/lib/containerd
rm -rf /var/run/kubernetes
rm -rf /etc/cni/net.d
rm -rf /opt/cni
rm -rf /var/lib/cni
rm -rf /run/flannel
log_ok "Removed K8s and containerd data directories"

rm -rf /root/.kube
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    USER_HOME=$(eval echo "~${SUDO_USER}")
    rm -rf "${USER_HOME}/.kube"
    log_ok "Removed ${USER_HOME}/.kube"
fi
log_ok "Removed kubeconfig files"

# -------------------------------------------------------
# Step 5: Clean up network
# -------------------------------------------------------
log_step 5 "Cleaning up network interfaces"

ip link delete cni0 2>/dev/null || true
ip link delete flannel.1 2>/dev/null || true
ip link delete kube-bridge 2>/dev/null || true
log_ok "Removed CNI network interfaces"

# Flush iptables rules added by kube-proxy/flannel
iptables -F 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -X 2>/dev/null || true
log_ok "Flushed iptables rules"

# -------------------------------------------------------
# Step 6: Remove sysctl and module configs (leave swap as-is)
# -------------------------------------------------------
log_step 6 "Removing kernel configs"

rm -f /etc/sysctl.d/k8s.conf
rm -f /etc/modules-load.d/k8s.conf
sysctl --system > /dev/null 2>&1
log_ok "Removed k8s sysctl and module-load configs"

# -------------------------------------------------------
# Step 7: Update apt cache
# -------------------------------------------------------
log_step 7 "Updating apt cache"

apt-get update -qq 2>/dev/null || true
log_ok "apt cache updated"

echo ""
echo "============================================"
echo -e "${GREEN} RESET COMPLETE${NC}"
echo "============================================"
echo ""
echo "The system is clean. You can now re-run:"
echo "  ./install-k8s.sh --registry-port 30500"
echo ""
