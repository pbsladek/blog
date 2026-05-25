---
title: Projects
layout: single
permalink: /projects/
author_profile: true
---

<div class="project-grid">
  <article class="project-card">
    <div class="project-card__header">
      <h2>waitfor</h2>
      <span class="project-card__tag">Automation</span>
    </div>
    <p>Semantic condition polling for shell scripts, CI pipelines, Docker entrypoints, Kubernetes init containers, and agent workflows.</p>
    <div class="project-card__links">
      <a href="https://pbsladek.github.io/waitfor/">Docs</a>
      <a href="https://github.com/pbsladek/wait-for">GitHub</a>
    </div>

    <div class="language-sh highlighter-rouge"><div class="highlight"><pre class="highlight"><code>go install github.com/pbsladek/wait-for/cmd/waitfor@latest</code></pre></div></div>
  </article>

  <article class="project-card">
    <div class="project-card__header">
      <h2>snetc</h2>
      <span class="project-card__tag">Networking</span>
    </div>
    <p>Native subnet calculations for CIDR inspection, VLSM planning, route aggregation, overlap checks, and RFC range classification.</p>
    <div class="project-card__links">
      <a href="https://pbsladek.github.io/snetc/">Docs</a>
      <a href="https://github.com/pbsladek/snetc">GitHub</a>
    </div>

    <div class="language-sh highlighter-rouge"><div class="highlight"><pre class="highlight"><code>docker run --rm pwbsladek/snetc:latest 192.168.0.0/22</code></pre></div></div>
  </article>

  <article class="project-card">
    <div class="project-card__header">
      <h2>ai-mr-comment</h2>
      <span class="project-card__tag">Code review</span>
    </div>
    <p>AI-generated PR and MR comments, titles, descriptions, commit messages, CI review gates, and changelog summaries from git diffs.</p>
    <div class="project-card__links">
      <a href="https://pbsladek.github.io/ai-mr-comment/">Docs</a>
      <a href="https://github.com/pbsladek/ai-mr-comment">GitHub</a>
    </div>

    <div class="language-sh highlighter-rouge"><div class="highlight"><pre class="highlight"><code>brew install pbsladek/tap/ai-mr-comment</code></pre></div></div>
  </article>
</div>
