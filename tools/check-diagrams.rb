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
kubernetes_path = "_site/2026/06/14/vllm-kubernetes/index.html"
vllm_html = read(vllm_path)
kubernetes_html = read(kubernetes_path)

figure_count = vllm_html.scan(/<figure class="diagram(?: [^"]*)?" aria-labelledby="/).length
assert(figure_count == 2, "expected 2 diagrams in the vLLM 101 post, found #{figure_count}")

kubernetes_figure_count = kubernetes_html.scan(/<figure class="diagram(?: [^"]*)?" aria-labelledby="/).length
assert(
  kubernetes_figure_count == 1,
  "expected 1 diagram in the vLLM Kubernetes post, found #{kubernetes_figure_count}"
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

css = read("_site/assets/css/diagrams.css")
[
  ".page__content .diagram",
  "width: min(980px, calc(100vw - 2rem));",
  "margin: 2rem 0 2.25rem 50%;",
  "transform: translateX(-50%);",
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
  ".page__content .diagram__connector--route-out",
  "grid-column: 5;",
  "@media (max-width: 760px)",
  "width: 100vw;",
  "margin-left: calc(50% - 50vw);",
  "transform: none;",
  "grid-template-columns: 1fr;",
  ".page__content .diagram__worker-grid"
].each do |needle|
  assert(css.include?(needle), "responsive diagram CSS missing #{needle.inspect}")
end

puts "diagram checks passed"
