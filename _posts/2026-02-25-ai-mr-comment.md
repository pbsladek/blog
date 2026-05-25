---
title: ai-mr-comment
excerpt: A small CLI for turning diffs into useful PR and MR comments, titles, commit messages, and automation artifacts.
tags:
  - tools
  - ai
  - code-review
---

[ai-mr-comment](https://pbsladek.github.io/ai-mr-comment/) is a command-line tool that reads a git diff and asks an AI provider to turn it into useful review material. It can generate a pull request or merge request comment, a title and description, a conventional commit message, or a changelog-style summary.

The input can come from the current branch, staged changes, a commit range, a diff file, standard input, a GitHub pull request URL, or a GitLab merge request URL. That makes it useful both locally and inside CI.

<!--more-->

A typical local use is to summarize staged work before committing:

```sh
ai-mr-comment --staged --template technical
```

For hosted review automation, point it at a PR or MR and let it fetch the diff itself:

```sh
ai-mr-comment --pr "$PR_URL" --post
```

It also has a commit-message path:

```sh
ai-mr-comment --commit-msg --staged
```

The helpful part is not that it replaces review. It removes the blank page at the start of review. A good generated summary gives maintainers a first pass over what changed, why it matters, and where the risky parts might be. The JSON and JSONL modes make it easy to keep artifacts, gate CI with `--exit-code`, or feed a later step in a pipeline.

It works well with agents because it gives them a narrow, scriptable interface: provide a diff, receive structured review text or a stable exit code. Agents can call it after making changes, inspect the generated summary for missed intent, post it back to the remote review, or use the commit-message mode to keep routine git hygiene out of the main task loop.
