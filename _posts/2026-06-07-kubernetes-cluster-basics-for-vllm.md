---
title: Kubernetes Cluster Basics for vLLM
excerpt: A practical Kubernetes primer for control planes, worker nodes, Deployments, ReplicaSets, Pods, Services, networking, storage, kubelet, the API server, kubeconfig, and GPU worker placement before deploying vLLM.
tags:
  - ai
  - inference
  - kubernetes
  - vllm
series: vllm-inference
---

The first post covered the vLLM serving path: tokenization, prefill, decode, KV cache, PagedAttention, and the API boundary. Before putting that service on Kubernetes, it helps to separate what Kubernetes itself is doing from what vLLM is doing.

This post is the cluster primer. It is about the control plane, worker nodes, Deployments, ReplicaSets, Pods, Services, networking, storage, kubelet, the container runtime, the API server, and why GPU workers need a little extra setup.

<!--more-->

{% include series-nav.html %}

## Control plane and workers

Before we put vLLM on Kubernetes, it helps to separate the cluster into two jobs. The control plane accepts the desired state, stores it, decides where work should run, and keeps checking that reality matches the plan. Worker nodes run the containers.

A small production-shaped cluster might have nine nodes:

- three control-plane nodes for high availability
- three CPU workers for routers, gateways, controllers, observability, and ordinary services
- three GPU workers for vLLM model servers

<figure class="diagram" aria-labelledby="k8s-cluster-diagram">
  <figcaption id="k8s-cluster-diagram" class="diagram__caption">Nine-node Kubernetes shape</figcaption>
  <div class="diagram__cluster">
    <div class="diagram__group diagram__cluster-group">
      <div class="diagram__group-title">Control plane quorum</div>
      <div class="diagram__cluster-grid diagram__cluster-grid--control">
        <div class="diagram__worker-pool">
          <div class="diagram__pool-title">control-plane-1</div>
          <div class="diagram__pool-items diagram__pool-items--stack">
            <div class="diagram__node diagram__node--compact">
              Node services
              <span class="diagram__note">systemd-managed kubelet and container runtime</span>
            </div>
            <div class="diagram__node diagram__node--compact">
              Static control-plane pods
              <span class="diagram__note">API server, scheduler, controllers, etcd member</span>
            </div>
          </div>
        </div>
        <div class="diagram__worker-pool">
          <div class="diagram__pool-title">control-plane-2</div>
          <div class="diagram__pool-items diagram__pool-items--stack">
            <div class="diagram__node diagram__node--compact">
              Node services
              <span class="diagram__note">systemd-managed kubelet and container runtime</span>
            </div>
            <div class="diagram__node diagram__node--compact">
              Static control-plane pods
              <span class="diagram__note">API server, scheduler, controllers, etcd member</span>
            </div>
          </div>
        </div>
        <div class="diagram__worker-pool">
          <div class="diagram__pool-title">control-plane-3</div>
          <div class="diagram__pool-items diagram__pool-items--stack">
            <div class="diagram__node diagram__node--compact">
              Node services
              <span class="diagram__note">systemd-managed kubelet and container runtime</span>
            </div>
            <div class="diagram__node diagram__node--compact">
              Static control-plane pods
              <span class="diagram__note">API server, scheduler, controllers, etcd member</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    <div class="diagram__connector diagram__connector--down" aria-hidden="true"></div>
    <div class="diagram__group diagram__cluster-group">
      <div class="diagram__group-title">Worker nodes</div>
      <div class="diagram__cluster-grid diagram__cluster-grid--workers">
        <div class="diagram__worker-pool">
          <div class="diagram__pool-title">CPU workers x3</div>
          <div class="diagram__pool-items">
            <div class="diagram__node diagram__node--compact">
              Node services
              <span class="diagram__note">systemd-managed kubelet and container runtime</span>
            </div>
            <div class="diagram__node diagram__node--compact">
              Scheduled pods
              <span class="diagram__note">ingress, router, metrics, ordinary services</span>
            </div>
          </div>
        </div>
        <div class="diagram__worker-pool diagram__worker-pool--accent">
          <div class="diagram__pool-title">GPU workers x3</div>
          <div class="diagram__pool-items">
            <div class="diagram__node diagram__node--compact">
              Node services
              <span class="diagram__note">systemd-managed kubelet and container runtime</span>
            </div>
            <div class="diagram__node diagram__node--compact diagram__node--accent">
              Scheduled pods
              <span class="diagram__note">vLLM model servers</span>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>
