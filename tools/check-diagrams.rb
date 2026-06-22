#!/usr/bin/env ruby
# frozen_string_literal: true

def fail_check(message)
  warn "diagram check failed: #{message}"
  exit 1
end

def assert(condition, message)
  fail_check(message) unless condition
end

def read(path)
  assert(File.file?(path), "missing #{path}")
  File.read(path)
end

def ordered?(content, terms)
  offset = 0

  terms.all? do |term|
    index = content.index(term, offset)
    if index
      offset = index + term.length
      true
    else
      false
    end
  end
end

site_html_paths = Dir["_site/**/*.html"]
assert(!site_html_paths.empty?, "no built HTML files found; run the Jekyll build first")

site_html_paths.each do |path|
  html = read(path)
  assert(!html.include?("mermaid"), "#{path} still references Mermaid")
  assert(!html.include?("flowchart"), "#{path} still contains graph source text")
  assert(!html.include?("language-mermaid"), "#{path} still renders Mermaid as a code block")
  assert(!html.include?("language-text"), "#{path} still renders conceptual diagrams as text code")

  html.scan(/<figure class="diagram(?: [^"]*)?" aria-labelledby="([^"]+)">([\s\S]*?)<\/figure>/).each do |caption_id, figure|
    expected_caption = %(<figcaption id="#{caption_id}" class="diagram__caption">)
    assert(figure.include?(expected_caption), "#{path} diagram #{caption_id} is missing a matching caption")
  end
end

vllm_path = "_site/2026/05/21/vllm-inference-101/index.html"
cluster_basics_path = "_site/2026/06/07/kubernetes-cluster-basics-for-vllm/index.html"
kubernetes_path = "_site/2026/06/14/vllm-kubernetes/index.html"
rbac_path = "_site/2026/06/18/kubernetes-rbac-basics-for-vllm/index.html"
security_path = "_site/2026/06/20/vllm-kubernetes-security-rbac/index.html"
vllm_html = read(vllm_path)
cluster_basics_html = read(cluster_basics_path)
kubernetes_html = read(kubernetes_path)
rbac_html = read(rbac_path)
security_html = read(security_path)

figure_count = vllm_html.scan(/<figure class="diagram(?: [^"]*)?" aria-labelledby="/).length
assert(figure_count == 2, "expected 2 diagrams in the vLLM 101 post, found #{figure_count}")

kubernetes_figure_count = kubernetes_html.scan(/<figure class="diagram(?: [^"]*)?" aria-labelledby="/).length
assert(
  kubernetes_figure_count == 2,
  "expected 2 diagrams in the vLLM Kubernetes post, found #{kubernetes_figure_count}"
)

cluster_basics_figure_count = cluster_basics_html.scan(/<figure class="diagram(?: [^"]*)?" aria-labelledby="/).length
assert(
  cluster_basics_figure_count == 4,
  "expected 4 diagrams in the Kubernetes cluster basics post, found #{cluster_basics_figure_count}"
)

rbac_figure_count = rbac_html.scan(/<figure class="diagram(?: [^"]*)?" aria-labelledby="/).length
assert(
  rbac_figure_count == 2,
  "expected 2 diagrams in the Kubernetes RBAC basics post, found #{rbac_figure_count}"
)

security_figure_count = security_html.scan(/<figure class="diagram(?: [^"]*)?" aria-labelledby="/).length
assert(
  security_figure_count == 1,
  "expected 1 diagram in the vLLM security post, found #{security_figure_count}"
)

serving_match = vllm_html.match(/<figure class="diagram diagram--flow" aria-labelledby="serving-path-diagram">([\s\S]*?)<\/figure>/)
assert(serving_match, "missing serving path diagram")
serving = serving_match[1]

assert(serving.include?("diagram__pipeline"), "serving diagram must use the centered pipeline layout")
assert(serving.include?("diagram__service"), "serving diagram must group vLLM internals in one service boundary")
assert(serving.include?("diagram__stages"), "serving diagram must render vLLM internals as ordered stages")
assert(!serving.include?("diagram__grid"), "serving diagram must not use the generic card grid")

