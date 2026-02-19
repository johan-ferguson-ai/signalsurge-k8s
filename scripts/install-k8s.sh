#!/bin/bash
# =============================================================================
# install-k8s.sh
# Run this on a BARE Ubuntu/Debian server to install a single-node Kubernetes
# cluster with container registry, ready for CI/CD deployments.
#
# One command, zero interaction:
#   sudo ./install-k8s.sh --registry-port 30500
#
# What it does:
#   1.  Preflight checks (root, OS, CPU, RAM, ports)
#   2.  System prep (swap, kernel modules, sysctl)
#   3.  Install containerd from Docker apt repo
#   4.  Install kubeadm, kubelet, kubectl (latest)
#   5.  Init cluster (kubeadm init)
#   6.  Install Flannel CNI
#   7.  Wait for node Ready
#   8.  Install local-path-provisioner StorageClass
#   9.  Install KEDA (pod monitoring + horizontal autoscaling)
#   10. Install metrics-server (kubectl top, HPA)
#   11. Install kube-state-metrics (pod/deployment state metrics)
#   12. Deploy registry:2 with PVC persistence
#   13. Configure containerd for insecure registry access
#   14. Create CI ServiceAccount + token
#   15. Output token, kubeconfig, ready for setup-local-config.sh
#
# Idempotent — safe to re-run. Each step checks before acting.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

REGISTRY_PORT=30500
REGISTRY_NAMESPACE="microservice-generator"
POD_CIDR="10.244.0.0/16"
SA_NAME="ci-deploy"
SA_NAMESPACE="kube-system"
SECRET_NAME="ci-deploy-token"

# =============================================================================
# Parse arguments
# =============================================================================
while [ $# -gt 0 ]; do
    case $1 in
        --registry-port=*) REGISTRY_PORT="${1#*=}" ;;
        --registry-port) shift; REGISTRY_PORT="$1" ;;
        --help|-h)
            echo "Usage: sudo $0 [--registry-port PORT]"
            echo ""
            echo "Options:"
            echo "  --registry-port PORT  NodePort for the container registry (default: 30500)"
            echo ""
            echo "Example:"
            echo "  sudo $0 --registry-port 30500"
            exit 0
            ;;
        *) echo -e "${RED}Unknown argument: $1${NC}"; exit 1 ;;
    esac
    shift
done

log_step() {
    local step=$1
    local total=$2
    local msg=$3
    echo ""
    echo -e "${CYAN}[${step}/${total}] ${msg}${NC}"
}

log_ok() {
    echo -e "${GREEN}  ✓ $1${NC}"
}

log_skip() {
    echo -e "${YELLOW}  ⊘ $1 (already done)${NC}"
}

log_warn() {
    echo -e "${YELLOW}  ⚠ $1${NC}"
}

log_err() {
    echo -e "${RED}  ✗ $1${NC}"
}

TOTAL_STEPS=15

echo ""
echo "============================================"
echo " Kubernetes Single-Node Installer"
echo " Registry NodePort: ${REGISTRY_PORT}"
echo "============================================"
echo ""

# =============================================================================
# Step 1: Preflight checks
# =============================================================================
log_step 1 $TOTAL_STEPS "Preflight checks"

# Root check
if [ "$EUID" -ne 0 ]; then
    log_err "This script must be run as root (use sudo)"
    exit 1
fi
log_ok "Running as root"

# OS check
if [ ! -f /etc/os-release ]; then
    log_err "Cannot detect OS — /etc/os-release not found"
    exit 1
fi

. /etc/os-release
case "$ID" in
    ubuntu|debian)
        log_ok "OS: ${PRETTY_NAME}"
        ;;
    *)
        log_err "Unsupported OS: ${ID}. Only Ubuntu and Debian are supported."
        exit 1
        ;;
esac

# CPU check (minimum 2)
CPU_COUNT=$(nproc)
if [ "$CPU_COUNT" -lt 2 ]; then
    log_err "Minimum 2 CPUs required (found ${CPU_COUNT})"
    exit 1
fi
log_ok "CPUs: ${CPU_COUNT}"

# RAM check (minimum 2GB = 2,000,000 KB with some tolerance)
MEM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_TOTAL_MB=$((MEM_TOTAL_KB / 1024))
if [ "$MEM_TOTAL_MB" -lt 1800 ]; then
    log_err "Minimum 2 GB RAM required (found ${MEM_TOTAL_MB} MB)"
    exit 1
fi
log_ok "RAM: ${MEM_TOTAL_MB} MB"

# Port checks
for port in 6443 10250 $REGISTRY_PORT; do
    if ss -tlnp | grep -q ":${port} "; then
        log_warn "Port ${port} is already in use (may be from a previous install)"
    fi
done
log_ok "Port checks passed"

# =============================================================================
# Step 2: System prep (swap, kernel modules, sysctl)
# =============================================================================
log_step 2 $TOTAL_STEPS "System preparation"

# Disable swap
if swapon --show | grep -q .; then
    swapoff -a
    log_ok "Swap disabled"
else
    log_skip "Swap already disabled"
fi

# Remove swap entries from fstab
if grep -qE '^\s*[^#].*\sswap\s' /etc/fstab; then
    sed -i '/\sswap\s/s/^/#/' /etc/fstab
    log_ok "Commented out swap entries in /etc/fstab"
