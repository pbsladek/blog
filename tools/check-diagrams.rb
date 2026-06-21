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
classic_savings_path = "_site/2026/05/31/classic-savings-rates/index.html"
inflation_path = "_site/2026/06/01/inflation-emergency-fund-target/index.html"
renting_path = "_site/2026/06/02/renting-is-not-wasting-money/index.html"
relationships_path = "_site/2026/06/03/relationships-financial-plan/index.html"
vllm_html = read(vllm_path)
kubernetes_html = read(kubernetes_path)
classic_savings_html = read(classic_savings_path)
inflation_html = read(inflation_path)
renting_html = read(renting_path)
relationships_html = read(relationships_path)

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

[
  [classic_savings_html, "Classic Savings Rates Are Dubious"],
  [inflation_html, "Inflation Keeps Moving the Emergency Fund Target"],
  [renting_html, "Renting Is Not Wasting Money"],
  [relationships_html, "Relationships Are Part of the Financial Plan"]
].each do |html, current_title|
  assert(html.include?(%(<h2 id="post-series-title" class="post-series__title">Classic Savings Rates</h2>)), "#{current_title} missing series nav")
  assert(html.include?(current_title), "#{current_title} missing from rendered page")
end

cpi_match = inflation_html.match(/<figure class="diagram diagram--chart" aria-labelledby="cpi-stack-chart">([\s\S]*?)<\/figure>/)
assert(cpi_match, "missing cumulative inflation chart")
cpi_chart = cpi_match[1]

assert(
  cpi_chart.include?(%(<text class="line-chart__tick line-chart__tick--compact" x="80" y="376" text-anchor="start">2021 +7.6%</text>)),
  "cpi chart first x-axis period label must be start-anchored and compact"
)

assert(
  cpi_chart.include?(%(<text class="line-chart__label" x="92" y="306">0.0%</text>)),
  "cpi chart zero label must sit above the origin marker and line"
)

assert(
  cpi_chart.include?(%(<text class="line-chart__tick line-chart__tick--compact" x="830" y="376" text-anchor="end">May 2026 +2.3%</text>)),
  "cpi chart last x-axis period label must be end-anchored and compact"
)

assert(!cpi_chart.include?("May 2026: +2.3% YTD"), "cpi chart must not use the overflowing final x-axis label")

beef_match = inflation_html.match(/<figure class="diagram diagram--chart" aria-labelledby="beef-inflation-chart">([\s\S]*?)<\/figure>/)
assert(beef_match, "missing beef inflation chart")
beef_chart = beef_match[1]

[
  "Beef and veal CPI since 1950",
  "Indexed price level, where 1950 equals 100",
  %(<polyline class="line-chart__series line-chart__series--mega" points="90,313 238,305 386,256 534,211 682,124 830,114" />),
  %(<polyline class="line-chart__series line-chart__series--inflation" points="90,313 238,302 386,236 534,173 682,98 830,89" />),
  %(<text class="line-chart__label line-chart__label--small" x="825" y="74" text-anchor="end">All items: 13.9x</text>),
  %(<text class="line-chart__label line-chart__label--small" x="825" y="139" text-anchor="end">Beef: 12.5x</text>),
  "Y-axis: price level index, 1950 = 100",
  "Ground beef:",
  "$6.745"
].each do |needle|
  assert(beef_chart.include?(needle), "beef inflation chart missing #{needle.inspect}")
end

[
  "2025 beef:",
  "2025 all items:",
  "May 2026 beef: 12.5x",
  "May 2026 all items: 13.9x"
].each do |needle|
  assert(!beef_chart.include?(needle), "beef inflation chart must not use crowded label #{needle.inspect}")
end