assert(
  ordered?(
    serving,
    [
      "Client request",
      "vLLM service",
      "API server",
      "HTTP request handling",
      "Input processing",
      "Tokenization happens here",
      "Engine core",
      "Scheduler and KV cache",
      "GPU worker",
      "Prefill and decode passes",
      "Stream response"
    ]
  ),
  "serving diagram must keep tokenization inside the vLLM service boundary"
)

assert(
  vllm_html.include?(%(<a href="https://docs.ollama.com/quickstart">quickstart guide</a>)),
  "vLLM 101 post must link to the Ollama quickstart guide"
)

cluster_match = cluster_basics_html.match(/<figure class="diagram" aria-labelledby="k8s-cluster-diagram">([\s\S]*?)<\/figure>/)
assert(cluster_match, "missing Kubernetes cluster diagram")
cluster = cluster_match[1]

assert(cluster.include?("diagram__cluster"), "cluster diagram must use the cluster layout")
assert(cluster.include?("diagram__cluster-grid--control"), "cluster diagram must show control-plane nodes")
assert(cluster.include?("diagram__cluster-grid--workers"), "cluster diagram must show worker nodes")
assert(cluster.include?("diagram__worker-pool"), "cluster diagram must group worker pools")
assert(cluster.include?("diagram__pool-items"), "cluster diagram must separate node services from scheduled pods")
assert(cluster.include?("diagram__pool-items--stack"), "cluster diagram must stack control-plane node internals")

assert(
  ordered?(
    cluster,
    [
      "Control plane quorum",
      "control-plane-1",
      "Node services",
      "systemd-managed kubelet and container runtime",
      "Static control-plane pods",
      "API server, scheduler, controllers, etcd member",
      "control-plane-2",
      "Node services",
      "systemd-managed kubelet and container runtime",
      "Static control-plane pods",
      "API server, scheduler, controllers, etcd member",
      "control-plane-3",
      "Node services",
      "systemd-managed kubelet and container runtime",
      "Static control-plane pods",
      "API server, scheduler, controllers, etcd member",
      "Worker nodes",
      "CPU workers x3",
      "Node services",
      "systemd-managed kubelet and container runtime",
      "Scheduled pods",
      "ingress, router, metrics, ordinary services",
      "GPU workers x3",
      "Node services",
      "systemd-managed kubelet and container runtime",
      "Scheduled pods",
      "vLLM model servers"
    ]
  ),
  "cluster diagram no longer matches the 3 control-plane / CPU worker pool / GPU worker pool shape"
)

external_match = cluster_basics_html.match(/<figure class="diagram diagram--flow" aria-labelledby="external-vllm-traffic-diagram">([\s\S]*?)<\/figure>/)
assert(external_match, "missing external vLLM traffic diagram")
external = external_match[1]

assert(
  ordered?(
    external,
    [
      "External traffic to vLLM",
      "Client",
      "Edge load balancer or ingress",
      "Model-aware router",
      "vLLM Service",
      "kube-proxy or eBPF dataplane sends traffic to an endpoint",
      "Ready vLLM Pod",
      "CNI provides Pod networking"
    ]
  ),
  "external traffic diagram no longer shows client -> ingress -> router -> service -> ready vLLM pod"
)

mesh_match = cluster_basics_html.match(/<figure class="diagram" aria-labelledby="mesh-pod-traffic-diagram">([\s\S]*?)<\/figure>/)
assert(mesh_match, "missing mesh Pod-to-Pod traffic diagram")
mesh = mesh_match[1]