else
    log_skip "No swap entries in /etc/fstab"
fi

# Load kernel modules
MODULES_CONF="/etc/modules-load.d/k8s.conf"
if [ ! -f "$MODULES_CONF" ]; then
    cat > "$MODULES_CONF" <<EOF
overlay
br_netfilter
EOF
    log_ok "Created ${MODULES_CONF}"
else
    log_skip "${MODULES_CONF} already exists"
fi

modprobe overlay 2>/dev/null || true
modprobe br_netfilter 2>/dev/null || true
log_ok "Kernel modules loaded (overlay, br_netfilter)"

# Sysctl params
SYSCTL_CONF="/etc/sysctl.d/k8s.conf"
if [ ! -f "$SYSCTL_CONF" ]; then
    cat > "$SYSCTL_CONF" <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
    sysctl --system > /dev/null 2>&1
    log_ok "Created ${SYSCTL_CONF} and applied sysctl"
else
    log_skip "${SYSCTL_CONF} already exists"
    sysctl --system > /dev/null 2>&1
fi

# =============================================================================
# Step 3: Install containerd
# =============================================================================
log_step 3 $TOTAL_STEPS "Installing containerd"

if command -v containerd &>/dev/null && systemctl is-active containerd &>/dev/null; then
    log_skip "containerd is already installed and running"

    # Always ensure CRI plugin is enabled and SystemdCgroup is set
    # (Docker's containerd.io disables CRI by default)
    CONTAINERD_CHANGED=false
    if grep -q 'disabled_plugins = \["cri"\]' /etc/containerd/config.toml 2>/dev/null; then
        sed -i 's/disabled_plugins = \["cri"\]/disabled_plugins = []/' /etc/containerd/config.toml
        log_ok "CRI plugin enabled (was disabled)"
        CONTAINERD_CHANGED=true
    fi
    if grep -q 'SystemdCgroup = false' /etc/containerd/config.toml 2>/dev/null; then
        sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
        log_ok "SystemdCgroup enabled (was disabled)"
        CONTAINERD_CHANGED=true
    fi
    if [ "$CONTAINERD_CHANGED" = true ]; then
        systemctl restart containerd
        sleep 3
        log_ok "containerd restarted with updated config"
    fi
else
    # Install prerequisites
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg apt-transport-https > /dev/null

    # Add Docker GPG key
    install -m 0755 -d /etc/apt/keyrings
    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
        curl -fsSL https://download.docker.com/linux/${ID}/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    # Add Docker repo
    DOCKER_LIST="/etc/apt/sources.list.d/docker.list"
    if [ ! -f "$DOCKER_LIST" ]; then
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" > "$DOCKER_LIST"
        apt-get update -qq
    fi

    # Install containerd
    apt-get install -y -qq containerd.io > /dev/null
    log_ok "containerd.io installed from Docker repo"

    # Generate default config
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml

    # Enable CRI plugin (Docker's containerd.io disables it by default)
    sed -i 's/disabled_plugins = \["cri"\]/disabled_plugins = []/' /etc/containerd/config.toml
    log_ok "CRI plugin enabled"

    # Enable SystemdCgroup
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    log_ok "SystemdCgroup enabled in containerd config"

    # Enable and restart (apt install may have already started it with old config)
    systemctl enable containerd > /dev/null 2>&1
    systemctl restart containerd
    sleep 3
    if systemctl is-active containerd &>/dev/null; then
        log_ok "containerd started and enabled"
    else
        log_err "containerd failed to start"
        systemctl status containerd --no-pager
        exit 1
    fi
fi

# =============================================================================
# Step 3b: Configure Docker Hub pull-through mirror (mirror.gcr.io)
# Must happen BEFORE kubeadm init (step 5) and registry:2 pull (step 10)
# to avoid Docker Hub rate limits (100 pulls/6hrs per IP).
# =============================================================================
log_step 3 $TOTAL_STEPS "Configuring Docker Hub mirror (mirror.gcr.io)"

CERTS_DIR="/etc/containerd/certs.d"
CONTAINERD_CONFIG="/etc/containerd/config.toml"
DOCKERHUB_HOST_DIR="${CERTS_DIR}/docker.io"

if [ -f "${DOCKERHUB_HOST_DIR}/hosts.toml" ]; then
    log_skip "Docker Hub mirror already configured"
else
    # Ensure config_path is set in containerd config so it reads certs.d
    if [ -f "$CONTAINERD_CONFIG" ]; then
        CURRENT_CONFIG_PATH=$(grep -E '^\s*config_path\s*=' "$CONTAINERD_CONFIG" | head -1 | tr -d ' "' | cut -d= -f2)
        if [ -z "$CURRENT_CONFIG_PATH" ] || [ "$CURRENT_CONFIG_PATH" = "" ]; then
            if grep -q 'config_path = ""' "$CONTAINERD_CONFIG"; then
                sed -i "s|config_path = \"\"|config_path = \"${CERTS_DIR}\"|" "$CONTAINERD_CONFIG"
                log_ok "Set config_path = \"${CERTS_DIR}\" in containerd config"
            fi
        else
            log_skip "config_path already set to: ${CURRENT_CONFIG_PATH}"
        fi
    fi

    # Create docker.io mirror config
    mkdir -p "${DOCKERHUB_HOST_DIR}"
    cat > "${DOCKERHUB_HOST_DIR}/hosts.toml" <<TOML
