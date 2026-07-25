#!/usr/bin/env bash

set -euo pipefail

echo "Installing K3s..."

curl -sfL https://get.k3s.io | \
  INSTALL_K3S_EXEC="server --write-kubeconfig-mode 644 --disable traefik" \
  sh -

echo "Waiting for the Kubernetes node..."

until sudo k3s kubectl get node >/dev/null 2>&1; do
  sleep 5
done

echo "Configuring kubectl for the current user..."

mkdir -p "$HOME/.kube"

sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"

export KUBECONFIG="$HOME/.kube/config"

if ! grep -q 'KUBECONFIG=.*\.kube/config' "$HOME/.bashrc"; then
  echo 'export KUBECONFIG=$HOME/.kube/config' >> "$HOME/.bashrc"
fi

echo
echo "Kubernetes cluster is ready."
kubectl get nodes -o wide
