#!/bin/bash
# AAK Task
# Description: Bash script to set up a Kubernetes cluster with 2 control plane nodes and 1 worker node.
# This script is based on the official Kubernetes documentation for kubeadm.
# Usage: Run this script on each node, modifying the LOAD_BALANCER_IP accordingly.

# --- Variables ---
# The control-plane-endpoint should be a reachable IP or DNS name.
# It should be the public IP of your first control-plane node for this setup.
LOAD_BALANCER_IP="3.93.201.137"
KUBEADM_TOKEN=""
KUBEADM_HASH=""
KUBEADM_CERT_KEY=""

# --- Functions ---
configure_prerequisites() {
    echo "Configuring prerequisites as per Kubernetes documentation..."
    # Disable swap permanently, as required by kubeadm pre-flight checks.
    sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
    sudo swapoff -a

    # Enable kernel modules for networking. These are essential for the CNI plugin.
    cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
    sudo modprobe overlay
    sudo modprobe br_netfilter

    # Enable IP forwarding, a key requirement for Kubernetes networking.
    cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
    sudo sysctl --system
}

install_kubernetes_components() {
    echo "Installing Kubernetes components using YUM..."
    # The documentation provides steps for Debian/Ubuntu (apt-get). This section
    # is the Amazon Linux equivalent using yum.
    cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl
EOF

    # Install kubelet, kubeadm, and kubectl.
    sudo yum update -y
    sudo yum install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
    sudo systemctl enable --now kubelet

    # Install containerd runtime, as required by Kubernetes.
    sudo yum install -y containerd
    sudo systemctl enable --now containerd

    # Configure containerd to use the systemd cgroup driver.
    sudo mkdir -p /etc/containerd
    containerd config default | sudo tee /etc/containerd/config.toml
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    sudo systemctl restart containerd
}

initialize_control_plane() {
    echo "Initializing the first control-plane node..."
    # This command is the core of a highly available setup.
    # --control-plane-endpoint: Sets the API server's endpoint.
    # --upload-certs: Uploads certificates to the cluster for easy joining.
    # --pod-network-cidr: Specifies the IP range for the pod network (Calico in this case).
    sudo kubeadm init \
        --control-plane-endpoint "$LOAD_BALANCER_IP:6443" \
        --upload-certs \
        --pod-network-cidr=10.244.0.0/16

    # Configure kubectl for the current user, as per documentation.
    mkdir -p "$HOME/.kube"
    sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
    sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

    # Install a pod network add-on (Calico). This is a required step for inter-pod communication.
    kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml

    # Get join commands for other nodes.
    echo "Waiting for cluster to be ready..."
    sleep 30
    KUBEADM_TOKEN=$(sudo kubeadm token create)
    KUBEADM_HASH=$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //')
    KUBEADM_CERT_KEY=$(sudo kubeadm init phase upload-certs --upload-certs | grep -m1 -oP '(?<=certificate-key=).*')

    echo "Kubeadm Join Token: $KUBEADM_TOKEN"
    echo "Kubeadm Hash: sha256:$KUBEADM_HASH"
    echo "Kubeadm Cert Key: $KUBEADM_CERT_KEY"
    echo "Use these values to join other nodes."
}

join_control_plane() {
    echo "Joining as a control-plane node..."
    if [ -z "$KUBEADM_TOKEN" ] || [ -z "$KUBEADM_HASH" ] || [ -z "$KUBEADM_CERT_KEY" ]; then
        echo "Error: KUBEADM_TOKEN, KUBEADM_HASH, and KUBEADM_CERT_KEY must be set."
        exit 1
    fi
    # The --control-plane and --certificate-key flags are used to join as an HA member.
    sudo kubeadm join "$LOAD_BALANCER_IP:6443" \
        --token "$KUBEADM_TOKEN" \
        --discovery-token-ca-cert-hash sha256:"$KUBEADM_HASH" \
        --control-plane \
        --certificate-key "$KUBEADM_CERT_KEY"
}

join_worker_node() {
    echo "Joining as a worker node..."
    if [ -z "$KUBEADM_TOKEN" ] || [ -z "$KUBEADM_HASH" ]; then
        echo "Error: KUBEADM_TOKEN and KUBEADM_HASH must be set."
        exit 1
    fi
    # This is the standard join command for worker nodes.
    sudo kubeadm join "$LOAD_BALANCER_IP:6443" \
        --token "$KUBEADM_TOKEN" \
        --discovery-token-ca-cert-hash sha256:"$KUBEADM_HASH"
}

# --- Main Logic ---
configure_prerequisites
install_kubernetes_components

echo "Please choose the node type to set up:"
echo "1. First Control-Plane Node"
echo "2. Additional Control-Plane Node"
echo "3. Worker Node"
read -p "Enter your choice (1, 2, or 3): " choice

case $choice in
    1)
        initialize_control_plane
        ;;
    2)
        read -p "Enter the Kubeadm token: " KUBEADM_TOKEN
        read -p "Enter the discovery hash (e.g., sha256:<hash>): " KUBEADM_HASH
        read -p "Enter the certificate key: " KUBEADM_CERT_KEY
        KUBEADM_HASH=$(echo "$KUBEADM_HASH" | sed 's/sha256://')
        join_control_plane
        ;;
    3)
        read -p "Enter the Kubeadm token: " KUBEADM_TOKEN
        read -p "Enter the discovery hash (e.g., sha256:<hash>): " KUBEADM_HASH
        KUBEADM_HASH=$(echo "$KUBEADM_HASH" | sed 's/sha256://')
        join_worker_node
        ;;
    *)
        echo "Invalid choice."
        exit 1
        ;;
esac

echo "Cluster setup complete on this node."