assert(
  ordered?(
    mesh,
    [
      "Pod-to-Pod traffic with a service mesh",
      "Source Pod on a CPU worker",
      "Router container",
      "Mesh proxy",
      "Service and dataplane",
      "CoreDNS resolves the Service; EndpointSlices feed kube-proxy or eBPF",
      "CNI / node network",
      "moves packets between Pod IPs, even across nodes",
      "Destination Pod on a GPU worker",
      "Mesh proxy",
      "vLLM container"
    ]
  ),
  "mesh traffic diagram no longer shows router -> mesh -> service/dataplane -> CNI -> vLLM"
)
assert(mesh.include?("diagram__traffic-grid"), "mesh traffic diagram must use the left/right traffic layout")
assert(mesh.include?("diagram__transit"), "mesh traffic diagram must keep service/dataplane and CNI in the middle column")
assert(mesh.include?("diagram__grid diagram__grid--stack"), "mesh pod internals must stack inside each pod boundary")

coredns_match = cluster_basics_html.match(/<figure class="diagram" aria-labelledby="coredns-flow-diagram">([\s\S]*?)<\/figure>/)
assert(coredns_match, "missing CoreDNS flow diagram")
coredns = coredns_match[1]

assert(
  ordered?(
    coredns,
    [
      "CoreDNS lookup flow",
      "Application Pod",
      "kube-dns Service",
      "CoreDNS Pods",
      "answer cluster names or forward external names",
      "Answer source",
      "Kubernetes API data",
      "Services, EndpointSlices, namespaces",
      "Upstream DNS",
      "external names such as object stores or registries"
    ]
  ),
  "CoreDNS diagram no longer shows pod -> kube-dns Service -> CoreDNS -> API data or upstream DNS"
)
assert(coredns.include?("diagram__dns-grid"), "CoreDNS diagram must use the left/right DNS layout")
assert(coredns.include?("diagram__grid--two"), "CoreDNS answer sources must render as two columns on desktop")

probe_match = kubernetes_html.match(/<figure class="diagram" aria-labelledby="probe-timing-diagram">([\s\S]*?)<\/figure>/)
assert(probe_match, "missing probe timing diagram")
probe = probe_match[1]

assert(
  ordered?(
    probe,
    [
      "Probe timing examples",
      "Safe vLLM startup",
      "Model load",
      "Startup probe",
      "10s period x 60 failures = 600s budget",
      "Readiness probe",
      "controls Service endpoints",
      "Liveness probe",
      "disabled by startupProbe",
      "Too aggressive",
      "Model load",
      "needs about 110s",
      "Liveness probe",
      "30s period x 3 failures = about 90s",
      "restart",
      "pod never reaches readiness"
    ]
  ),
  "probe timing diagram no longer explains safe startup and too-aggressive liveness timing"
)
assert(probe.include?("diagram__probe-model"), "probe timing diagram must use the probe model layout")
assert(probe.include?("diagram__probe-track"), "probe timing diagram must render probe tracks")
assert(probe.include?("diagram__probe-segment--danger"), "probe timing diagram must show restart loop risk")
assert(!probe.include?("diagram__probe-point"), "probe timing diagram should use aligned bubbles, not point markers")

router_match = kubernetes_html.match(/<figure class="diagram" aria-labelledby="router-diagram">([\s\S]*?)<\/figure>/)
assert(router_match, "missing router diagram")
router = router_match[1]

assert(
  ordered?(
    router,
    [
      "Client",
      "Edge LB / Ingress",
      "Model-aware router",
      "diagram__connector diagram__connector--down diagram__connector--route-out",
      "Replica pool for one served model",
      "Select one ready replica per request",
      "vLLM pod A",
      "vLLM pod B",
      "vLLM pod C"
    ]
  ),
  "router diagram no longer matches client -> ingress -> router -> one selected replica"
)

assert(
  kubernetes_html.include?("The selected worker still does the whole request."),
  "router post text must state that one worker handles the request"
)

