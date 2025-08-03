# -*- mode: ruby -*-
# vi: set ft=ruby :

# Fully Automated RKE2 Cluster with Longhorn
# Usage: vagrant up (wait 20-25 minutes for complete setup)

CLUSTER_CONFIG = {
  master: {
    name: "rke2-master",
    ip: "192.168.100.10", 
    cpus: 6,
    memory: 24576,
    disk_size: "80GB"
  },
  workers: [
    {
      name: "rke2-worker-1",
      ip: "192.168.100.11",
      cpus: 4, 
      memory: 32768,
      disk_size: "500GB"
    },
    {
      name: "rke2-worker-2",
      ip: "192.168.100.12",
      cpus: 4,
      memory: 32768, 
      disk_size: "500GB"
    }
  ]
}

Vagrant.configure("2") do |config|
  config.vm.box = "generic/ubuntu2204"
  
  # Create shared folder for token exchange
  config.vm.synced_folder ".", "/vagrant", type: "vmware"

  config.vm.provider "vmware_fusion" do |vmware|
    vmware.gui = false
    vmware.vmx["ethernet0.virtualDev"] = "e1000"
    
    # Performance optimizations
    vmware.vmx["mainMem.useNamedFile"] = "FALSE"
    vmware.vmx["sched.mem.pshare.enable"] = "FALSE" 
    vmware.vmx["prefvmx.useRecommendedLockedMemSize"] = "TRUE"
    vmware.vmx["MemTrimRate"] = "0"
  end

  # Master node
  config.vm.define "master", primary: true do |master|
    master.vm.hostname = CLUSTER_CONFIG[:master][:name]
    master.vm.network "private_network", ip: CLUSTER_CONFIG[:master][:ip]
    
    master.vm.provider "vmware_fusion" do |vmware|
      vmware.vmx["displayName"] = CLUSTER_CONFIG[:master][:name]
      vmware.vmx["memsize"] = CLUSTER_CONFIG[:master][:memory]
      vmware.vmx["numvcpus"] = CLUSTER_CONFIG[:master][:cpus]
      vmware.vmx["scsi0:0.size"] = CLUSTER_CONFIG[:master][:disk_size]
      vmware.vmx["scsi0:0.diskformat"] = "thin"
    end

    # Hosts file setup
    master.vm.provision "shell", inline: <<-SHELL
      hostnamectl set-hostname #{CLUSTER_CONFIG[:master][:name]}
      cat >> /etc/hosts << EOF
#{CLUSTER_CONFIG[:master][:ip]} #{CLUSTER_CONFIG[:master][:name]}
#{CLUSTER_CONFIG[:workers][0][:ip]} #{CLUSTER_CONFIG[:workers][0][:name]}
#{CLUSTER_CONFIG[:workers][1][:ip]} #{CLUSTER_CONFIG[:workers][1][:name]}
EOF
    SHELL

    # Common setup
    master.vm.provision "shell", inline: <<-SHELL
      echo "=== Master: Common Setup ==="
      export DEBIAN_FRONTEND=noninteractive
      apt-get update && apt-get upgrade -y
      apt-get install -y curl wget vim htop nfs-common open-iscsi util-linux cryptsetup
      
      # Kubernetes prerequisites
      swapoff -a
      sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
      
      cat > /etc/sysctl.d/99-kubernetes.conf << EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1  
net.ipv4.ip_forward = 1
vm.swappiness = 1
EOF
      
      modprobe br_netfilter
      echo 'br_netfilter' > /etc/modules-load.d/k8s.conf
      sysctl --system
      
      systemctl stop ufw && systemctl disable ufw
      systemctl enable --now iscsid
      mkdir -p /var/lib/longhorn
    SHELL

    # RKE2 master installation  
    master.vm.provision "shell", inline: <<-SHELL
      echo "=== Master: Installing RKE2 ==="
      curl -sfL https://get.rke2.io | sh -
      
      mkdir -p /etc/rancher/rke2
      cat > /etc/rancher/rke2/config.yaml << EOF
cluster-cidr: "10.42.0.0/16"
service-cidr: "10.43.0.0/16"
cni: "canal"
node-ip: #{CLUSTER_CONFIG[:master][:ip]}
advertise-address: #{CLUSTER_CONFIG[:master][:ip]}
bind-address: 0.0.0.0
secrets-encryption: true
protect-kernel-defaults: false
disable:
  - rke2-snapshot-controller
  - rke2-snapshot-controller-crd
  - rke2-snapshot-validation-webhook
kubelet-arg:
  - "max-pods=250"
EOF
      
      systemctl enable rke2-server.service
      systemctl start rke2-server.service
      
      # Wait for RKE2 to be ready
      until systemctl is-active --quiet rke2-server; do
        echo "Waiting for RKE2 server..."
        sleep 10
      done
      
      sleep 30
      
      # Setup kubectl access
      mkdir -p /home/vagrant/.kube
      cp /etc/rancher/rke2/rke2.yaml /home/vagrant/.kube/config
      chown vagrant:vagrant /home/vagrant/.kube/config
      
      # Add to PATH
      cat >> /home/vagrant/.bashrc << 'EOF'