</figure>

Most cluster operations talk to the API server. `kubectl`, CI, controllers, schedulers, and kubelets all use the API server as the front door. The API server stores cluster state in etcd. The scheduler watches for Pods that do not have a node yet, picks a node that satisfies their constraints, and records that decision through the API server. The controller manager watches desired state and creates or updates objects to move the cluster toward it.

That controller manager is not one controller. It runs a collection of built-in control loops. In current upstream Kubernetes, the `kube-controller-manager` reference lists a little over 50 controller names, although a few are disabled by default and some only matter when the related feature or API is in use. You do not need to memorize all of them. The useful mental model is that each controller watches objects through the API server, compares desired state with observed state, and writes updates back through the API server.

The important groups to recognize are:

- **Workload controllers:** Deployment, ReplicaSet, StatefulSet, DaemonSet, Job, CronJob, and garbage-collector controllers.
- **Node and scheduling-adjacent controllers:** Node lifecycle, taint eviction, node IPAM, node route, and disruption controllers.
- **Service and networking controllers:** EndpointSlice, EndpointSlice mirroring, Endpoints, Service, Service CIDR, and service load balancer controllers.
- **Storage controllers:** persistent volume binder, attach-detach, expander, protection, and related volume controllers.
- **Security and API plumbing controllers:** ServiceAccount, ServiceAccount token, namespace, resource quota, certificate signing request, cluster role aggregation, and root CA publisher controllers.

Cloud-specific loops, such as creating cloud load balancers for `LoadBalancer` Services or managing cloud node lifecycle, are often handled by a separate cloud-controller-manager. Add-ons and operators can also run their own controllers outside the built-in controller manager; for example, an ingress controller, cert-manager, a CSI controller, or a custom model-serving operator.

Managed Kubernetes services change where some of this operational work lives. Amazon EKS, Azure AKS, and Google Kubernetes Engine manage the control plane for you: the API server, controller manager, scheduler, etcd backing store, upgrades, and high-availability shape are mostly provider-owned. They also usually integrate Kubernetes networking with the cloud VPC, load balancers, identity, and storage classes, which can make the first working cluster much easier than building every piece yourself.

That does not make the serving system managed end to end. You still need to choose and maintain worker node pools, including CPU and GPU pools; install or enable GPU device support; size nodes; plan rollouts; watch capacity; handle node drains and failures; tune storage for model weights; and decide how ingress, service mesh, NetworkPolicy, and autoscaling should behave. Managed Kubernetes removes a lot of control-plane maintenance, but vLLM serving still has the same practical concerns around warm capacity, GPU availability, model startup time, observability, and safe rollouts.

## The API server endpoint

In a kubeadm-style cluster, the API server process often appears as a static Pod mirrored into the `kube-system` namespace, with a name like `kube-apiserver-control-plane-1`. That Pod name tells you where one API server process is running. Your kubeconfig points at the Kubernetes API server endpoint clients should use:

```yaml
clusters:
  - name: kubernetes
    cluster:
      server: https://api.k8s.example.com:6443
      certificate-authority-data: ...
users:
  - name: paul@example.com
    user:
      token: ...
contexts:
  - name: prod
    context:
      cluster: kubernetes
      user: paul@example.com
```

That `server` URL is the API server address. In a single-node lab, it might be `https://192.0.2.10:6443`, pointing straight at the node running the API server. In a highly available cluster, it is usually a load balancer or DNS name in front of the API server instances on the three control-plane nodes.

The rest of the kubeconfig tells `kubectl` how to trust and authenticate to that endpoint. The cluster entry carries the certificate authority data, so the client can verify it is talking to the real API server. The user entry carries a credential, such as a bearer token, client certificate, or exec-based login plugin. The context ties the cluster and user together.