[
  "Startup time is not one thing. It is a chain:",
  "Image pull",
  "Model download",
  "Storage read path",
  "Checkpoint format",
  "Model size and dtype",
  "Context length and KV cache",
  "Different models change the startup budget in predictable ways.",
  "Make the cache path explicit with",
  "Use <code class=\"language-plaintext highlighter-rouge\">--load-format</code> only when you know why that format matches your checkpoint and storage path.",
  "scale up quickly from sustained queue or cache pressure, scale down slowly",
  "Fast scale-up matters because new vLLM capacity is late capacity.",
  "Slow scale-down matters for the opposite reason.",
  "Zero-downtime scale-down is not just an HPA setting. It is a drain path:",
  "The safest pattern is: stop admitting new requests first, wait for in-flight requests to finish",
  "Testing graceful scale-down",
  "Manual pod termination:",
  "Deployment scale-down:",
  "HPA downscale:",
  "Add a negative test too.",
  "If you cannot observe those, you cannot really know whether scale-down is zero-downtime."
].each do |needle|
  assert(kubernetes_html.include?(needle), "HPA section missing scale-up/scale-down guidance #{needle.inspect}")
end

[
  "Kubernetes RBAC Basics for vLLM Operators",
  "RBAC is how Kubernetes decides who can do what to Kubernetes API objects.",
  "Kubernetes supports several authorizer modes, including RBAC, Node, Webhook, ABAC, AlwaysAllow, and AlwaysDeny.",
  "RBAC is the main authorizer you use for human users, service accounts, CI, and controllers",
  "the Node authorizer handles kubelet-specific access",
  "The API server is the enforcement point.",
  "Control-plane components",
  "Admission is the last policy checkpoint before an allowed write changes cluster state.",
  "RBAC might allow a CI service account to create Pods in <code class=\"language-plaintext highlighter-rouge\">inference-models</code>",
  "Mutating admission runs before validating admission",
  "Admission is not a replacement for RBAC.",
  "Kyverno is one common way to manage those admission policies.",
  "It runs in the cluster as a dynamic admission controller",
  "the API server sends matching AdmissionReview requests to Kyverno",
  "For validation, it can reject a vLLM Deployment that uses <code class=\"language-plaintext highlighter-rouge\">latest</code>",
  "For mutation, it can add standard labels",
  "this Kyverno <code class=\"language-plaintext highlighter-rouge\">MutatingPolicy</code> modifies matching vLLM Pods as they are created",
  "default-vllm-pod-platform-fields",
  "platform.example.com/workload",
  "prometheus.io/scrape",
  "runtimeClassName",
  "The policy object is YAML, but the value under <code class=\"language-plaintext highlighter-rouge\">applyConfiguration.expression</code> is a CEL expression.",
  "That is why the patch body uses <code class=\"language-plaintext highlighter-rouge\">Object{...}</code> syntax instead of normal YAML indentation.",
  "The secure form is an image digest such as <code class=\"language-plaintext highlighter-rouge\">vllm/vllm-openai@sha256:...</code>",
  "require-vllm-image-digests",
  "validationActions",
  "container.image.contains",
  "Kyverno also has <code class=\"language-plaintext highlighter-rouge\">ImageValidatingPolicy</code>",
  "policy reporting and background scans",
  "Kyverno still does not replace RBAC or model-layer authorization.",
  "Normal read requests such as <code class=\"language-plaintext highlighter-rouge\">get</code>, <code class=\"language-plaintext highlighter-rouge\">list</code>, and <code class=\"language-plaintext highlighter-rouge\">watch</code> do not go through admission.",
  "a validating admission policy cannot save you from a user who is already authorized to read Secret values.",
  "Dex is an OpenID Connect identity provider and broker.",
  "The important split is identity versus permission.",
  "It is not a Kubernetes authorizer.",
  "issuer URL, client ID, username claim, and groups claim",
  "kube-apiserver OIDC configuration",
  "/etc/kubernetes/manifests/kube-apiserver.yaml",
  "--oidc-issuer-url=https://dex.example.com",
  "--oidc-client-id=kubernetes",
  "--oidc-username-claim=email",
  "--oidc-groups-claim=groups",
  "https://api-server.example.com:6443",
  "certificate-authority-data",
  "client.authentication.k8s.io/v1",
  "kubectl",
  "oidc-login",
  "get-token",
  "--oidc-extra-scope=groups",
  "The <code class=\"language-plaintext highlighter-rouge\">server</code> field is the Kubernetes API server endpoint: <code class=\"language-plaintext highlighter-rouge\">https://api-server.example.com:6443</code>",
  "the client is talking to the API server",
  "as a generic target",
  "Dex also makes self-service Kubernetes access easier to operate.",
  "generates a kubeconfig from fixed cluster settings",
  "That self-service flow should generate configuration, not permission.",
  "Access still comes from identity-provider groups and RBAC bindings.",
  "Platform owns the Dex client, issuer URL, callback settings, cluster CA, and approved kubeconfig template.",
  "remove the user from the identity-provider group",
  "Dex should not get broad RBAC just because it participates in authentication",
  "Role, ClusterRole, RoleBinding, ClusterRoleBinding",
  "A developer who only needs to inspect model-serving resources should not be able to mutate Deployments or read Secrets.",
  "If the router discovers workers through Kubernetes labels, it needs read access to the objects it watches.",
  "For vLLM, <code class=\"language-plaintext highlighter-rouge\">pods/portforward</code> deserves special attention.",
  "Use <code class=\"language-plaintext highlighter-rouge\">kubectl auth can-i</code> before assuming an RBAC rule does what you intended:",
  "RBAC controls the Kubernetes API. It does not control the model API."
].each do |needle|
  assert(rbac_html.include?(needle), "RBAC basics post missing #{needle.inspect}")