server = "https://registry-1.docker.io"

[host."https://mirror.gcr.io"]
  capabilities = ["pull", "resolve"]
TOML
    log_ok "Created ${DOCKERHUB_HOST_DIR}/hosts.toml → mirror.gcr.io"

    # Restart containerd to pick up config_path and mirror
    systemctl restart containerd
    sleep 3
    if systemctl is-active containerd &>/dev/null; then
        log_ok "containerd restarted with Docker Hub mirror"
    else
        log_err "containerd failed to restart after mirror config"
        systemctl status containerd --no-pager
        exit 1
    fi
fi

# =============================================================================
# Step 4: Install kubeadm, kubelet, kubectl
# =============================================================================
log_step 4 $TOTAL_STEPS "Installing Kubernetes components"

if command -v kubeadm &>/dev/null && command -v kubelet &>/dev/null && command -v kubectl &>/dev/null; then
    INSTALLED_VERSION=$(kubeadm version -o short 2>/dev/null || echo "unknown")
    log_skip "kubeadm/kubelet/kubectl already installed (${INSTALLED_VERSION})"
else
    # Install prerequisites
    apt-get install -y -qq apt-transport-https ca-certificates curl gpg > /dev/null

    # Detect latest stable K8s minor version
    # Try the pkgs.k8s.io endpoint to find the latest available repo
    LATEST_MINOR=""
    for minor in $(seq 32 -1 28); do
        if curl -fsSL "https://pkgs.k8s.io/core:/stable:/v1.${minor}/deb/Release" &>/dev/null; then
            LATEST_MINOR="1.${minor}"
            break
        fi
    done

    if [ -z "$LATEST_MINOR" ]; then
        log_err "Could not detect latest K8s version from pkgs.k8s.io"
        exit 1
    fi
    log_ok "Detected latest K8s repo: v${LATEST_MINOR}"

    # Add K8s GPG key
    K8S_KEYRING="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
    if [ ! -f "$K8S_KEYRING" ]; then
        curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${LATEST_MINOR}/deb/Release.key" | gpg --dearmor -o "$K8S_KEYRING"
        chmod a+r "$K8S_KEYRING"
    fi

    # Add K8s repo
    K8S_LIST="/etc/apt/sources.list.d/kubernetes.list"
    echo "deb [signed-by=${K8S_KEYRING}] https://pkgs.k8s.io/core:/stable:/v${LATEST_MINOR}/deb/ /" > "$K8S_LIST"
    apt-get update -qq

    # Install
    apt-get install -y -qq kubelet kubeadm kubectl > /dev/null

    # Pin versions so apt-get upgrade doesn't break the cluster
    apt-mark hold kubelet kubeadm kubectl > /dev/null 2>&1

    INSTALLED_VERSION=$(kubeadm version -o short 2>/dev/null || echo "unknown")
    log_ok "Installed kubeadm/kubelet/kubectl ${INSTALLED_VERSION}"
fi

# =============================================================================
# Step 5: Initialize cluster
# =============================================================================
log_step 5 $TOTAL_STEPS "Initializing Kubernetes cluster"

# Detect the node's primary IP (needed for kubeadm init and later steps)
NODE_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
if [ -z "$NODE_IP" ]; then
    NODE_IP=$(hostname -I | awk '{print $1}')
fi
log_ok "Node IP: ${NODE_IP}"

# Set up kubeconfig path for root
export KUBECONFIG=/etc/kubernetes/admin.conf

if [ -f /etc/kubernetes/admin.conf ] && kubectl get nodes &>/dev/null; then
    log_skip "Cluster already initialized"
else
    echo "  Advertising API server on: ${NODE_IP}"

    kubeadm init \
        --pod-network-cidr="${POD_CIDR}" \
        --apiserver-advertise-address="${NODE_IP}" 2>&1 | tail -5

    log_ok "Cluster initialized"
fi

# Also set up kubeconfig for the user who invoked sudo
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    USER_HOME=$(eval echo "~${SUDO_USER}")
    mkdir -p "${USER_HOME}/.kube"
    cp -f /etc/kubernetes/admin.conf "${USER_HOME}/.kube/config"
    chown "$(id -u "$SUDO_USER"):$(id -g "$SUDO_USER")" "${USER_HOME}/.kube/config"
    log_ok "Copied kubeconfig to ${USER_HOME}/.kube/config"
fi

# Root kubeconfig
mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config
log_ok "Copied kubeconfig to /root/.kube/config"

# Remove control-plane taint for single-node
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
log_ok "Removed control-plane taint (single-node scheduling)"

# =============================================================================
# Step 6: Install Flannel CNI
# =============================================================================
log_step 6 $TOTAL_STEPS "Installing Flannel CNI"

if kubectl get daemonset -n kube-flannel kube-flannel-ds &>/dev/null 2>&1 || \
   kubectl get daemonset -n kube-system kube-flannel-ds &>/dev/null 2>&1; then
    log_skip "Flannel already installed"