After the API server receives a request, it authenticates who the caller is, authorizes what that caller can do, and then runs admission checks before persisting the change. In a typical cluster, authorization is RBAC: a user, group, or service account is allowed to perform verbs like `get`, `list`, `create`, or `delete` against specific resource types in specific namespaces. That is why `kubectl get pods -n kube-system` and `kubectl delete deployment vllm-gpt-oss` are different security decisions, even though both go to the same API server endpoint.

Either way, `kubectl` is not talking directly to etcd and it is not SSHing to workers. It sends authenticated, authorized API requests to the API server because that is where validation, admission control, persistence, and watches happen.

## Static control-plane pods

How those control-plane components run depends on the Kubernetes distribution. On a common kubeadm-style Ubuntu setup, systemd starts kubelet and the container runtime, then kubelet starts the API server, scheduler, controller manager, and stacked etcd from static Pod manifests. "Static" means the kubelet reads local manifest files on that node and starts those pods directly, instead of waiting for the scheduler to place them like normal workload pods.

Those static pods usually show up in `kube-system` as mirror pods: Pod objects the kubelet creates in the API server to reflect static Pods it is already running from local manifests. This makes the Pod visible to `kubectl`, but the API object is not the source of truth. If you delete the mirror Pod through the API server, the kubelet keeps the static Pod running and recreates the mirror object. Other distributions may package or supervise pieces differently, and some clusters use external etcd. The important split is still the same: kubelet and the runtime are node-level services; the control-plane components are the Kubernetes brain running on the control-plane nodes.

## Worker nodes

The worker side is different. Each node runs a kubelet and a container runtime, usually as system services managed by systemd or the node image. Common Kubernetes runtimes are `containerd` and `CRI-O`; Docker Engine is familiar to many developers, but modern Kubernetes talks to runtimes through the Container Runtime Interface rather than using Docker as the normal node runtime. The kubelet watches the API server for Pods assigned to that node, asks the container runtime to start containers, reports Pod status back to the API server, and runs health probes. Networking is handled by the cluster CNI and service plumbing such as kube-proxy or an equivalent dataplane.

The kubelet is where a lot of control-plane decisions become host actions. The scheduler records that a Pod should run on a node, but kubelet on that node is what sees the assigned Pod, calls the container runtime, mounts volumes, wires in CNI networking, runs probes, and reports status. Node-level networking, logging, metrics, device plugins, and storage agents often run as DaemonSets so every relevant node gets the same helper Pods.

## Pods, ReplicaSets, Deployments, and Services

A Pod is the smallest schedulable workload unit in Kubernetes. It is one or more containers that share the same network namespace, Pod IP, volumes, and lifecycle. For vLLM, the simple case is one container running the vLLM server, sometimes with sidecars or init containers around it for auth, mesh proxying, metrics, or model download.

You usually do not create long-running Pods directly. A Deployment is the object you normally write for stateless services. It says what Pod template you want, how many replicas should exist, and how rollouts should behave. The Deployment controller creates a ReplicaSet for a specific version of that Pod template. The ReplicaSet controller then keeps the requested number of matching Pods alive.

The ownership chain is `Deployment` to `ReplicaSet` to `Pods`.

That chain matters during rollouts. When you change the Deployment's Pod template, Kubernetes creates a new ReplicaSet for the new version and gradually shifts replicas from the old ReplicaSet to the new one. If a Pod dies, the ReplicaSet replaces it. If a node dies, the scheduler can place replacement Pods on other suitable nodes.

Those controllers run as part of the control plane, usually inside `kube-controller-manager` on a kubeadm-style cluster. They do not start containers themselves. They create and update API objects. The scheduler and kubelets then act on those objects: the scheduler assigns unscheduled Pods to nodes, and kubelets on those nodes make the containers real.

A Service is different. It does not run your application, and it is not the same thing as an endpoint. A Service is the stable front door: it gives clients a durable DNS name and virtual address. Endpoints are the actual network destinations behind that front door, usually Pod IP and port pairs for Pods that match the Service selector and are ready to receive traffic. Modern Kubernetes represents those backend destinations with EndpointSlice objects, which scale better than the older Endpoints object.

