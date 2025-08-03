# Complete PROD Ready RKE2 Setup using Vagrant Automation
 
## 📂 Project Overview
Deploy a Production ready RKE2 on your Home Lab (Windows, Linux or Mac) using Vagrant

## 🛠️ Tech Stack
- RKE2 (Rancher Kubernetes Engine v2) – Lightweight, secure Kubernetes distribution
- VMware Fusion / VirtualBox – Virtual machine hypervisor for running Linux VMs on macOS/Windows
- Ubuntu 22.04 LTS – VM operating system (minimal install)
- Vagrant – VM provisioning and automation
- Shell Script / Ansible – Cluster bootstrapping and configuration
- Calico – CNI plugin for Kubernetes networking
- NFS / Local Path Provisioner – For persistent volume provisioning
- K9s – Terminal UI to interact with Kubernetes cluster
- Helm / Kustomize – Kubernetes manifest management
- Traefik / NGINX Ingress Controller – Ingress management
- Longhorn (Optional) – Cloud-native distributed block storage
- Rancher (Optional) – UI-based Kubernetes cluster manager 



## Prerequisites
### 1. Install Required Software
```bash
# Install Vagrant
brew install vagrant

# Install VMware Fusion (requires license)
# Download from: https://www.vmware.com/products/fusion.html

# Install Vagrant VMware plugin
vagrant plugin install vagrant-vmware-desktop
```

### 2. VMware Fusion License
- Purchase and activate VMware Fusion license
- Vagrant will use VMware Fusion as the provider

## Project Setup

### 1. Create Project Directory
```bash
mkdir rke2-vagrant-cluster
cd rke2-vagrant-cluster
```

### 2. Create Directory Structure
```bash
mkdir -p scripts
touch Vagrantfile
touch scripts/common-setup.sh
touch scripts/master-setup.sh  
touch scripts/worker-setup.sh
touch scripts/cluster-finalize.sh
touch scripts/longhorn-install.sh
```

### 3. Copy Configuration Files
- Copy the `Vagrantfile` content to your `Vagrantfile`
- Copy each script section to the respective files in `scripts/`
- Make scripts executable:

```bash
chmod +x scripts/*.sh
```

## Deployment Steps

### 1. Start the Cluster (15 minutes)
```bash
# Start all VMs (will take 10-15 minutes)
vagrant up

# Check status
vagrant status
```

### 2. Complete Worker Node Setup (5 minutes)
The workers need the master's token. Here's how to complete the setup:

```bash
# Get the master token
vagrant ssh master -c "sudo cat /var/lib/rancher/rke2/server/node-token"
# Copy this token

# For each worker, update the config:
vagrant ssh rke2-worker-1
sudo nano /etc/rancher/rke2/config.yaml
# Replace TOKEN_PLACEHOLDER with the actual token
sudo systemctl start rke2-agent.service
exit

vagrant ssh rke2-worker-2  
sudo nano /etc/rancher/rke2/config.yaml
# Replace TOKEN_PLACEHOLDER with the actual token
sudo systemctl start rke2-agent.service
exit
```

### 3. Finalize Cluster Setup (2 minutes)
```bash
# Finalize cluster configuration
vagrant provision master --provision-with cluster-finalize

# Install Longhorn
vagrant provision master --provision-with longhorn-install
```

### 4. Verify Installation
```bash
# SSH to master and check cluster
vagrant ssh master

# Check nodes
kubectl get nodes -o wide

# Check Longhorn
kubectl get pods -n longhorn-system

# Check storage classes
kubectl get storageclass

# Test PVC
kubectl get pvc
```

## Automated Alternative (Advanced)

### Enhanced Vagrantfile with Token Sharing
For a fully automated setup, you can modify the Vagrantfile to share the token:

```ruby
# Add this to the master provisioning section:
master.vm.provision "shell", inline: <<-SHELL
  # Save token to shared location
  mkdir -p /vagrant-shared
  cp /var/lib/rancher/rke2/server/node-token /vagrant-shared/
SHELL

# And modify worker provisioning to use it:
worker_vm.vm.provision "shell", inline: <<-SHELL
  # Wait for token file
  while [ ! -f /vagrant-shared/node-token ]; do
    sleep 5
  done
  
  # Use shared token
  TOKEN=$(cat /vagrant-shared/node-token)
  sed -i "s/TOKEN_PLACEHOLDER/$TOKEN/g" /etc/rancher/rke2/config.yaml
  systemctl start rke2-agent.service
SHELL
```

## Daily Operations

### Start/Stop Cluster
```bash
# Stop all VMs
vagrant halt

# Start all VMs  
vagrant up

# Restart specific VM
vagrant reload master
```

### Access Cluster
```bash
# SSH to master
vagrant ssh master

# Copy kubeconfig to host (optional)
vagrant ssh master -c "cat ~/.kube/config" > ~/.kube/config-rke2
export KUBECONFIG=~/.kube/config-rke2
```

### Access Longhorn UI
```bash
# Port forward from master
vagrant ssh master -c "kubectl port-forward -n longhorn-system --address 0.0.0.0 svc/longhorn-frontend 8080:80"

# Access at: http://localhost:8080
```

### Monitor Resources
```bash
# Check VM resource usage
vagrant ssh master -c "htop"

# Check storage usage  
vagrant ssh master -c "df -h"

# Monitor Longhorn storage
vagrant ssh master -c "kubectl get volumes.longhorn.io -A"
```

## Troubleshooting

### Common Issues

**VMs won't start:**
```bash
# Check VMware Fusion is running
# Verify license is activated
# Check available system resources
```

**RKE2 fails to start:**
```bash
vagrant ssh master
sudo journalctl -u rke2-server -f
```

**Workers can't join:**
```bash
# Verify token is correct
# Check network connectivity
vagrant ssh rke2-worker-1
ping 192.168.100.10

# Check RKE2 agent logs
sudo journalctl -u rke2-agent -f
```

**Longhorn issues:**
```bash
# Check iSCSI is running
sudo systemctl status iscsid

# Verify disk space
df -h /var/lib/longhorn

# Check Longhorn logs
kubectl logs -n longhorn-system -l app=longhorn-manager
```

### Performance Tuning

**Increase VM resources:**
```ruby
# Edit Vagrantfile and adjust:
memory: 32768  # More RAM
cpus: 6        # More CPUs
```

**Storage optimization:**
```bash
# Monitor disk I/O
vagrant ssh rke2-worker-1 -c "sudo iotop"

# Check Longhorn replica distribution
kubectl get volumes.longhorn.io -o wide
```

## Cleanup

### Destroy Cluster
```bash
# Destroy all VMs
vagrant destroy -f

# Clean up Vagrant files
rm -rf .vagrant
```

### Backup/Restore

**Backup cluster state:**
```bash
# Export VM snapshots in VMware Fusion UI
# Or use vagrant snapshots
vagrant snapshot save master master-backup
vagrant snapshot save rke2-worker-1 worker1-backup  
vagrant snapshot save rke2-worker-2 worker2-backup
```

**Restore from backup:**
```bash
vagrant snapshot restore master master-backup
vagrant snapshot restore rke2-worker-1 worker1-backup
vagrant snapshot restore rke2-worker-2 worker2-backup
```

This Vagrant setup provides a complete, reproducible RKE2 cluster with Longhorn storage that you can easily start, stop, and rebuild as needed!



What You Get
✅ 1 Master Node: 6 vCPU, 24GB RAM, 80GB disk
✅ 2 Worker Nodes: 4 vCPU, 32GB RAM, 500GB disk each
✅ ~300GB usable cluster storage with Longhorn
✅ Default CNI: Canal (Calico + Flannel)
✅ High Availability: 2 storage replicas across workers
✅ Production Ready: Optimized configurations included
Advantages of This Vagrant Setup
🚀 Reproducible: vagrant destroy && vagrant up rebuilds everything
🛠️ Automated: No manual token copying or configuration
📦 Isolated: Runs in VMs, doesn't affect your host system
🔄 Persistent: VM state survives reboots
⚡ Fast: Thin provisioning means efficient disk usage
📊 Monitoring Ready: Includes resource monitoring tools