else
    kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml 2>&1 | tail -3
    log_ok "Flannel CNI installed"
fi

# =============================================================================
# Step 7: Wait for node Ready
# =============================================================================
log_step 7 $TOTAL_STEPS "Waiting for node to become Ready"

READY=false
for i in $(seq 1 60); do
    NODE_STATUS=$(kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [ "$NODE_STATUS" = "True" ]; then
        READY=true
        break
    fi
    echo -n "."
    sleep 5
done
echo ""

if [ "$READY" = true ]; then
    NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
    log_ok "Node ${NODE_NAME} is Ready"
else
    log_warn "Node not Ready after 5 minutes. Continuing anyway — it may need more time for CNI."
fi

# =============================================================================
# Step 8: Install StorageClass (local-path-provisioner)
# =============================================================================
log_step 8 $TOTAL_STEPS "Installing StorageClass"

DEFAULT_SC=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || echo "")

if [ -n "$DEFAULT_SC" ]; then
    log_skip "Default StorageClass already exists: ${DEFAULT_SC}"
else
    kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml 2>&1 | tail -3
    kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
    log_ok "Installed local-path-provisioner as default StorageClass"
fi

# =============================================================================
# Step 9: Install KEDA (pod monitoring + horizontal autoscaling)
# =============================================================================
log_step 9 $TOTAL_STEPS "Installing KEDA"

if kubectl get namespace keda &>/dev/null && kubectl get deployment keda-operator -n keda &>/dev/null; then
    log_skip "KEDA already installed"
else
    # Detect latest KEDA release from GitHub
    KEDA_VERSION=$(curl -fsSL "https://api.github.com/repos/kedacore/keda/releases/latest" 2>/dev/null | grep '"tag_name"' | head -1 | cut -d'"' -f4)

    if [ -z "$KEDA_VERSION" ]; then
        log_warn "Could not detect latest KEDA version from GitHub API. Using v2.16.1."
        KEDA_VERSION="v2.16.1"
    fi
    log_ok "Detected KEDA version: ${KEDA_VERSION}"

    # KEDA CRDs are large — use --server-side to avoid annotation size limits
    kubectl apply --server-side -f "https://github.com/kedacore/keda/releases/download/${KEDA_VERSION}/keda-${KEDA_VERSION#v}.yaml" 2>&1 | tail -5
    log_ok "KEDA ${KEDA_VERSION} installed"

    # Wait for KEDA operator to be ready
    echo "  Waiting for KEDA operator..."
    kubectl wait --for=condition=Available deployment/keda-operator -n keda --timeout=120s 2>/dev/null || {
        log_warn "KEDA operator not ready yet — it may need more time"
    }
fi

# =============================================================================
# Step 10: Install metrics-server
# =============================================================================
log_step 10 $TOTAL_STEPS "Installing metrics-server"

if kubectl get deployment metrics-server -n kube-system &>/dev/null; then
    log_skip "metrics-server already installed"
else
    METRICS_VERSION=$(curl -fsSL "https://api.github.com/repos/kubernetes-sigs/metrics-server/releases/latest" 2>/dev/null | grep '"tag_name"' | head -1 | cut -d'"' -f4)
    if [ -z "$METRICS_VERSION" ]; then
        log_warn "Could not detect latest metrics-server version. Using v0.7.2."
        METRICS_VERSION="v0.7.2"
    fi
    log_ok "Detected metrics-server version: ${METRICS_VERSION}"

    kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_VERSION}/components.yaml" 2>&1 | tail -3

    # Single-node clusters use self-signed kubelet certs — patch in --kubelet-insecure-tls
    kubectl patch deployment metrics-server -n kube-system \
        --type='json' \
        -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
    log_ok "Patched metrics-server with --kubelet-insecure-tls"

    echo "  Waiting for metrics-server..."
    kubectl wait --for=condition=Available deployment/metrics-server -n kube-system --timeout=120s 2>/dev/null || {
        log_warn "metrics-server not ready yet — it may need more time"
    }
    log_ok "metrics-server ${METRICS_VERSION} installed"
fi

# =============================================================================
# Step 11: Install kube-state-metrics
# =============================================================================
log_step 11 $TOTAL_STEPS "Installing kube-state-metrics"

if kubectl get deployment kube-state-metrics -n kube-system &>/dev/null; then
    log_skip "kube-state-metrics already installed"
else
    KSM_VERSION=$(curl -fsSL "https://api.github.com/repos/kubernetes/kube-state-metrics/releases/latest" 2>/dev/null | grep '"tag_name"' | head -1 | cut -d'"' -f4)
    if [ -z "$KSM_VERSION" ]; then
        log_warn "Could not detect latest kube-state-metrics version. Using v2.14.0."
        KSM_VERSION="v2.14.0"
    fi
    log_ok "Detected kube-state-metrics version: ${KSM_VERSION}"

    kubectl apply -f "https://github.com/kubernetes/kube-state-metrics/releases/download/${KSM_VERSION}/kube-state-metrics.yaml" 2>&1 | tail -3

    echo "  Waiting for kube-state-metrics..."
    kubectl wait --for=condition=Available deployment/kube-state-metrics -n kube-system --timeout=120s 2>/dev/null || {
        log_warn "kube-state-metrics not ready yet — it may need more time"
    }
    log_ok "kube-state-metrics ${KSM_VERSION} installed"