end

rbac_auth_match = rbac_html.match(/<figure class="diagram" aria-labelledby="k8s-rbac-auth-flow-diagram">([\s\S]*?)<\/figure>/)
assert(rbac_auth_match, "missing Kubernetes RBAC auth flow diagram")
rbac_auth = rbac_auth_match[1]

assert(rbac_auth.include?("diagram__auth-flow"), "RBAC auth diagram must use the auth-flow layout")
assert(rbac_auth.include?("diagram__auth-lane"), "RBAC auth diagram must use the auth lane layout")
assert(rbac_auth.include?("diagram__auth-stack"), "RBAC auth diagram must group API server steps")
assert(rbac_auth.include?("diagram__auth-side"), "RBAC auth diagram must include related control-plane context")

assert(
  ordered?(
    rbac_auth,
    [
      "Kubernetes API auth flow",
      "Client request",
      "API server",
      "Authentication",
      "Authorization",
      "Admission",
      "Stored state",
      "RBAC policy objects",
      "Control-plane components"
    ]
  ),
  "RBAC auth diagram no longer shows client -> API server authn/authz/admission -> etcd-backed state"
)

dex_auth_match = rbac_html.match(/<figure class="diagram" aria-labelledby="dex-oidc-auth-flow-diagram">([\s\S]*?)<\/figure>/)
assert(dex_auth_match, "missing Dex OIDC auth flow diagram")
dex_auth = dex_auth_match[1]

assert(dex_auth.include?("diagram__auth-flow"), "Dex auth diagram must use the auth-flow layout")
assert(dex_auth.scan("diagram__auth-lane").length >= 2, "Dex auth diagram must show login and API-server lanes")
assert(dex_auth.include?("diagram__auth-stack"), "Dex auth diagram must group Dex and API server steps")

assert(
  ordered?(
    dex_auth,
    [
      "Kubernetes auth flow with Dex and OIDC",
      "User and kubectl login",
      "Dex OIDC issuer",
      "Connector login",
      "ID token",
      "kubectl request",
      "API server OIDC config",
      "Control plane decision",
      "Authenticate token",
      "Map claims",
      "RBAC authorizer",
      "Admission and etcd",
      "Allowed or denied"
    ]
  ),
  "Dex OIDC auth diagram no longer shows login -> Dex token -> API server validation -> RBAC decision"
)