assert(!inflation_html.include?("beef-subsidy-chart"), "beef subsidy chart should be removed")
assert(!inflation_html.include?("beef without subsidies"), "beef subsidy discussion should be removed")
assert(!inflation_html.include?("Subsidies are tempting"), "beef subsidy discussion should be removed")
assert(
  inflation_html.include?("The two beef numbers are not conflicting.") &&
    inflation_html.include?("The second number is the recent jump on top of the already-inflated price level."),
  "beef section must explain the 12.5x long-window number versus the 44 percent recent-window number"
)

ground_beef_match = inflation_html.match(/<figure class="diagram diagram--chart" aria-labelledby="ground-beef-price-chart">([\s\S]*?)<\/figure>/)
assert(ground_beef_match, "missing ground beef dollar price chart")
ground_beef_chart = ground_beef_match[1]

[
  "Regular ground beef, dollars per pound",
  "BLS/FRED average retail price series",
  %(<polyline class="line-chart__series line-chart__series--small" points="90,237 383,226 748,131 830,32" />),
  "1984 avg.",
  "$1.29",
  "2000 avg.",
  "$1.57",
  "2020 avg.",
  "$4.12",
  "May 2026",
  "$6.745",
  "Y-axis: average retail dollars per pound"
].each do |needle|
  assert(ground_beef_chart.include?(needle), "ground beef dollar-price chart missing #{needle.inspect}")
end

[
  "regular ground beef, not the full beef-and-veal CPI basket",
  "roughly a 64 percent increase"
].each do |needle|
  assert(inflation_html.include?(needle), "ground beef dollar-price explanation missing #{needle.inspect}")
end

[
  "<th>Regular ground beef</th>",
  "Average retail price</th>"
].each do |needle|
  assert(!inflation_html.include?(needle), "ground beef dollar-price table should be replaced by a chart")
end

season_match = inflation_html.match(/<figure class="diagram diagram--chart" aria-labelledby="ski-season-chart">([\s\S]*?)<\/figure>/)
assert(season_match, "missing ski season pass chart")
season_chart = season_match[1]

[
  "Season-pass prices in nominal and December 2025 dollars",
  "Ski season pass line graph with nominal and inflation-adjusted prices",
  %(<polyline class="line-chart__series line-chart__series--small" points="150,285 470,181 790,92" />),
  %(<polyline class="line-chart__series line-chart__series--season" points="150,237 470,125 790,92" />),
  "line-chart__point line-chart__point--season",
  "chart-legend__swatch chart-legend__swatch--small",
  "$282",
  "$877",
  "$1,051",
  "inflation adds $257",
  "inflation adds $298",
  "20 percent above the 2008 launch price after CPI",
  "1958 local pass",
  "2008 Epic launch",
  "2025 Epic adult"
].each do |needle|
  assert(season_chart.include?(needle), "ski season pass chart missing #{needle.inspect}")
end

[
  "Season-pass prices in nominal and 2026 dollars",
  "$1,089",
  "May 2026 dollars"
].each do |needle|
  assert(!season_chart.include?(needle), "ski season pass chart must not use stale 2026 label #{needle.inspect}")
end

assert(
  inflation_html.include?("December 2025 CPIAUCSL of <code class=\"language-plaintext highlighter-rouge\">326.031</code>"),
  "ski season pass method note must include the December 2025 CPIAUCSL endpoint"
)

assert(
  inflation_html.match?(%r{<th(?: [^>]*)?>Real historical price</th>}) &&
    inflation_html.match?(%r{<th(?: [^>]*)?>CPI-adjusted to December 2025</th>}),
  "classic savings inflation price table must render readable table headers"
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
  ".page__content .line-chart__tick--compact",
  "font-size: 0.66rem;",
  ".page__content .line-chart__label--small",
  "font-size: 0.68rem;",
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

site_css = read("_site/assets/css/site-enhancements.css")
[
  'html[data-theme="light"] .page__title a',
  'html[data-theme="light"] .page__content table th',
  "color: var(--site-text);",
  "background: var(--site-surface-soft);"
].each do |needle|
  assert(site_css.include?(needle), "light-mode table CSS missing #{needle.inspect}")
end

puts "diagram checks passed"