fi

# =============================================================================
# Step 12: Deploy container registry with PVC persistence
# =============================================================================
log_step 12 $TOTAL_STEPS "Deploying container registry"

# Create namespace
if ! kubectl get namespace ${REGISTRY_NAMESPACE} &>/dev/null; then
    kubectl create namespace ${REGISTRY_NAMESPACE}
    log_ok "Created namespace: ${REGISTRY_NAMESPACE}"
else
    log_skip "Namespace ${REGISTRY_NAMESPACE} already exists"
fi

# Deploy registry (PVC + Deployment + NodePort Service)
if kubectl get deployment registry -n ${REGISTRY_NAMESPACE} &>/dev/null; then
    log_skip "Registry deployment already exists"
else
    cat <<EOF | kubectl apply -f -
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: registry-data
  namespace: ${REGISTRY_NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: registry
  namespace: ${REGISTRY_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: registry
  template:
    metadata:
      labels:
        app: registry
    spec:
      containers:
      - name: registry
        image: registry:2
        ports:
        - containerPort: 5000
        volumeMounts:
        - name: registry-data
          mountPath: /var/lib/registry
        env:
        - name: REGISTRY_STORAGE_DELETE_ENABLED
          value: "true"
      volumes:
      - name: registry-data
        persistentVolumeClaim:
          claimName: registry-data
---
apiVersion: v1
kind: Service
metadata:
  name: registry
  namespace: ${REGISTRY_NAMESPACE}
spec:
  type: NodePort
  selector:
    app: registry
  ports:
  - port: 5000
    targetPort: 5000
    nodePort: ${REGISTRY_PORT}
EOF
    log_ok "Registry deployed (NodePort ${REGISTRY_PORT}, 20Gi PVC)"
fi

# Wait for registry pod to be ready
echo "  Waiting for registry pod..."
kubectl wait --for=condition=Ready pod -l app=registry -n ${REGISTRY_NAMESPACE} --timeout=120s 2>/dev/null || {
    log_warn "Registry pod not ready yet — it may need the StorageClass provisioner to start first"
}

# =============================================================================
# Step 13: Configure containerd for insecure registry access
# =============================================================================
log_step 13 $TOTAL_STEPS "Configuring containerd for local registry"

# NODE_IP was detected in step 5
REGISTRY_ADDR="${NODE_IP}:${REGISTRY_PORT}"
LOCALHOST_REGISTRY="localhost:${REGISTRY_PORT}"

CERTS_DIR="/etc/containerd/certs.d"
CONTAINERD_CONFIG="/etc/containerd/config.toml"

configure_registry_host() {
    local registry_name=$1
    local registry_url=$2
    local host_dir="${CERTS_DIR}/${registry_name}"

    if [ -f "${host_dir}/hosts.toml" ]; then
        log_skip "Registry config for ${registry_name} already exists"
    else
        mkdir -p "${host_dir}"
        cat > "${host_dir}/hosts.toml" <<TOML
server = "${registry_url}"

[host."${registry_url}"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
TOML
        log_ok "Created ${host_dir}/hosts.toml → ${registry_url}"
    fi
}

# Configure for both localhost and IP-based access
configure_registry_host "${LOCALHOST_REGISTRY}" "http://${LOCALHOST_REGISTRY}"
configure_registry_host "${REGISTRY_ADDR}" "http://${REGISTRY_ADDR}"

# Ensure config_path is set in containerd config
if [ -f "$CONTAINERD_CONFIG" ]; then
    CURRENT_CONFIG_PATH=$(grep -E '^\s*config_path\s*=' "$CONTAINERD_CONFIG" | head -1 | tr -d ' "' | cut -d= -f2)

    if [ -z "$CURRENT_CONFIG_PATH" ] || [ "$CURRENT_CONFIG_PATH" = "" ]; then
        if grep -q 'config_path = ""' "$CONTAINERD_CONFIG"; then
            sed -i "s|config_path = \"\"|config_path = \"${CERTS_DIR}\"|" "$CONTAINERD_CONFIG"
            log_ok "Set config_path = \"${CERTS_DIR}\" in containerd config"
        fi
    else
        log_skip "config_path already set to: ${CURRENT_CONFIG_PATH}"
    fi
fi

# Restart containerd to pick up changes
systemctl restart containerd
sleep 3
if systemctl is-active containerd &>/dev/null; then
    log_ok "containerd restarted successfully"
else
    log_err "containerd failed to restart"
    systemctl status containerd --no-pager
    exit 1
fi

# =============================================================================
# Step 14: Create CI ServiceAccount + token
# =============================================================================
log_step 14 $TOTAL_STEPS "Creating CI ServiceAccount"

# ServiceAccount
if kubectl get serviceaccount ${SA_NAME} -n ${SA_NAMESPACE} &>/dev/null; then
    log_skip "ServiceAccount ${SA_NAME} already exists"
else
    kubectl create serviceaccount ${SA_NAME} -n ${SA_NAMESPACE}
    log_ok "Created ServiceAccount: ${SA_NAME}"
fi

# ClusterRoleBinding
if kubectl get clusterrolebinding ${SA_NAME}-admin &>/dev/null; then
    log_skip "ClusterRoleBinding ${SA_NAME}-admin already exists"
else
    kubectl create clusterrolebinding ${SA_NAME}-admin \
        --clusterrole=cluster-admin \
        --serviceaccount=${SA_NAMESPACE}:${SA_NAME}
    log_ok "Created ClusterRoleBinding: ${SA_NAME}-admin"
fi

# Token secret
if kubectl get secret ${SECRET_NAME} -n ${SA_NAMESPACE} &>/dev/null; then
    log_skip "Token secret ${SECRET_NAME} already exists"
else
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${SA_NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: ${SA_NAME}
type: kubernetes.io/service-account-token
EOF
    sleep 3
    log_ok "Created token secret: ${SECRET_NAME}"
fi

# Extract token
TOKEN=$(kubectl get secret ${SECRET_NAME} -n ${SA_NAMESPACE} -o jsonpath='{.data.token}' | base64 -d)
if [ -z "$TOKEN" ]; then
    log_err "Failed to extract token from secret"
    exit 1
fi
log_ok "Token extracted successfully"

# =============================================================================
# Step 15: Output summary
# =============================================================================
log_step 15 $TOTAL_STEPS "Complete — output summary"

# Get API server address (use external IP)
API_SERVER="https://${NODE_IP}:6443"

# Build kubeconfig
KUBECONFIG_CONTENT="apiVersion: v1
clusters:
- cluster:
    insecure-skip-tls-verify: true
    server: ${API_SERVER}
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: ${SA_NAME}
  name: ${SA_NAME}@kubernetes
current-context: ${SA_NAME}@kubernetes
kind: Config
preferences: {}
users:
- name: ${SA_NAME}
  user:
    token: ${TOKEN}"

KUBECONFIG_B64=$(echo "$KUBECONFIG_CONTENT" | base64 -w 0)

echo ""
echo "============================================"
echo -e "${GREEN} INSTALLATION COMPLETE${NC}"
echo "============================================"
echo ""
echo "  Node:          $(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
echo "  K8s Version:   $(kubectl version --short 2>/dev/null | head -1 || kubeadm version -o short)"
echo "  API Server:    ${API_SERVER}"
echo "  Registry:      ${REGISTRY_ADDR} (NodePort ${REGISTRY_PORT})"
echo "  StorageClass:  $(kubectl get storageclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo 'pending')"
echo "  CNI:           Flannel"
echo "  KEDA:          $(kubectl get deployment keda-operator -n keda -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo 'pending')"
echo "  metrics-server:$(kubectl get deployment metrics-server -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo 'pending')"
echo "  kube-state:    $(kubectl get deployment kube-state-metrics -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo 'pending')"
echo ""
echo "============================================"
echo " QUICK VERIFICATION"
echo "============================================"
echo ""
echo "  kubectl get nodes"
kubectl get nodes 2>/dev/null || true
echo ""
echo "  kubectl get pods -A"
kubectl get pods -A 2>/dev/null || true
echo ""

# Test registry
echo "  Registry test:"
if curl -sf "http://localhost:${REGISTRY_PORT}/v2/_catalog" 2>/dev/null; then
    echo ""
    log_ok "Registry is accessible"
else
    log_warn "Registry not responding yet — pod may still be starting"
fi
echo ""

# Generate provision-remote.sh with all values baked in
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROVISION_SCRIPT="${SCRIPT_DIR}/provision-remote.sh"

cat > "${PROVISION_SCRIPT}" <<'PROVISION_HEADER'
#!/bin/bash
# =============================================================================
# provision-remote.sh
# Generated by install-k8s.sh — run this on your LOCAL machine.
#
# Usage: ./provision-remote.sh --project my-service
#        ./provision-remote.sh --all
#
# What it does:
#   1. Reads Gitea credentials from local Helm values
#   2. Sets KUBECONFIG_BASE64 and REMOTE_REGISTRY as Gitea secrets
#   3. Saves kubeconfig locally for kubectl access
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PROVISION_HEADER

# Bake in the remote values
cat >> "${PROVISION_SCRIPT}" <<PROVISION_VALUES
# --- Baked-in values from install-k8s.sh ---
REGISTRY="${REGISTRY_ADDR}"
API_SERVER="${API_SERVER}"
TOKEN="${TOKEN}"
KUBECONFIG_B64="${KUBECONFIG_B64}"
KUBECONFIG_CONTENT='${KUBECONFIG_CONTENT}'
# --- End baked-in values ---

PROVISION_VALUES

cat >> "${PROVISION_SCRIPT}" <<'PROVISION_BODY'
# Defaults
GITEA_URL="http://localhost:3100"
GITEA_USER="gitea_admin"
GITEA_PASS=""
PROJECT=""
HELM_VALUES=""
ALL_REPOS=false

# Parse arguments
while [ $# -gt 0 ]; do
    case $1 in
        --project=*) PROJECT="${1#*=}" ;;
        --project) shift; PROJECT="$1" ;;
        --gitea-url=*) GITEA_URL="${1#*=}" ;;
        --gitea-url) shift; GITEA_URL="$1" ;;
        --helm-values=*) HELM_VALUES="${1#*=}" ;;
        --helm-values) shift; HELM_VALUES="$1" ;;
        --all) ALL_REPOS=true ;;
        --help|-h)
            echo "Usage: $0 --project <project-name>"
            echo "       $0 --all"
            echo ""
            echo "Options:"
            echo "  --project NAME       Project/repo name (provision a single repo)"
            echo "  --all                Provision ALL repos owned by gitea_admin"
            echo "  --gitea-url URL      Gitea URL (default: http://localhost:3100)"
            echo "  --helm-values PATH   Path to Helm values.yaml (auto-detected)"
            echo ""
            echo "Examples:"
            echo "  $0 --project my-service"
            echo "  $0 --all"
            exit 0
            ;;
        *) echo -e "${RED}Unknown argument: $1${NC}"; exit 1 ;;
    esac
    shift