[
  "Securing vLLM on Kubernetes",
  "The RBAC post covered Kubernetes management access",
  "Kubernetes RBAC controls who can manage the serving platform. It does not decide who can use a model, issue API keys, enforce tenant limits, protect prompt data, or stop an agent from turning model output into an unsafe action.",
  "Model-serving boundary",
  "client -&gt; gateway or LLM gateway -&gt; model policy -&gt; router -&gt; vLLM worker",
  "Who can call <code class=\"language-plaintext highlighter-rouge\">general-chat</code> or <code class=\"language-plaintext highlighter-rouge\">finance-summary</code>",
  "Which agent tools can run and under whose authority",
  "API keys and user-facing access",
  "you need key issuance, rotation, revocation, owner metadata",
  "model allowlists",
  "vLLM has a built-in <code class=\"language-plaintext highlighter-rouge\">--api-key</code> server option.",
  "It is not a user-facing key-management system",
  "Common out-of-the-box options:",
  "AWS API Gateway usage plans/API keys, Azure API Management subscriptions, Google Cloud API Gateway API keys",
  "Kong Gateway key-auth, Apache APISIX key-auth",
  "LiteLLM Proxy virtual keys, budgets, model access, spend tracking, and <code class=\"language-plaintext highlighter-rouge\">/key/generate</code>",
  "Store only hashed keys, use short prefixes for lookup, support rotation/revocation",
  "API keys are bearer secrets, not strong user identity.",
  "The router or LLM gateway should reject requests for models outside the key",
  "should not be able to call <code class=\"language-plaintext highlighter-rouge\">finance-summary</code> by changing the <code class=\"language-plaintext highlighter-rouge\">model</code> field",
  "Prompt injection and agent boundaries",
  "Once model output can drive retrieval, code execution, browsers, ticket systems, databases, or cloud APIs, you are securing an agent system.",
  "A vLLM worker receives tokens and returns tokens.",
  "Indirect prompt injection is worse for agents",
  "Do not put secrets, raw credentials, or broad internal data into model context",
  "Put tool calls through a policy service, not directly from model text to execution.",
  "agent service -&gt; policy check -&gt; tool executor -&gt; external system",
  "The vLLM worker should not have cloud admin credentials, database write credentials, shell access to the host, or broad outbound internet access.",
  "This is how you keep a model from “running crazy”: do not let text directly become authority.",
  "Istio Gateway API at the edge",
  "GatewayClass -&gt; Gateway -&gt; HTTPRoute -&gt; Service -&gt; router Pod",
  "Istio supports Gateway API and has said it intends to make it the default traffic-management API.",
  "Gateway API resources are CRDs and are not installed by default on most clusters.",
  "<span class=\"na\">gatewayClassName</span><span class=\"pi\">:</span> <span class=\"s\">istio</span>",
  "<span class=\"na\">certificateRefs</span><span class=\"pi\">:</span>",
  "<span class=\"na\">kind</span><span class=\"pi\">:</span> <span class=\"s\">HTTPRoute</span>",
  "For a raw TCP port, use <code class=\"language-plaintext highlighter-rouge\">TCPRoute</code> instead of an Istio <code class=\"language-plaintext highlighter-rouge\">VirtualService</code>.",
  "<span class=\"s\">inference-tcp-gateway</span>",
  "TCPRoute is a Gateway API experimental-channel resource.",
  "<span class=\"na\">kind</span><span class=\"pi\">:</span> <span class=\"s\">TCPRoute</span>",
  "<span class=\"na\">gateway-access</span><span class=\"pi\">:</span> <span class=\"s\">inference</span>",
  "Packets do not travel to an <code class=\"language-plaintext highlighter-rouge\">HTTPRoute</code>, <code class=\"language-plaintext highlighter-rouge\">TCPRoute</code>, or old <code class=\"language-plaintext highlighter-rouge\">VirtualService</code> object.",
  "The certificate Secret belongs in the namespace where the <code class=\"language-plaintext highlighter-rouge\">Gateway</code> reads it.",
  "NetworkPolicy: default-deny the model pods",
  "Runtime isolation: containers, gVisor, Kata, and VMs",
  "Kubernetes <code class=\"language-plaintext highlighter-rouge\">RuntimeClass</code> is the standard API for selecting a different container runtime configuration per Pod.",
  "spec.runtimeClassName",
  "<span class=\"na\">runtimeClassName</span><span class=\"pi\">:</span> <span class=\"s\">kata</span>",
  "Standard container",
  "gVisor",
  "Kata Containers",
  "Dedicated VM/node pool",
  "Separate cluster/account/project",
  "I would not start by forcing the GPU worker itself into a sandbox runtime.",
  "Runtime isolation does not solve prompt injection.",
  "Securing vLLM on Kubernetes is not one RBAC file. It is a layered access model."
].each do |needle|
  assert(security_html.include?(needle), "vLLM security post missing #{needle.inspect}")
