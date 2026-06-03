#! /bin/sh

#set -x

if [ $# != 1 ]; then
	echo 'Usage: build-cluster.sh <network interface>'
	exit 1
fi
netif=$1; shift

# Install Podman packages and supporting utilities which are also needed for
# Kubernetes
echo "Installing and initialising podman-suite"
sudo env ASSUME_ALWAYS_YES=yes pkg update
sudo pkg install -y podman-suite
sudo kldload nullfs
sudo kldload fdescfs
sudo kldload if_bridge
sudo kldload pf
sudo sysrc kld_list="nullfs fdescfs if_bridge pf"

ensure_sysctl() {
	local var=$1; shift
	grep -q ${var} /etc/sysctl.conf || (
		echo ${var} | sudo tee -a /etc/sysctl.conf > /dev/null
	)
}

# Sysctl settings to allow routing and filtering for cluster network traffic
ensure_sysctl 'net.pf.filter_local=1'
ensure_sysctl 'net.inet.ip.forwarding=1'
ensure_sysctl 'net.link.bridge.pfil_member=1'
sudo service sysctl start

# Set up a simple PF config which is needed for container networking
if [ ! -f /etc/pf.conf ]; then
	cat >> pf.conf-tmp <<EOF
v4egress_if = "${netif}"
v6egress_if = "${netif}"

nat on \$v4egress_if inet from <cni-nat> to any -> (\$v4egress_if)
nat on \$v6egress_if inet6 from <cni-nat> to !ff00::/8 -> (\$v6egress_if)

rdr-anchor "cni-rdr/*"
nat-anchor "cni-rdr/*"
table <cni-nat>
EOF
	sudo mv pf.conf-tmp /etc/pf.conf
	sudo sysrc pf_enable=YES
	sudo service pf restart
fi

# Setup container storage
if [ ! -d /var/db/containers ]; then
	sudo zfs create -o mountpoint=/var/db/containers zroot/containers
fi

# Install build tools needed for building Kubernetes components from source.
echo "Installing packages needed to build and use cluster components"
sudo pkg install -y go gmake gsed git-lite bash pkgconf coreutils kubectl

# Build and install crictl
echo "Building crictl tool for troubleshooting CRI-O problems"
if [ ! -d cri-tools ]; then
	git clone https://github.com/kubernetes-sigs/cri-tools.git
fi
(
	cd cri-tools
	git pull
	gmake
	sudo install build/bin/freebsd/amd64/crictl /usr/local/bin
	# TODO sudo
	cat >crictl.yaml-tmp <<EOF
runtime-endpoint: "unix:///var/run/crio/crio.sock"
timeout: 0
debug: false
EOF
	sudo mv crictl.yaml-tmp /usr/local/etc/crictl.yaml
)

# Build and install CRI-O
echo "Building CRI-O"
if [ ! -d cri-o ]; then
	git clone -b freebsd-wip-1.33.0 https://github.com/dfr/cri-o.git
fi
(
	if [ -f /usr/local/etc/rc.d/crio ]; then
		sudo service crio stop
	fi
	cd cri-o
	git pull
	gmake bin/crio
	sudo install bin/crio /usr/local/bin
	sudo install contrib/freebsd/crio /usr/local/etc/rc.d
	sudo sysrc crio_enable=YES
)

# Build and install kubelet
echo "Building kubelet, the node agent running on each node in the cluster"
if [ ! -d kubernetes ]; then
	git clone https://github.com/kubernetes/kubernetes.git
fi
(
	if [ -f /usr/local/etc/rc.d/kubelet ]; then
		sudo service kubelet stop
	fi
	sudo install -m 755 files/kubelet /usr/local/etc/rc.d
	cd kubernetes
	git remote add dfr https://github.com/dfr/kubernetes.git
	git fetch dfr
	git checkout freebsd-kubelet-v1.31.0-alpha
	gmake WHAT=cmd/kubelet
	sudo install _output/local/go/bin/kubelet /usr/local/bin
	sudo sysrc kubelet_enable=YES
)

# Build and install kubeadm
echo "Building kubeadm, a tool for creating and managing clusters"
(
	cd kubernetes
	git checkout freebsd-kubeadm-v1.31.0-alpha
	gmake WHAT=cmd/kubeadm
	sudo install _output/local/go/bin/kubeadm /usr/local/bin
)

# Build a single node cluster using kubeadm
echo "Building a single node cluster"
cat >kubeadm-config.yaml <<EOF
kind: ClusterConfiguration
apiVersion: kubeadm.k8s.io/v1beta3
imageRepository: ghcr.io/dfr
kubernetesVersion: v1.31.0-alpha
networking:
  serviceSubnet: 10.96.0.0/12
  podSubnet: 10.244.0.0/16
---
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
serverTLSBootstrap: true
EOF

sudo service crio start
while [ ! -S /var/run/crio/crio.sock ]; do
	echo "Waiting for crio to start"
	sleep 1
done
echo "crio is running"

sudo kubeadm init --config ./kubeadm-config.yaml || exit 1
mkdir -p $HOME/.kube
sudo cp /usr/local/etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Approve node TLS signing requests
sleep 1
kubectl get csr --no-headers | cut -w -f1 | xargs kubectl certificate approve

# Remove taints from our single node so that we can schedule non control plane
# workloads
kubectl taint nodes --all node-role.kubernetes.io/control-plane-

# Install a simple network configuration to allow allocating IP addresses for
# pods
sudo install -m 644 files/10-kubetest.conflist /usr/local/etc/cni/net.d

echo "If everything worked right, the cluster should be live"
kubectl get all -A