done

if [ -n "$PROJECT" ] && [ "$ALL_REPOS" = true ]; then
    echo -e "${RED}ERROR: --project and --all are mutually exclusive${NC}"
    exit 1
fi

if [ -z "$PROJECT" ] && [ "$ALL_REPOS" = false ]; then
    echo -e "${RED}ERROR: --project or --all is required${NC}"
    echo "Usage: $0 --project <project-name>"
    echo "       $0 --all"
    exit 1
fi

echo ""
echo "============================================"
echo " Provision Remote Cluster for CI/CD"
echo "============================================"
if [ "$ALL_REPOS" = true ]; then
    echo "  Mode:       ALL repos"
else
    echo "  Project:    ${PROJECT}"
    echo "  Repo:       ${GITEA_USER}/${PROJECT}"
fi
echo "  Gitea:      ${GITEA_URL}"
echo "  Registry:   ${REGISTRY}"
echo "  API Server: ${API_SERVER}"
echo "============================================"
echo ""

# -------------------------------------------------------
# Step 1: Find Gitea password from Helm values
# -------------------------------------------------------
echo -e "${YELLOW}[1/4] Reading Gitea credentials...${NC}"

if [ -z "$HELM_VALUES" ]; then
    # Auto-detect: look relative to this script, then common locations
    for candidate in \
        "$(dirname "$0")/helm/microservice-generator/values.yaml" \
        "$(dirname "$0")/../helm/microservice-generator/values.yaml" \
        "$(dirname "$0")/../../helm/microservice-generator/values.yaml" \
        "./helm/microservice-generator/values.yaml"; do
        if [ -f "$candidate" ]; then
            HELM_VALUES="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"
            break
        fi
    done