end

gateway_api_match = security_html.match(/<figure class="diagram" aria-labelledby="gateway-api-vllm-flow-diagram">([\s\S]*?)<\/figure>/)
assert(gateway_api_match, "missing Gateway API vLLM flow diagram")
gateway_api = gateway_api_match[1]

assert(gateway_api.include?("diagram__auth-flow"), "Gateway API diagram must use the auth-flow layout")
assert(gateway_api.include?("diagram__auth-lane"), "Gateway API diagram must use auth lanes")
assert(gateway_api.include?("diagram__auth-stack"), "Gateway API diagram must stack route and certificate nodes")

assert(
  ordered?(
    gateway_api,
    [
      "Gateway API traffic and certificate flow",
      "Client",
      "Istio ingress gateway",
      "LoadBalancer Service",
      "Envoy gateway proxy",
      "Route to vLLM",
      "Gateway listener",
      "HTTPRoute / TCPRoute",
      "old Istio API: VirtualService",
      "vLLM router Service and Pod",
      "cert-manager",
      "Certificate resource",
      "Kubernetes Secret",
      "serves the Secret named in certificateRefs"
    ]
  ),
  "Gateway API diagram no longer shows client -> gateway proxy -> route -> vLLM plus cert-manager -> Secret -> Gateway listener"
)

[
  "Two planes",
  "Trust boundaries",
  "RBAC is not model authorization",
  "Model access belongs above Kubernetes RBAC",
  "Admission controls and deployment policy",
  "Reference policy shape",
  "Failure modes to avoid",
  "Production checklist",
  "UDPRoute",
  "UDP",
  "router-udp",
  "9001",
  "L4",
  "l4",
  "Example RBAC: developers can view, operators can deploy",
  "Example RBAC: router service discovery",
  "Namespace boundaries"
].each do |needle|
  assert(!security_html.include?(needle), "vLLM security post should not include RBAC basics section #{needle.inspect}")
end

series_html = security_html
assert(
  ordered?(
    series_html,
    [
      "Running vLLM in Kubernetes",
      "Kubernetes RBAC Basics for vLLM Operators",
      "Securing vLLM on Kubernetes"
    ]
  ),
  "series navigation must place RBAC basics before the vLLM security post"
)

