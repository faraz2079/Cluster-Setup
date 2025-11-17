#!/bin/bash
set -e

###############################################
# Manual Placeholder Variables (EDIT THESE)
###############################################

INTERFACE_NAME="<INTERFACE_NAME>"             # e.g. enp0s3
CONTROL_PLANE_IP="<CONTROL_PLANE_IP>"         # e.g. 192.168.1.50
KUBERNETES_VERSION="<KUBERNETES_VERSION>"     # e.g. v1.32
CRIO_VERSION="<CRIO_VERSION>"                 # e.g. v1.32

###############################################
echo ">>> Using:"
echo "Interface: $INTERFACE_NAME"
echo "IP: $CONTROL_PLANE_IP"
echo "Kubernetes Version: $KUBERNETES_VERSION"
echo "CRI-O Version: $CRIO_VERSION"
sleep 3

###############################################
# Load required kernel modules
###############################################

echo ">>> Loading kernel modules..."
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

###############################################
# sysctl settings
###############################################
echo ">>> Applying sysctl settings..."

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system


###############################################
# Disable swap
###############################################

echo ">>> Disabling swap..."
sudo swapoff -a
(crontab -l 2>/dev/null; echo "@reboot /sbin/swapoff -a") | crontab - || true


###############################################
# Install dependencies
###############################################

sudo apt-get update -y
sudo apt-get install -y apt-transport-https ca-certificates curl gpg jq


###############################################
# Install CRI-O
###############################################

echo ">>> Installing CRI-O runtime..."
curl -fsSL https://pkgs.k8s.io/addons:/cri-o:/stable:/$CRIO_VERSION/deb/Release.key \
| gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://pkgs.k8s.io/addons:/cri-o:/stable:/$CRIO_VERSION/deb/ /" \
| tee /etc/apt/sources.list.d/cri-o.list

sudo apt-get update -y
sudo apt-get install -y cri-o

sudo systemctl daemon-reload
sudo systemctl enable --now crio

###############################################
# Install kubectl, kubeadm, kubelet
###############################################

echo ">>> Installing Kubernetes packages..."

curl -fsSL https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/Release.key \
| sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/ /" \
| sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update -y
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

###############################################
# Configure kubelet to use your manual IP
###############################################

echo "KUBELET_EXTRA_ARGS=--node-ip=$CONTROL_PLANE_IP" | sudo tee /etc/default/kubelet


###############################################
# Create kubeadm config
###############################################

echo ">>> Writing kubeadm config..."

cat <<EOF | sudo tee kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "$CONTROL_PLANE_IP"
  bindPort: 6443
nodeRegistration:
  name: "controlplane"

---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: "$KUBERNETES_VERSION"
controlPlaneEndpoint: "$CONTROL_PLANE_IP:6443"
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
  dnsDomain: "cluster.local"

EOF


###############################################
# Start Kubernetes Control Plane
###############################################

echo ">>> Initializing Kubernetes cluster..."

sudo kubeadm init --config kubeadm-config.yaml --upload-certs


###############################################
# Configure kubectl for user
###############################################

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config


###############################################
# Install CNI (Flannel)
###############################################

echo ">>> Installing Flannel CNI..."

kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml

echo ">>> Kubernetes cluster setup complete!"
kubectl get nodes -o wide
