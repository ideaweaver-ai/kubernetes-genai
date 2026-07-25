#!/usr/bin/env bash

set -Eeuo pipefail

###############################################################################
# Single-node K3s GPU cluster for a Lambda Cloud GPU VM
#
# Installs:
#   - K3s
#   - kubectl configuration
#   - Helm
#   - NVIDIA GPU Operator
#   - CUDA validation workload
#
# Assumption:
#   The NVIDIA driver is already installed on the Lambda VM.
###############################################################################

log() {
  echo
  echo "============================================================"
  echo "$1"
  echo "============================================================"
}

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

###############################################################################
# 1. Basic checks
###############################################################################

if [[ "${EUID}" -eq 0 ]]; then
  fail "Run this script as the normal Lambda user, not directly as root."
fi

if ! command -v sudo >/dev/null 2>&1; then
  fail "sudo is required."
fi

log "Checking operating system"

if [[ ! -f /etc/os-release ]]; then
  fail "Unable to detect the Linux distribution."
fi

source /etc/os-release

echo "Operating system: ${PRETTY_NAME:-unknown}"

log "Checking NVIDIA GPU"

if ! command -v nvidia-smi >/dev/null 2>&1; then
  fail "nvidia-smi was not found. Confirm that the Lambda GPU image includes NVIDIA drivers."
fi

nvidia-smi

log "Checking internet connectivity"

curl -fsSL --connect-timeout 10 https://get.k3s.io >/dev/null ||
  fail "Unable to reach the K3s installation service."

###############################################################################
# 2. Install required packages
###############################################################################

log "Installing required operating-system packages"

sudo apt-get update

sudo apt-get install -y \
  curl \
  wget \
  ca-certificates \
  gnupg \
  jq \
  git \
  tar \
  gzip

###############################################################################
# 3. Disable swap
###############################################################################

log "Disabling swap"

sudo swapoff -a

if grep -Eq '^[^#].*\sswap\s' /etc/fstab; then
  sudo cp /etc/fstab /etc/fstab.backup
  sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab
fi

###############################################################################
# 4. Load Kubernetes networking modules
###############################################################################

log "Configuring kernel modules"

cat <<'EOF' | sudo tee /etc/modules-load.d/k3s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

###############################################################################
# 5. Configure kernel parameters
###############################################################################

log "Configuring Kubernetes networking parameters"

cat <<'EOF' | sudo tee /etc/sysctl.d/99-kubernetes-k3s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system

###############################################################################
# 6. Install K3s
###############################################################################

log "Installing a single-node K3s cluster"

if command -v k3s >/dev/null 2>&1; then
  echo "K3s is already installed."
else
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_EXEC="server \
      --write-kubeconfig-mode=644 \
      --disable=traefik" \
    sh -
fi

###############################################################################
# 7. Wait for Kubernetes
###############################################################################

log "Waiting for the Kubernetes API server"

for attempt in {1..60}; do
  if sudo k3s kubectl get nodes >/dev/null 2>&1; then
    break
  fi

  if [[ "${attempt}" -eq 60 ]]; then
    fail "Kubernetes API server did not become ready."
  fi

  sleep 5
done

###############################################################################
# 8. Configure kubectl for the current user
###############################################################################

log "Configuring kubectl"

mkdir -p "${HOME}/.kube"

sudo cp /etc/rancher/k3s/k3s.yaml "${HOME}/.kube/config"
sudo chown "$(id -u):$(id -g)" "${HOME}/.kube/config"
chmod 600 "${HOME}/.kube/config"

export KUBECONFIG="${HOME}/.kube/config"

if ! grep -q 'KUBECONFIG=.*/.kube/config' "${HOME}/.bashrc"; then
  echo 'export KUBECONFIG=$HOME/.kube/config' >> "${HOME}/.bashrc"
fi

kubectl get nodes -o wide

###############################################################################
# 9. Install Helm
###############################################################################

log "Installing Helm"

