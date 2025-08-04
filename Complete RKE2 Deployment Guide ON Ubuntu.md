# Complete RKE2 Deployment Guide: Ubuntu 24.04 with Longhorn, Harbor, and JupyterHub

## Expected Cluster Capacity

With the recommended configuration (Master: 16vCPU/64GB, Workers: 8vCPU/32GB each):

### **Total Resources:**
- **vCPUs**: 48 total (40+ available for applications)
- **RAM**: 160GB total (140+ GB available for applications)  
- **Storage**: 550GB total (expandable with Longhorn)

### **Application Capacity:**
- **JupyterHub Users**: 30-50 concurrent users (4GB each)
- **Harbor Projects**: Multiple projects with GB-scale storage
- **Additional Applications**: Plenty of room for monitoring, CI/CD, etc.

### **High Availability:**
- Can survive loss of any single worker node
- Longhorn provides 3-replica data redundancy
- Critical services can be spread across nodes

## Overview

This tutorial will guide you through deploying a production-ready Kubernetes cluster using RKE2 on Ubuntu 24.04 with:
- **RKE2**: Free, open-source Kubernetes distribution (Apache 2.0 License)
- **Longhorn**: Cloud-native distributed block storage
- **Harbor**: Enterprise-class container registry
- **JupyterHub**: Multi-user Jupyter notebook platform

## Prerequisites

### Hardware Requirements
- **Master Node**: 16 vCPUs, 64GB RAM, 250GB storage
- **Worker Nodes**: 8 vCPUs, 32GB RAM, 100GB storage each (recommended)
- **Network**: All nodes must communicate on ports 6443, 9345, and 8472 (UDP)

### Alternative Worker Node Configurations:
- **Cost-Effective**: 4 vCPUs, 16GB RAM, 80GB storage each
- **High-Performance**: 12 vCPUs, 48GB RAM, 150GB storage each

### Software Requirements
- **OS**: Ubuntu 24.04 LTS Server (fresh installation)
- **Network**: Static IP addresses recommended
- **Internet Access**: Required for downloading components
- **SSH Access**: To all nodes

### Infrastructure Setup
```
Node Layout:
├── rke2-master-01  (192.168.1.10) - Control Plane
├── rke2-worker-01  (192.168.1.11) - Worker Node
├── rke2-worker-02  (192.168.1.12) - Worker Node
└── rke2-worker-03  (192.168.1.13) - Worker Node
```

## Phase 1: System Preparation

### 1.1 Update All Nodes

SSH into each node and run:

```bash
# Update system packages
sudo apt update && sudo apt upgrade -y

# Install required packages
sudo apt install -y curl wget nfs-common open-iscsi

# Disable UFW firewall (adjust for production security requirements)
sudo systemctl stop ufw
sudo systemctl disable ufw

# Enable and start iSCSI (required for Longhorn)
sudo systemctl enable iscsid
sudo systemctl start iscsid

# Clean up
sudo apt autoremove -y
```

### 1.2 Configure Network (Optional but Recommended)

Ensure NetworkManager doesn't interfere with CNI:

```bash
# Create NetworkManager config to ignore CNI interfaces
sudo mkdir -p /etc/NetworkManager/conf.d/
sudo tee /etc/NetworkManager/conf.d/rke2-canal.conf > /dev/null <<EOF
[keyfile]
unmanaged-devices=interface-name:cali*;interface-name:flannel*
EOF

# Restart NetworkManager if it's running
sudo systemctl restart NetworkManager 2>/dev/null || true
```

## Phase 2: RKE2 Master Node Installation

### 2.1 Install RKE2 Server on Master Node

SSH to your master node (192.168.1.10):

