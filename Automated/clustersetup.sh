#!/usr/bin/env bash

set -euo pipefail

echo "============================"
echo " Kubernetes Control Plane Setup (Auto Mode)"
echo "============================"

# -------------------------------
# 1) Kernel modules + sysctl
# -------------------------------

echo "[1/10] Configuring kernel modules..."

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf >/dev/null
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf >/dev/null
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system

# -------------------------------
# 2) Disable swap
# -------------------------------

echo "[2/10] Disabling swap..."

sudo swapoff -a
( crontab -l 2>/dev/null; echo "@reboot /sbin/swapoff -a" ) | crontab - || true

# -------------------------------
# 3) Install CRI-O
# -------------------------------

echo "[3/10] Installing CRI-O runtime..."

export KUBERNETES_VERSION=v1.32
export CRIO_VERSION=v1.32

sudo apt-get update -y
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

sudo mkdir -p /etc/apt/keyrings

curl -fsSL https://pkgs.k8s.io/addons:/cri-o:/stable:/$CRIO_VERSION/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://pkgs.k8s.io/addons:/cri-o:/stable:/$CRIO_VERSION/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/cri-o.list >/dev/null

sudo apt-get update -y
sudo apt-get install -y cri-o cri-o-runc

sudo systemctl enable --now crio

# -------------------------------
# 4) Install kubeadm, kubelet, kubectl
# -------------------------------

echo "[4/10] Installing Kubernetes packages..."

curl -fsSL https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

sudo apt-get update -y
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# -------------------------------
# 5) Detect interface + IP
# -------------------------------

echo "[5/10] Detecting primary network interface and IP..."

CP_IP="$(ip route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++){if($i=="src"){print $(i+1); exit}}}')"
CP_IFACE="$(ip route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}')"
CP_NAME="$(hostname -s)"

echo "Detected:"
echo "  - Interface: $CP_IFACE"
echo "  - IP:        $CP_IP"
echo "  - Hostname:  $CP_NAME"

# Tell kubelet to use this IP
echo "KUBELET_EXTRA_ARGS=--node-ip=$CP_IP" | sudo tee /etc/default/kubelet >/dev/null
sudo systemctl daemon-reload
sudo systemctl restart kubelet

# -------------------------------
# 6) Create kubeadm.config
# -------------------------------

echo "[6/10] Generating kubeadm.config..."

cat <<EOF | sudo tee kubeadm.config >/dev/null
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "${CP_IP}"
  bindPort: 6443
nodeRegistration:
  name: "${CP_NAME}"

---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: "v1.32.0"
controlPlaneEndpoint: "${CP_IP}:6443"
apiServer:
  extraArgs:
    enable-admission-plugins: "NodeRestriction"
    audit-log-path: "/var/log/kubernetes/audit.log"
controllerManager:
  extraArgs:
    node-cidr-mask-size: "24"
scheduler:
  extraArgs:
    leader-elect: "true"
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
  dnsDomain: "cluster.local"

---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: "systemd"
syncFrequency: "1m"

---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: "ipvs"
conntrack:
  maxPerCore: 32768
  min: 131072
  tcpCloseWaitTimeout: "1h"
  tcpEstablishedTimeout: "24h"
EOF

# -------------------------------
# 7) Initialize cluster
# -------------------------------

echo "[7/10] Initializing Kubernetes cluster..."

sudo kubeadm init --config kubeadm.config --upload-certs

# -------------------------------
# 8) Configure kubectl for current user
# -------------------------------

echo "[8/10] Setting up kubectl for this user..."

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown "$(id -u):$(id -g)" $HOME/.kube/config

# -------------------------------
# 9) Install CNI plugins (must exist locally)
# -------------------------------

echo "[9/10] Installing CNI plugins..."

CNI_VERSION=v1.4.0

if [[ ! -f "cni-plugins-linux-amd64-${CNI_VERSION}.tgz" ]]; then
    echo "ERROR: CNI plugin archive cni-plugins-linux-amd64-${CNI_VERSION}.tgz not found in current directory."
    echo "Please download it first."
    exit 1
fi

sudo mkdir -p /opt/cni/bin
sudo tar -C /opt/cni/bin -xzf cni-plugins-linux-amd64-${CNI_VERSION}.tgz

# -------------------------------
# 10) Install Flannel
# -------------------------------

echo "[10/10] Installing Flannel CNI..."

kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml

echo ""
echo "======================================"
echo " Kubernetes Setup Complete! 🎉"
echo "======================================"
echo "Your cluster is ready. Test with:"
echo "  kubectl get nodes -o wide"
echo "  kubectl get pods -A"
echo ""