if command -v helm >/dev/null 2>&1; then
  echo "Helm is already installed."
else
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 |
    bash
fi

helm version

###############################################################################
# 10. Add the NVIDIA Helm repository
###############################################################################

log "Adding the NVIDIA Helm repository"

helm repo add nvidia https://helm.ngc.nvidia.com/nvidia \
  --force-update

helm repo update

###############################################################################
# 11. Install the NVIDIA GPU Operator
###############################################################################

log "Installing the NVIDIA GPU Operator"

kubectl create namespace gpu-operator \
  --dry-run=client \
  -o yaml |
  kubectl apply -f -

helm upgrade \
  --install gpu-operator \
  nvidia/gpu-operator \
  --namespace gpu-operator \
  --set driver.enabled=false \
  --wait \
  --timeout 15m

###############################################################################
# 12. Wait for GPU Operator resources
###############################################################################

log "Waiting for GPU Operator components"

kubectl wait \
  --for=condition=Ready \
  pods \
  --all \
  --namespace gpu-operator \
  --timeout=900s || true

kubectl get pods -n gpu-operator -o wide

###############################################################################
# 13. Wait for Kubernetes to advertise the GPU
###############################################################################

log "Waiting for nvidia.com/gpu to appear on the node"

GPU_FOUND=false

for attempt in {1..60}; do
  GPU_COUNT="$(
    kubectl get nodes \
      -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' \
      2>/dev/null || true
  )"

  if [[ -n "${GPU_COUNT}" && "${GPU_COUNT}" != "0" ]]; then
    GPU_FOUND=true
    echo "Kubernetes detected ${GPU_COUNT} GPU resource(s)."
    break
  fi

  echo "Waiting for GPU discovery: attempt ${attempt}/60"
  sleep 10
done

if [[ "${GPU_FOUND}" != "true" ]]; then
  echo
  echo "The cluster is running, but nvidia.com/gpu was not detected."
  echo "Run these troubleshooting commands:"
  echo
  echo "  kubectl get pods -n gpu-operator"
  echo "  kubectl describe node"
  echo "  kubectl logs -n gpu-operator -l app=nvidia-device-plugin-daemonset"
  echo "  sudo journalctl -u k3s --no-pager -n 200"
  exit 1
fi

###############################################################################
# 14. Display GPU capacity
###############################################################################

log "Displaying Kubernetes GPU capacity"

kubectl get nodes \
  -o custom-columns='NAME:.metadata.name,GPU-CAPACITY:.status.capacity.nvidia\.com/gpu,GPU-ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'

###############################################################################
# 15. Run a CUDA validation Pod
###############################################################################

log "Creating a CUDA validation Pod"

cat <<'EOF' > /tmp/cuda-gpu-test.yaml
apiVersion: v1
kind: Pod
metadata:
  name: cuda-gpu-test
spec:
  restartPolicy: Never
  containers:
    - name: cuda
      image: nvidia/cuda:12.8.1-base-ubuntu22.04
      command:
        - bash
        - -c
        - |
          echo "GPU visible inside Kubernetes:"
          nvidia-smi
      resources:
        limits:
          nvidia.com/gpu: 1
EOF

kubectl delete pod cuda-gpu-test \
  --ignore-not-found=true \
  --wait=true

kubectl apply -f /tmp/cuda-gpu-test.yaml

kubectl wait \
  --for=jsonpath='{.status.phase}'=Succeeded \
  pod/cuda-gpu-test \
  --timeout=300s || true

###############################################################################
# 16. Show test results
###############################################################################

log "CUDA Pod results"

kubectl get pod cuda-gpu-test -o wide
kubectl logs cuda-gpu-test || true

log "Installation completed"

echo "Cluster information:"
kubectl cluster-info

echo
echo "Node information:"
kubectl get nodes -o wide

echo
echo "GPU resources:"
kubectl get nodes \
  -o custom-columns='NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'

echo
echo "The single-node Kubernetes GPU cluster is ready."