For example, a Service might be named `vllm-gpt-oss`, select Pods with `app=vllm-gpt-oss`, and expose port `80`. The backing endpoints might be Pod addresses such as `10.42.1.25:8000`, `10.42.2.19:8000`, and `10.42.3.44:8000`. Clients use the Service name. Kubernetes keeps the endpoint list updated as Pods start, become ready, fail, or get replaced. That is why the Deployment's Pod labels and the Service selector have to match.

The EndpointSlice controller does that bookkeeping. It is one of the built-in controllers running in `kube-controller-manager` on a typical control plane. It watches Services and Pods through the API server. When Pods match a Service selector, it writes EndpointSlice objects in the same namespace, usually labeled with the Service name. Each slice contains a chunk of backend addresses, ports, protocol, and endpoint conditions such as whether a backend is ready, serving, or terminating. Splitting endpoints into slices avoids one giant Endpoints object for large Services.

For vLLM, this split is useful but limited. The Deployment and ReplicaSet can keep the desired number of model-server Pods alive. The Service can give routers and clients a stable in-cluster name. But Kubernetes is still operating at the Pod and endpoint level; it does not know which vLLM replica has KV cache pressure, a long decode queue, or enough capacity for the next request.

## Networking basics

Kubernetes networking starts with Pod IPs. The cluster CNI plugin gives Pods network connectivity and decides how traffic moves between nodes. Common CNIs include Calico, Cilium, Flannel, and cloud-provider CNIs. The implementation details differ, but the goal is the same: a Pod should be able to talk to another Pod by IP without the application knowing which node either Pod is on.

Pod IPs are not a stable API for clients. Pods are created, deleted, rescheduled, and replaced during rollouts. The Service is the stable name clients use; EndpointSlices are the changing backend destinations the dataplane can send traffic to. For example, a Service named `vllm-gpt-oss` in namespace `inference` gets an internal DNS name like `vllm-gpt-oss.inference.svc.cluster.local`. The cluster dataplane then sends traffic to a ready endpoint behind that Service.

EndpointSlices are API data, not packet forwarding by themselves. Several network components watch that data. CoreDNS uses Services and EndpointSlices to answer cluster DNS names. `kube-proxy` watches Services and EndpointSlices and programs iptables or IPVS rules so traffic to a Service virtual IP lands on one of the ready backend Pod IPs. eBPF dataplanes such as Cilium can watch the same API objects and program eBPF load-balancing maps instead of using kube-proxy. Ingress controllers, Gateway API controllers, service meshes, and model-aware routers may also watch Services, EndpointSlices, or Pod labels to discover backends.

The CNI still matters underneath all of that. Once a backend Pod IP is chosen, the CNI-provided node network is what makes that Pod IP reachable, possibly across nodes. If NetworkPolicy is enabled, the CNI or dataplane also enforces whether the source Pod is allowed to connect to that destination. You usually do not design the application around whether the cluster uses kube-proxy, IPVS, or eBPF, but it matters operationally for performance, observability, NetworkPolicy behavior, and debugging.

Traffic from outside the cluster usually enters through an ingress controller, Gateway API implementation, cloud load balancer, or service mesh gateway. That edge layer is where TLS termination, public DNS, coarse routing, and external auth often live. Inside the cluster, Services and DNS connect the edge, routers, model servers, metrics, and storage helpers.

Service type controls how a Service is exposed:

| Type | What it gives you | Where it fits |
| --- | --- | --- |
| `ClusterIP` | An internal virtual IP and DNS name reachable inside the cluster. This is the default. | Good for router-to-vLLM traffic inside the cluster. |
| `NodePort` | Opens a port on each node and forwards to the Service. | Useful for simple labs or as a building block behind some load balancers, but usually not the final production edge. |
| `LoadBalancer` | Asks the cloud or infrastructure integration to create an external load balancer that forwards to the Service. | Common managed-cluster way to expose ingress gateways or edge services. |
| `ExternalName` | Returns a DNS CNAME to an external name instead of selecting Pods. | Useful for pointing in-cluster clients at an external service, not for routing to vLLM Pods. |
| Headless Service | Uses `clusterIP: None`, so DNS returns backend records instead of one Service virtual IP. | Useful when clients need to discover individual backends directly. |

