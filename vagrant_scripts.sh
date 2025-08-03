# =============================================================================
# scripts/common-setup.sh - Common setup for all nodes
# =============================================================================
#!/bin/bash
set -e

echo "=== Starting Common Node Setup ==="

# Update system
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y

# Install required packages
apt-get install -y \
    curl \
    wget \
    vim \
    htop \
    nfs-common \
    open-iscsi \
    util-linux \
    cryptsetup \
    iscsi-initiator-utils

# Configure timezone
timedatectl set-timezone UTC

# Disable swap (required for Kubernetes)
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Configure system parameters for Kubernetes
cat > /etc/sysctl.d/99-kubernetes.conf << EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
vm.swappiness = 1
EOF

# Load br_netfilter module
modprobe br_netfilter
echo 'br_netfilter' > /etc/modules-load.d/k8s.conf

# Apply sysctl changes
sysctl --system

# Disable firewall (RKE2 will manage iptables)
systemctl stop ufw
systemctl disable ufw

# Enable and start iSCSI for Longhorn
systemctl enable --now iscsid
systemctl enable --now open-iscsi

# Configure Longhorn prerequisites
echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf

# Create longhorn directory
mkdir -p /var/lib/longhorn

# Set up automatic security updates
apt-get install -y unattended-upgrades
echo 'Unattended-Upgrade::Automatic-Reboot "false";' >> /etc/apt/apt.conf.d/50unattended-upgrades

echo "=== Common Node Setup Complete ==="

# =============================================================================
# scripts/master-setup.sh - RKE2 master node setup
# =============================================================================
#!/bin/bash
set -e

MASTER_IP="$1"

echo "=== Starting RKE2 Master Setup on IP: $MASTER_IP ==="

# Install RKE2 server
curl -sfL https://get.rke2.io | sh -

# Create RKE2 config directory
mkdir -p /etc/rancher/rke2

# Configure RKE2 server
cat > /etc/rancher/rke2/config.yaml << EOF
# Basic cluster configuration
cluster-cidr: "10.42.0.0/16"
service-cidr: "10.43.0.0/16"
cluster-dns: "10.43.0.10"

# Network configuration  
cni: "canal"
disable-kube-proxy: false

# Security and compliance
protect-kernel-defaults: false
secrets-encryption: true

# Node configuration
node-ip: $MASTER_IP
advertise-address: $MASTER_IP
bind-address: 0.0.0.0

# Disable components we'll install separately
disable:
  - rke2-snapshot-controller
  - rke2-snapshot-controller-crd
  - rke2-snapshot-validation-webhook

# Kubelet configuration
kubelet-arg:
  - "max-pods=250"
  - "cluster-dns=10.43.0.10"
  - "cluster-domain=cluster.local"
EOF

# Enable and start RKE2 server
systemctl enable rke2-server.service
systemctl start rke2-server.service

# Wait for RKE2 to be ready
echo "Waiting for RKE2 server to be ready..."
while ! systemctl is-active --quiet rke2-server; do
  echo "Waiting for RKE2 server to start..."
  sleep 10
done

# Wait for node to be ready
sleep 30

# Set up kubectl access
mkdir -p /home/vagrant/.kube
cp /etc/rancher/rke2/rke2.yaml /home/vagrant/.kube/config
chown vagrant:vagrant /home/vagrant/.kube/config

# Add RKE2 binaries to PATH
cat >> /home/vagrant/.bashrc << 'EOF'
export PATH=$PATH:/var/lib/rancher/rke2/bin
export KUBECONFIG=/home/vagrant/.kube/config
alias k=kubectl
EOF

# Add to root PATH as well
cat >> /root/.bashrc << 'EOF'
export PATH=$PATH:/var/lib/rancher/rke2/bin
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
alias k=kubectl
EOF

# Create symlinks for easier access
ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl
ln -sf /var/lib/rancher/rke2/bin/crictl /usr/local/bin/crictl

# Display join token and instructions
echo "=== RKE2 Master Setup Complete ==="
echo "Node token: $(cat /var/lib/rancher/rke2/server/node-token)"
echo "Master IP: $MASTER_IP"
echo "To connect workers, use server: https://$MASTER_IP:9345"

# =============================================================================
# scripts/worker-setup.sh - RKE2 worker node setup  
# =============================================================================
#!/bin/bash
set -e

MASTER_IP="$1"
WORKER_NAME="$2"

echo "=== Starting RKE2 Worker Setup: $WORKER_NAME ==="
echo "Master IP: $MASTER_IP"

# Install RKE2 agent
curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" sh -

# Create RKE2 config directory
mkdir -p /etc/rancher/rke2

