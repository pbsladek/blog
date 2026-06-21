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
  "Role, ClusterRole, RoleBinding, ClusterRoleBinding",
  "A developer who only needs to inspect model-serving resources should not be able to mutate Deployments or read Secrets.",
  "If the router discovers workers through Kubernetes labels, it needs read access to the objects it watches.",
  "For vLLM, <code class=\"language-plaintext highlighter-rouge\">pods/portforward</code> deserves special attention.",
  "Use <code class=\"language-plaintext highlighter-rouge\">kubectl auth can-i</code> before assuming an RBAC rule does what you intended:",
  "RBAC controls the Kubernetes API. It does not control the model API."
].each do |needle|
  assert(rbac_html.include?(needle), "RBAC basics post missing #{needle.inspect}")
end

[
  "Securing vLLM on Kubernetes",
  "The RBAC post covered Kubernetes management access",
  "Kubernetes RBAC controls who can manage the serving platform. It does not decide who can use a model.",
  "Model access belongs above Kubernetes RBAC",
  "client identity -&gt; gateway auth -&gt; model authorization -&gt; router -&gt; worker",
  "NetworkPolicy: default-deny the model pods",
  "Admin endpoints and metrics",
  "Securing vLLM on Kubernetes is not one RBAC file. It is a layered access model."
].each do |needle|
  assert(security_html.include?(needle), "vLLM security post missing #{needle.inspect}")
end

[
  "## Example RBAC: developers can view, operators can deploy",
  "## Example RBAC: router service discovery",
  "## Namespace boundaries"
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
  "@media (max-width: 1040px)",
  ".page__content .diagram__traffic-grid > .diagram__connector::before",
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