These types interact with different parts of the network stack. `ClusterIP` and `NodePort` rely on kube-proxy or an equivalent eBPF dataplane watching Services and EndpointSlices. `LoadBalancer` also involves a cloud-controller-manager or load balancer controller that talks to infrastructure outside the cluster. `ExternalName` is mostly a DNS behavior handled through CoreDNS. Headless Services lean more heavily on DNS and EndpointSlices because clients may receive individual backend addresses rather than a single virtual IP.

NetworkPolicy is the security control for Pod-to-Pod traffic when the CNI supports it. Without policy, many clusters allow broad east-west traffic by default. With policy, you can say that only the model-aware router may connect to vLLM Pods on port `8000`, while metrics collectors may scrape `/metrics` and unrelated workloads cannot reach the model server at all.

For vLLM, the common request path is:

<figure class="diagram diagram--flow" aria-labelledby="external-vllm-traffic-diagram">
  <figcaption id="external-vllm-traffic-diagram" class="diagram__caption">External traffic to vLLM</figcaption>
  <div class="diagram__pipeline">
    <div class="diagram__node diagram__node--wide">
      Client
      <span class="diagram__note">browser, SDK, batch job, or agent</span>
    </div>
    <div class="diagram__connector diagram__connector--down" aria-hidden="true"></div>
    <div class="diagram__node diagram__node--wide">
      Edge load balancer or ingress
      <span class="diagram__note">public DNS, TLS, auth, request limits</span>
    </div>
    <div class="diagram__connector diagram__connector--down" aria-hidden="true"></div>
    <div class="diagram__node diagram__node--wide">
      Model-aware router
      <span class="diagram__note">chooses a model backend from live inference state</span>
    </div>
    <div class="diagram__connector diagram__connector--down" aria-hidden="true"></div>
    <div class="diagram__node diagram__node--wide">
      vLLM Service
      <span class="diagram__note">stable name; kube-proxy or eBPF dataplane sends traffic to an endpoint</span>
    </div>
    <div class="diagram__connector diagram__connector--down" aria-hidden="true"></div>
    <div class="diagram__node diagram__node--wide diagram__node--accent">
      Ready vLLM Pod
      <span class="diagram__note">CNI provides Pod networking; response may stream for a long time</span>
    </div>
  </div>
</figure>

This is also where inference behavior affects networking choices. Chat and completion responses may stream for a long time, so gateway, ingress, router, and client timeouts need to allow streaming responses. Readiness should keep cold Pods out of Service endpoints until the model is loaded. If a Pod dies mid-stream, the connection fails; another replica can handle a retry, but it starts a new request because the KV cache lived in the failed Pod.

Internal traffic uses the same primitives. A router Pod calling a vLLM Pod still depends on Pod IP connectivity from the CNI, Service discovery, and the cluster dataplane. If a service mesh is installed, each application container may talk through a local sidecar or node proxy first. The mesh can add mTLS, retries, telemetry, and authorization policy, but the CNI still provides the underlying Pod network.