# Wait for master to be available
echo "Waiting for master node to be available..."
until curl -k https://$MASTER_IP:9345 &> /dev/null; do
  echo "Master not ready yet, waiting..."
  sleep 10
done

# Get the token from master (we'll need to do this manually or via ssh)
# For now, we'll use a placeholder - you'll need to update this
echo "Waiting for token file to be available..."
sleep 60

# Try to get token via SSH (requires SSH keys or manual intervention)
# In practice, you might copy this manually or use a shared volume
TOKEN_FILE="/tmp/node-token"

# Create worker configuration
# Note: You'll need to replace TOKEN_PLACEHOLDER with actual token
cat > /etc/rancher/rke2/config.yaml << EOF
server: https://$MASTER_IP:9345
token: TOKEN_PLACEHOLDER
node-label:
  - "node.longhorn.io/create-default-disk=true"
  - "node-role.kubernetes.io/worker=true"
kubelet-arg:
  - "max-pods=250"
EOF

echo "=== Worker configuration created ==="
echo "Manual step required: Replace TOKEN_PLACEHOLDER in /etc/rancher/rke2/config.yaml"
echo "with the actual token from master node: /var/lib/rancher/rke2/server/node-token"

# Enable RKE2 agent (but don't start yet - needs token)
systemctl enable rke2-agent.service

echo "=== RKE2 Worker Setup Complete ==="
echo "To complete setup:"
echo "1. SSH to master: vagrant ssh master"
echo "2. Get token: sudo cat /var/lib/rancher/rke2/server/node-token"
echo "3. SSH to this worker: vagrant ssh $WORKER_NAME" 
echo "4. Edit config: sudo nano /etc/rancher/rke2/config.yaml"
echo "5. Replace TOKEN_PLACEHOLDER with actual token"
echo "6. Start service: sudo systemctl start rke2-agent.service"

# =============================================================================
# scripts/cluster-finalize.sh - Final cluster configuration
# =============================================================================
#!/bin/bash
set -e

echo "=== Finalizing RKE2 Cluster Setup ==="

# Ensure we have the right environment
export PATH=$PATH:/var/lib/rancher/rke2/bin
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

# Wait for all nodes to be ready
echo "Waiting for cluster to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s

# Display cluster status
echo "=== Cluster Status ==="
kubectl get nodes -o wide

# Show system pods
echo "=== System Pods ==="
kubectl get pods -A

# Create storage class for Longhorn (will be used after Longhorn install)
cat > /tmp/longhorn-storageclass.yaml << 'EOF'
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: longhorn-fast
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "2"
  staleReplicaTimeout: "2880"
  fromBackup: ""
  fsType: "ext4"
  dataLocality: "best-effort"
EOF

echo "=== Cluster Finalization Complete ==="
echo "Ready for Longhorn installation!"

# =============================================================================
# scripts/longhorn-install.sh - Longhorn CSI installation
# =============================================================================
#!/bin/bash
set -e

echo "=== Installing Longhorn Storage ==="

# Ensure we have the right environment
export PATH=$PATH:/var/lib/rancher/rke2/bin
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

# Verify cluster is ready
kubectl get nodes

# Check Longhorn prerequisites
echo "=== Checking Longhorn Prerequisites ==="
kubectl get nodes -o jsonpath='{.items[*].metadata.labels}' | grep -o 'node\.longhorn\.io/create-default-disk[^,]*' || echo "Longhorn labels not found - will be auto-detected"

# Install Longhorn
echo "=== Installing Longhorn via kubectl ==="
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.7.2/deploy/longhorn.yaml

# Wait for Longhorn to be ready
echo "=== Waiting for Longhorn pods to be ready ==="
kubectl wait --for=condition=ready pod -l app=longhorn-manager -n longhorn-system --timeout=600s
kubectl wait --for=condition=ready pod -l app=longhorn-driver-deployer -n longhorn-system --timeout=300s

# Apply optimized storage class
kubectl apply -f /tmp/longhorn-storageclass.yaml

# Show Longhorn status
echo "=== Longhorn Installation Status ==="
kubectl get pods -n longhorn-system
kubectl get storageclass

# Test storage with a sample PVC
cat > /tmp/test-pvc.yaml << 'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-longhorn-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn-fast
  resources:
    requests:
      storage: 1Gi
EOF

kubectl apply -f /tmp/test-pvc.yaml

echo "=== Testing storage ==="
kubectl get pvc test-longhorn-pvc

# Display access information
echo "=== Longhorn UI Access ==="
echo "To access Longhorn UI:"
echo "1. kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80"
echo "2. Open browser to http://localhost:8080"

echo "=== Longhorn Installation Complete ==="
echo "Storage system is ready for your applications!"