fi

if [ -z "$HELM_VALUES" ] || [ ! -f "$HELM_VALUES" ]; then
    echo -e "${RED}ERROR: Cannot find helm/microservice-generator/values.yaml${NC}"
    echo "Run this script from the project root, or use --helm-values <path>"
    exit 1
fi

# Extract Gitea admin password from values.yaml
GITEA_PASS=$(grep -A5 'admin:' "$HELM_VALUES" | grep 'password:' | head -1 | sed 's/.*password: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | tr -d ' ')

if [ -z "$GITEA_PASS" ]; then
    echo -e "${RED}ERROR: Could not extract Gitea password from ${HELM_VALUES}${NC}"
    exit 1
fi

echo -e "${GREEN}  ✓ Found credentials in ${HELM_VALUES}${NC}"

# -------------------------------------------------------
# Step 2: Save kubeconfig locally
# -------------------------------------------------------
echo -e "${YELLOW}[2/4] Saving kubeconfig...${NC}"

KUBECONFIG_FILE="./remote-kubeconfig.yaml"
echo "$KUBECONFIG_CONTENT" > "$KUBECONFIG_FILE"
chmod 600 "$KUBECONFIG_FILE"
echo -e "${GREEN}  ✓ Saved: ${KUBECONFIG_FILE}${NC}"

# Test connection
if kubectl --kubeconfig="$KUBECONFIG_FILE" get nodes &>/dev/null; then
    echo -e "${GREEN}  ✓ Connection to remote cluster verified${NC}"
else
    echo -e "${YELLOW}  ⚠ Could not connect to remote cluster (may need VPN/network access)${NC}"
fi

# -------------------------------------------------------
# Step 3: Set Gitea secrets
# -------------------------------------------------------
echo -e "${YELLOW}[3/4] Setting Gitea secrets...${NC}"

AUTH_B64=$(echo -n "${GITEA_USER}:${GITEA_PASS}" | base64 -w 0 2>/dev/null || echo -n "${GITEA_USER}:${GITEA_PASS}" | base64 2>/dev/null)

set_secret() {
    local repo=$1
    local name=$2
    local value=$3

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -X PUT \
        -H "Authorization: Basic ${AUTH_B64}" \
        -H "Content-Type: application/json" \
        -d "{\"data\": \"${value}\"}" \
        "${GITEA_URL}/api/v1/repos/${repo}/actions/secrets/${name}")

    if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "201" ]; then
        echo -e "${GREEN}  ✓ ${name} set (HTTP ${HTTP_CODE})${NC}"
    else
        echo -e "${RED}  ✗ ${name} FAILED (HTTP ${HTTP_CODE})${NC}"
        echo "    Check that repo '${repo}' exists and Gitea is running at ${GITEA_URL}"
        return 1
    fi
}