<figure class="diagram" aria-labelledby="mesh-pod-traffic-diagram">
  <figcaption id="mesh-pod-traffic-diagram" class="diagram__caption">Pod-to-Pod traffic with a service mesh</figcaption>
  <div class="diagram__traffic-grid">
    <div class="diagram__group">
      <div class="diagram__group-title">Source Pod on a CPU worker</div>
      <div class="diagram__grid diagram__grid--stack">
        <div class="diagram__node">
          Router container
          <span class="diagram__note">sends request to service name</span>
        </div>
        <div class="diagram__node">
          Mesh proxy
          <span class="diagram__note">mTLS, policy, telemetry</span>
        </div>
      </div>
    </div>
    <div class="diagram__connector" aria-hidden="true"></div>
    <div class="diagram__transit">
      <div class="diagram__node">
        Service and dataplane
        <span class="diagram__note">CoreDNS resolves the Service; EndpointSlices feed kube-proxy or eBPF</span>
      </div>
      <div class="diagram__connector diagram__connector--down" aria-hidden="true"></div>
      <div class="diagram__node">
        CNI / node network
        <span class="diagram__note">moves packets between Pod IPs, even across nodes</span>
      </div>
    </div>
    <div class="diagram__connector" aria-hidden="true"></div>
    <div class="diagram__group">
      <div class="diagram__group-title">Destination Pod on a GPU worker</div>
      <div class="diagram__grid diagram__grid--stack">
        <div class="diagram__node">
          Mesh proxy
          <span class="diagram__note">receives and verifies mesh traffic</span>
        </div>
        <div class="diagram__node diagram__node--accent">
          vLLM container
          <span class="diagram__note">handles the full inference request</span>
        </div>
      </div>
    </div>
  </div>
</figure>

CoreDNS is the usual in-cluster DNS service. Pods normally use the cluster DNS Service as their resolver. When a Pod asks for `vllm-gpt-oss.inference.svc.cluster.local`, CoreDNS can answer from Kubernetes service data. When it asks for an external name, CoreDNS usually forwards the query to an upstream resolver.

<figure class="diagram" aria-labelledby="coredns-flow-diagram">
  <figcaption id="coredns-flow-diagram" class="diagram__caption">CoreDNS lookup flow</figcaption>
  <div class="diagram__dns-grid">
    <div class="diagram__dns-column">
      <div class="diagram__node diagram__node--wide">
        Application Pod
        <span class="diagram__note">looks up vLLM Service or external model registry</span>
      </div>
      <div class="diagram__connector diagram__connector--down" aria-hidden="true"></div>
      <div class="diagram__node diagram__node--wide">
        kube-dns Service
        <span class="diagram__note">stable cluster DNS address in front of CoreDNS Pods</span>
      </div>
      <div class="diagram__connector diagram__connector--down" aria-hidden="true"></div>
      <div class="diagram__node diagram__node--wide diagram__node--accent">
        CoreDNS Pods
        <span class="diagram__note">answer cluster names or forward external names</span>
      </div>
    </div>
    <div class="diagram__connector" aria-hidden="true"></div>
    <div class="diagram__group">
      <div class="diagram__group-title">Answer source</div>
      <div class="diagram__grid diagram__grid--two">
        <div class="diagram__node">
          Kubernetes API data
          <span class="diagram__note">Services, EndpointSlices, namespaces</span>
        </div>
        <div class="diagram__node">
          Upstream DNS
          <span class="diagram__note">external names such as object stores or registries</span>
        </div>
      </div>
    </div>
  </div>
</figure>

## Storage basics

Storage matters for vLLM because model weights are large. If every new Pod downloads the model from the internet or a model registry at startup, rollouts get slower, failures take longer to recover from, and the registry becomes part of your serving path. Kubernetes gives you a few ways to make that more predictable, but it helps to separate the objects.

A `StorageClass` describes a kind of storage the cluster can provision, such as cloud block storage, network file storage, or local NVMe-backed storage. A `PersistentVolume` is the actual storage resource. A `PersistentVolumeClaim` is a Pod's request for storage. The Container Storage Interface, or CSI, is the plugin interface that lets Kubernetes talk to storage systems from cloud providers, SAN/NAS systems, local disk operators, and other storage backends.

The usual application manifest does not create a disk directly. It asks for one:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: model-cache
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: fast-ssd
  resources:
    requests:
      storage: 500Gi