css = read("_site/assets/css/diagrams.css")
[
  ".page__content .diagram",
  "clear: both;",
  "width: min(980px, calc(100vw - 2rem));",
  "margin: 2rem 0 2.25rem 50%;",
  "transform: translateX(-50%);",
  "overflow: hidden;",
  ".page__content .diagram--flow",
  "width: fit-content;",
  "min-width: min(100%, 24rem);",
  ".page__content .diagram__pipeline",
  "width: min(100%, 34rem);",
  ".page__content .diagram__stages",
  ".page__content .diagram__service",
  "width: min(100%, 34rem);",
  ".page__content .diagram__route",
  "grid-template-columns: minmax(9.5rem, 1fr) 2.25rem minmax(9.5rem, 1fr) 2.25rem minmax(9.5rem, 1fr);",
  ".page__content .diagram__grid--two",
  ".page__content .diagram__grid--stack",
  ".page__content .diagram__grid > .diagram__node",
  ".page__content .diagram__traffic-grid",
  "grid-template-columns: minmax(0, 1fr) 2.25rem minmax(0, 0.82fr) 2.25rem minmax(0, 1fr);",
  ".page__content .diagram__dns-grid",
  "grid-template-columns: minmax(0, 1fr) 2.25rem minmax(0, 1fr);",
  ".page__content .diagram__transit",
  ".page__content .diagram__dns-column",
  ".page__content .diagram__auth-flow",
  ".page__content .diagram__auth-lane",
  "grid-template-columns: minmax(0, 1fr) 2.25rem minmax(0, 1.35fr) 2.25rem minmax(0, 1fr);",
  ".page__content .diagram__auth-stack",
  ".page__content .diagram__auth-side",
  "@media (max-width: 1040px)",
  ".page__content .diagram__traffic-grid > .diagram__connector::before",
  ".page__content .diagram__auth-lane > .diagram__connector::before",
  ".page__content .diagram__cluster-grid--control",
  "grid-template-columns: repeat(3, minmax(0, 1fr));",
  ".page__content .diagram__cluster-grid--workers",
  "grid-template-columns: repeat(2, minmax(0, 1fr));",
  ".page__content .diagram__worker-pool",
  ".page__content .diagram__pool-items",
  ".page__content .diagram__pool-items--stack",
  ".page__content .diagram__node--compact",
  ".page__content .diagram__probe-model",
  ".page__content .diagram__probe-case",
  ".page__content .diagram__probe-row",
  ".page__content .diagram__probe-track",
  "grid-template-columns: repeat(12, minmax(0, 1fr));",
  "column-gap: 0.4rem;",
  ".page__content .diagram__probe-segment",
  "grid-column: var(--start) / span var(--span);",
  "linear-gradient(var(--diagram-accent-soft), var(--diagram-accent-soft)),",
  ".page__content .diagram__connector--route-out",
  "grid-column: 5;",
  "@media (max-width: 760px)",
  "width: 100vw;",
  "margin-left: calc(50% - 50vw);",
  "transform: none;",
  "grid-template-columns: repeat(5, minmax(0, 1fr));",
  "grid-template-columns: 1fr;",
  ".page__content .diagram__worker-grid"
].each do |needle|
  assert(css.include?(needle), "responsive diagram CSS missing #{needle.inspect}")
end
assert(!css.include?(".page__content .diagram__probe-track::before"), "probe timing diagram must not draw lines through labels")

code_css = read("_site/assets/css/code-blocks.css")
[
  ".page__content :not(pre) > code",
  ".page__content :not(pre) > code.highlighter-rouge",
  "display: inline;",
  "overflow-wrap: anywhere;",
  "word-break: break-word;",
  "white-space: normal;",
  "box-decoration-break: clone;",
  ".page__content :not(pre) > code::before",
  ".page__content :not(pre) > code::after",
  "content: none;"
].each do |needle|
  assert(code_css.include?(needle), "inline code wrapping CSS missing #{needle.inspect}")
end

head_html = read("_site/2026/06/07/kubernetes-cluster-basics-for-vllm/index.html")
assert(
  head_html.match?(%r{/assets/css/code-blocks\.css\?v=\d+}),
  "code-blocks.css must be cache-busted so inline code fixes reach browsers"
)

site_css = read("_site/assets/css/site-enhancements.css")
[
  "html[data-theme=\"light\"] .page__title,",
  "html[data-theme=\"light\"] .page__title a,",
  "opacity: 1;",
  "--site-table-header-bg: #e7edf5;",
  "--site-table-row-bg: #ffffff;",
  "--site-table-row-alt-bg: #f6f9fc;",
  ".page__content table th",
  "background: var(--site-table-header-bg);",
  ".page__content table td",
  "background: var(--site-table-row-bg);"
].each do |needle|
  assert(site_css.include?(needle), "light-mode table CSS missing #{needle.inspect}")
end

puts "diagram checks passed"