export PATH=$PATH:/var/lib/rancher/rke2/bin
export KUBECONFIG=/home/vagrant/.kube/config
alias k=kubectl
EOF
      
      ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl
      
      # Share token for workers
      cp /var/lib/rancher/rke2/server/node-token /vagrant/node-token
      chmod 644 /vagrant/node-token
      
      echo "=== Master Setup Complete ==="
      echo "Token saved to shared folder for workers"
    SHELL
  end

  # Worker nodes
  CLUSTER_CONFIG[:workers].each_with_index do |worker, index|
    config.vm.define worker[:name] do |worker_vm|
      worker_vm.vm.hostname = worker[:name]
      worker_vm.vm.network "private_network", ip: worker[:ip]
      
      worker_vm.vm.provider "vmware_fusion" do |vmware|
        vmware.vmx["displayName"] = worker[:name]
        vmware.vmx["memsize"] = worker[:memory]
        vmware.vmx["numvcpus"] = worker[:cpus]
        vmware.vmx["scsi0:0.size"] = worker[:disk_size]
        vmware.vmx["scsi0:0.diskformat"] = "thin"
      end

      # Hosts file
      worker_vm.vm.provision "shell", inline: <<-SHELL
        hostnamectl set-hostname #{worker[:name]}
        cat >> /etc/hosts << EOF
#{CLUSTER_CONFIG[:master][:ip]} #{CLUSTER_CONFIG[:master][:name]}
#{CLUSTER_CONFIG[:workers][0][:ip]} #{CLUSTER_CONFIG[:workers][0][:name]}
#{CLUSTER_CONFIG[:workers][1][:ip]} #{CLUSTER_CONFIG[:workers][1][:name]}
EOF
      SHELL

      # Common setup (same as master)
      worker_vm.vm.provision "shell", inline: <<-SHELL
        echo "=== Worker #{worker[:name]}: Common Setup ==="
        export DEBIAN_FRONTEND=noninteractive
        apt-get update && apt-get upgrade -y
        apt-get install -y curl wget vim htop nfs-common open-iscsi util-linux cryptsetup
        
        swapoff -a
        sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
        
        cat > /etc/sysctl.d/99-kubernetes.conf << EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
vm.swappiness = 1
EOF
        
        modprobe br_netfilter
        echo 'br_netfilter' > /etc/modules-load.d/k8s.conf
        sysctl --system
        
        systemctl stop ufw && systemctl disable ufw
        systemctl enable --now iscsid
        mkdir -p /var/lib/longhorn
      SHELL

      # RKE2 worker installation
      worker_vm.vm.provision "shell", inline: <<-SHELL
        echo "=== Worker #{worker[:name]}: Installing RKE2 Agent ==="
        curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" sh -
        
        # Wait for master and token
        echo "Waiting for master to be ready and token to be available..."
        until curl -k https://#{CLUSTER_CONFIG[:master][:ip]}:9345 &> /dev/null && [ -f /vagrant/node-token ]; do
          echo "Waiting for master and token..."
          sleep 10
        done
        
        # Get token from shared folder
        TOKEN=$(cat /vagrant/node-token)
        
        mkdir -p /etc/rancher/rke2
        cat > /etc/rancher/rke2/config.yaml << EOF
server: https://#{CLUSTER_CONFIG[:master][:ip]}:9345
token: $TOKEN
node-label:
  - "node.longhorn.io/create-default-disk=true"
  - "node-role.kubernetes.io/worker=true"
kubelet-arg:
  - "max-pods=250"
EOF
        
        systemctl enable rke2-agent.service
        systemctl start rke2-agent.service
        
        echo "=== Worker #{worker[:name]} Setup Complete ==="
      SHELL
    end
  end

  # Final cluster setup (runs after all nodes are up)
  config.vm.define "master" do |master|
    master.vm.provision "shell", run: "always", inline: <<-SHELL
      # Only run if this is the final provision
      if [ "$1" = "--final" ]; then
        echo "=== Final Cluster Setup ==="
        export PATH=$PATH:/var/lib/rancher/rke2/bin
        export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
        
        # Wait for all nodes to be ready
        echo "Waiting for all nodes to be ready..."
        kubectl wait --for=condition=Ready nodes --all --timeout=600s
        
        echo "=== Cluster Status ==="
        kubectl get nodes -o wide
        
        echo "=== Installing Longhorn ==="
        kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.7.2/deploy/longhorn.yaml
        
        # Wait for Longhorn
        kubectl wait --for=condition=ready pod -l app=longhorn-manager -n longhorn-system --timeout=600s
        
        # Create optimized storage class
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
        
        kubectl apply -f /tmp/longhorn-storageclass.yaml
        
        # Test PVC
        cat > /tmp/test-pvc.yaml << 'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-longhorn-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn-fast
  resources:
    requests:
      storage: 1Gi
EOF
        
        kubectl apply -f /tmp/test-pvc.yaml
        
        echo "=== CLUSTER READY ==="
        echo "Nodes:"
        kubectl get nodes
        echo ""
        echo "Storage:"
        kubectl get storageclass
        kubectl get pvc
        echo ""
        echo "Longhorn UI: kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80"
        echo "Then visit: http://localhost:8080"
      fi
    SHELL
  end
end

# Usage Instructions:
# 1. Save this as Vagrantfile in an empty directory
# 2. Run: vagrant up
# 3. Wait 20-25 minutes for complete automated setup
# 4. Access: vagrant ssh master
# 5. Test: kubectl get nodes