list_repos() {
    local page=1
    local all_repos=""
    while true; do
        local response
        response=$(curl -s \
            -H "Authorization: Basic ${AUTH_B64}" \
            "${GITEA_URL}/api/v1/repos/search?limit=50&page=${page}&owner=${GITEA_USER}" 2>/dev/null || echo "")

        # Parse repo names from JSON without jq
        local names
        names=$(echo "$response" | grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"//' || echo "")

        if [ -z "$names" ]; then
            break
        fi

        if [ -z "$all_repos" ]; then
            all_repos="$names"
        else
            all_repos="$all_repos
$names"
        fi

        # If fewer than 50 results, we've reached the last page
        local count
        count=$(echo "$names" | wc -l)
        if [ "$count" -lt 50 ]; then
            break
        fi

        page=$((page + 1))
    done
    echo "$all_repos"
}

provision_repo() {
    local project_name=$1
    local repo="${GITEA_USER}/${project_name}"

    echo ""
    echo -e "${YELLOW}  --- ${repo} ---${NC}"

    if ! set_secret "$repo" "KUBECONFIG_BASE64" "$KUBECONFIG_B64"; then
        return 1
    fi
    if ! set_secret "$repo" "REMOTE_REGISTRY" "$REGISTRY"; then
        return 1
    fi

    # Verify secrets exist
    local secrets_list
    secrets_list=$(curl -s \
        -H "Authorization: Basic ${AUTH_B64}" \
        "${GITEA_URL}/api/v1/repos/${repo}/actions/secrets" 2>/dev/null || echo "")

    local verified=true
    for secret in KUBECONFIG_BASE64 REMOTE_REGISTRY; do
        if echo "$secrets_list" | grep -q "$secret"; then
            echo -e "${GREEN}  ✓ ${secret} exists${NC}"
        else
            echo -e "${RED}  ✗ ${secret} NOT found${NC}"
            verified=false
        fi
    done

    if [ "$verified" = false ]; then
        return 1
    fi
}

# Build project list
PROJECTS=()
if [ "$ALL_REPOS" = true ]; then
    echo "  Discovering repos for ${GITEA_USER}..."
    REPO_LIST=$(list_repos)
    if [ -z "$REPO_LIST" ]; then
        echo -e "${RED}ERROR: No repos found for ${GITEA_USER}${NC}"
        exit 1
    fi
    while IFS= read -r name; do
        [ -n "$name" ] && PROJECTS+=("$name")
    done <<< "$REPO_LIST"
    echo -e "${GREEN}  ✓ Found ${#PROJECTS[@]} repo(s)${NC}"
else
    PROJECTS+=("$PROJECT")
fi

# Provision each project
SUCCEEDED=0
FAILED=0
FAILED_NAMES=()
for proj in "${PROJECTS[@]}"; do
    if provision_repo "$proj"; then
        SUCCEEDED=$((SUCCEEDED + 1))
    else
        FAILED=$((FAILED + 1))
        FAILED_NAMES+=("$proj")
    fi
done

# -------------------------------------------------------
# Step 4: Summary
# -------------------------------------------------------
echo ""
echo "============================================"
if [ "$FAILED" -eq 0 ]; then
    echo -e "${GREEN} PROVISIONING COMPLETE${NC}"
else
    echo -e "${YELLOW} PROVISIONING COMPLETE (with errors)${NC}"
fi
echo "============================================"
echo ""
echo "  Kubeconfig: ${KUBECONFIG_FILE}"
echo "  Provisioned: ${SUCCEEDED}/$((SUCCEEDED + FAILED)) repos"
if [ "$FAILED" -gt 0 ]; then
    echo -e "  ${RED}Failed: ${FAILED_NAMES[*]}${NC}"
fi
echo ""
echo "  Quick commands:"
echo "    kubectl --kubeconfig=\"${KUBECONFIG_FILE}\" get nodes"
if [ "$ALL_REPOS" = true ]; then
    for proj in "${PROJECTS[@]}"; do
        echo "    kubectl --kubeconfig=\"${KUBECONFIG_FILE}\" get pods -n ${proj}"
    done
else
    echo "    kubectl --kubeconfig=\"${KUBECONFIG_FILE}\" get pods -n ${PROJECT}"
    echo ""
    echo "  To deploy, push to the main branch of ${GITEA_USER}/${PROJECT}"
fi
echo ""
echo -e "${GREEN}Done!${NC}"
PROVISION_BODY

chmod +x "${PROVISION_SCRIPT}"
log_ok "Generated ${PROVISION_SCRIPT}"

echo ""
echo "============================================"
echo " NEXT STEP"
echo "============================================"
echo ""
echo "  Copy provision-remote.sh to your local machine and run:"
echo ""
echo "  scp $(whoami)@$(hostname -I | awk '{print $1}'):${PROVISION_SCRIPT} ."
echo "  ./provision-remote.sh --project <your-project-name>"
echo "  ./provision-remote.sh --all                          # provision ALL repos"
echo ""
echo "  To regenerate provision-remote.sh later:"
echo "    sudo ./generate-provision.sh"
echo ""
echo -e "${GREEN}Done! The install is complete.${NC}"