```

Then a Pod mounts that claim as a volume. The CSI driver and storage class decide how the backing volume is created and attached.

Storage also has control-plane and node-side pieces. The Kubernetes control plane records the PVC and PV objects. A CSI controller, usually running as Pods in the cluster, provisions or attaches storage by talking to the storage backend. A CSI node plugin, usually a DaemonSet, runs on worker nodes and handles node-local mount work so kubelet can make the volume available to the Pod.

For model serving, the tradeoff is not just "persistent or not." It is startup time, throughput, sharing, and failure behavior. An `emptyDir` cache is simple and fast when backed by local disk, but it disappears when the Pod is deleted. A PVC can survive Pod restarts, but a `ReadWriteOnce` volume usually attaches to one node at a time. `ReadWriteMany` storage can be shared by multiple Pods, but the network filesystem has to handle many readers pulling large model files. Local NVMe can be very fast, but it ties the cache to a node, so rescheduling to another node may require another download.

`emptyDir` is node-local ephemeral storage managed by kubelet. On many Linux nodes, that data lives under kubelet's root directory, commonly `/var/lib/kubelet`, along with pod volume state and other node-local pod data. That makes node volume layout matter. If kubelet storage sits on the root filesystem, large model downloads can fill or pressure the same disk the OS depends on. If it sits on its own volume, you can size, monitor, and tune that path separately. For model caches, this is a heavy I/O path, so disk type and layout matter: slow network-backed root disks, small boot volumes, or noisy shared disks can turn model startup into an operational bottleneck.

The practical question is where model weights should live before the server becomes ready. Common patterns include downloading into a PVC during init, prewarming node-local caches, baking smaller artifacts into an image, or using a shared filesystem/object-store gateway when the storage system can handle the load. Another common pattern is syncing from object storage into local serving storage: keep the model artifact in S3, GCS, Azure Blob, or an internal object store, then use an init container, sidecar, or node-level sync process to copy it into a PVC or node-local cache before vLLM starts. That keeps object storage as the durable source of truth while serving from local disk or a Kubernetes volume. Whatever you choose, readiness should wait until the model is actually present and loaded.

For vLLM, the GPU workers have one extra requirement: the NVIDIA device plugin, or an equivalent GPU device plugin, must advertise GPU capacity to Kubernetes. Without that, the scheduler cannot see `nvidia.com/gpu` as a resource. With it, Pods that request GPUs can be placed on nodes that have available GPUs.

The device plugin is another bridge between node hardware and the control plane. It usually runs as a DaemonSet on GPU nodes, talks to kubelet through the Kubernetes device plugin interface, and reports allocatable resources such as `nvidia.com/gpu`. Kubelet publishes that node capacity back to the API server. The scheduler then sees GPU capacity when deciding where a Pod with a GPU request can run.

That does not automatically mean only GPU workloads can run on GPU nodes. A normal CPU-only Pod can still run there unless you add placement policy. Labels identify node properties, such as `accelerator=nvidia` or `nodepool=gpu`. Node selectors or node affinity can ask the scheduler to place vLLM Pods on nodes with those labels. Taints and tolerations solve the opposite problem: taint GPU nodes so ordinary workloads stay off them, then give vLLM Pods a matching toleration. Some teams keep GPU nodes reserved for model serving plus required node-level DaemonSets such as networking, logging, metrics, and device plugins. Others allow CPU workloads such as local routers, sidecars, or GPU-adjacent preprocessing to run there. The right choice is an operations policy, not something Kubernetes decides by itself.

GPU nodes also tend to need more hardware-aware maintenance than ordinary CPU workers: driver updates, CUDA/runtime compatibility, device plugin changes, firmware, cooling, and sometimes cloud instance or bare-metal repairs. You should plan for node failure, patching, and maintenance in every Kubernetes pool, but GPU pools deserve extra capacity planning. If one GPU node is drained for maintenance, the remaining nodes still need enough room to keep the required model replicas online. That is the practical reason to run more than one GPU worker and to think about serving capacity during maintenance, not only during normal traffic.

In the nine-node picture, the usual placement is simple: keep the control-plane nodes focused on cluster control, run the ingress or model-aware router on CPU workers, and schedule vLLM model pods on GPU workers.

## The takeaway

Kubernetes is an API-driven control system. Clients talk to the API server, the control plane reconciles desired state, and kubelets on nodes do the local work of running containers.

For vLLM, that means the Kubernetes layer can place pods, attach storage, route traffic through Services, watch health, and roll out changes. It still needs GPU-aware nodes, a plan for model weights, network policy, streaming-aware timeouts, and inference-specific observability. That is where the next post starts.
