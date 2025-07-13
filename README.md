FreeBSD Kubernetes Tech Demo
============================

Use this guide to download FreeBSD versions of core Kubernetes components, build
them from source and start a FreeBSD native test cluster.

Firstly, prepare a FreeBSD host or VM, installing FreeBSD-14.3-RELEASE, install
git-lite and clone this repository:

```
git clone https://github.com/dfr/kubernetes-demo.git demo
cd demo
```

Now run the build script. This installs packages needed by the cluster before downloading
source for components not yet available from the FreeBSD package collection and
building them.

After building all the components, it creates a single-node cluster. The build
script takes one argument which should be the 'upstream' network interface for
the host:

```
./build-cluster.sh vtnet0
```

If this works as intended, the cluster will be running and kubectl can be used
to examine the result and run workloads.

```
kubectl get all -A
```

Notes
=====

This software is intended as a demonstration of a FreeBSD-native Kubernetes
cluster and should be used only for experimentation and evaluation. It will
install tools and container images built from Kubernetes which include patches
from me that are not reviewed, endorsed or supported by the Kubernetes project.

The example network configuration does not NAT outgoing IP traffic from the
cluster which may not be routed correctly, depending on the local network
setup. For a single-node cluster, NAT can be enabled by changing `"ipMasq"` in
`files/10-kubetest.conflist` to `true`.