```bash
# Download and install RKE2
curl -sfL https://get.rke2.io | sh -

# Create RKE2 configuration directory
sudo mkdir -p /etc/rancher/rke2

# Create RKE2 server configuration
sudo tee /etc/rancher/rke2/config.yaml > /dev/null <<EOF
# RKE2 Server Configuration
write-kubeconfig-mode: "0644"
tls-san:
  - "192.168.1.10"  # Master node IP
  - "rke2-master-01"  # Master node hostname
node-label:
  - "node-role=master"
cluster-cidr: "10.42.0.0/16"
service-cidr: "10.43.0.0/16"
# Allow workloads on master node (remove if you want dedicated control plane)
# node-taint:
#   - "CriticalAddonsOnly=true:NoExecute"
EOF

# Enable and start RKE2 server
sudo systemctl enable rke2-server.service
sudo systemctl start rke2-server.service

# Monitor the startup process (optional)
sudo journalctl -u rke2-server -f
```

### 2.2 Configure kubectl Access

**Note about Master Node Resources:**
With 16 vCPUs and 64GB RAM, your master node is very powerful. By default, this configuration allows workloads to run on the master node, giving you ~14 vCPUs and 60GB RAM for applications in addition to the worker nodes. If you prefer a dedicated control plane, uncomment the `node-taint` lines in the config above.

```bash
# Create symlink for kubectl
sudo ln -s /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl

# Set up kubeconfig for root user
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

# Set up kubeconfig for current user
mkdir -p ~/.kube
sudo cp /etc/rancher/rke2/rke2.yaml ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config

# Verify cluster is running
kubectl get nodes
kubectl get pods -A
```

### 2.3 Get Worker Node Token

```bash
# Get the node token for worker nodes
sudo cat /var/lib/rancher/rke2/server/node-token
# Save this token - you'll need it for worker nodes
```

## Phase 3: RKE2 Worker Nodes Installation

### 3.1 Install RKE2 Agent on Each Worker Node

SSH to each worker node and run:

```bash
# Download and install RKE2 agent
curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" sh -

# Create RKE2 configuration directory
sudo mkdir -p /etc/rancher/rke2

# Create RKE2 agent configuration
# Replace <MASTER_IP> with your master IP and <TOKEN> with the token from step 2.3
sudo tee /etc/rancher/rke2/config.yaml > /dev/null <<EOF
# RKE2 Agent Configuration
server: https://192.168.1.10:9345
token: <TOKEN_FROM_MASTER_NODE>
node-label:
  - "node-role=worker"
EOF

# Enable and start RKE2 agent
sudo systemctl enable rke2-agent.service
sudo systemctl start rke2-agent.service

# Monitor the startup process (optional)
sudo journalctl -u rke2-agent -f
```

### 3.2 Verify Cluster

From the master node:

```bash
# Check all nodes are ready
kubectl get nodes -o wide

# Check system pods
kubectl get pods -A
```

Expected output should show all 4 nodes in "Ready" status.

## Phase 4: Install Helm

On the master node:

```bash
# Install Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify Helm installation
helm version

# Add useful Helm repositories
helm repo add jetstack https://charts.jetstack.io
helm repo add longhorn https://charts.longhorn.io
helm repo add harbor https://helm.goharbor.io
helm repo add jupyterhub https://hub.jupyter.org/helm-chart/
helm repo update
```

## Phase 5: Deploy Longhorn Storage

### 5.1 Install Longhorn

```bash
# Create Longhorn namespace and install
kubectl create namespace longhorn-system
helm upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --set persistence.defaultClass=true \
  --set persistence.defaultClassReplicaCount=3

# Wait for Longhorn to be ready
kubectl -n longhorn-system get pods -w
```

### 5.2 Access Longhorn UI (Optional)

```bash
# Create a service to access Longhorn UI
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80 &

# Access via http://localhost:8080
# Or create an ingress for permanent access
```

### 5.3 Verify Longhorn Storage

```bash
# Check storage classes
kubectl get storageclass

# Test with a sample PVC
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-longhorn-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: longhorn
EOF

# Verify PVC is bound
kubectl get pvc test-longhorn-pvc

# Clean up test PVC
kubectl delete pvc test-longhorn-pvc
```