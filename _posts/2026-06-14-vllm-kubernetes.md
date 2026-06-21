---
title: Running vLLM in Kubernetes
excerpt: A practical look at vLLM pods, GPU scheduling, replicas, model-aware routing, startup time, probes, performance tuning, autoscaling, and production checks.
tags:
  - ai
  - inference
  - kubernetes
  - vllm
series: vllm-inference
---

The cluster primer covered control planes, worker nodes, kubelet, the API server, and why GPU workers need device-plugin support. This post moves the vLLM service into that Kubernetes shape: GPU scheduling, replicas, routing, probes, and production failure modes.

<!--more-->

{% include series-nav.html %}

Assume the cluster has CPU workers for ingress, routers, metrics, and ordinary services, plus GPU workers for model servers. The vLLM pod belongs on the GPU side, while the public edge and model-aware router usually belong on the CPU side.

Kubernetes gives you scheduling, rollouts, service discovery, secrets, health checks, and resource boundaries. vLLM still needs the right GPU, enough memory, model access, and sane limits.

Kubernetes does not understand:

- token queues
- KV cache pressure
- GPU memory fragmentation
- time to first token
- per-model saturation
- whether a long-context request is crowding out shorter ones
- whether one replica is hot while another is idle

Kubernetes can keep pods alive and route to ready endpoints. It cannot tell you whether the inference scheduler is healthy.

A minimal Kubernetes manifest looks like this:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-gpt-oss
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vllm-gpt-oss
  template:
    metadata:
      labels:
        app: vllm-gpt-oss
    spec:
      containers:
        - name: vllm
          # Pinned on 2026-06-20: vLLM v0.23.0 multi-arch manifest.
          # Secure pattern: pin both version and digest; do not deploy `latest`.
          image: vllm/vllm-openai:v0.23.0@sha256:6d8429e38e3747723ca07ee1b17972e09bb9c51c4032b266f24fb1cc3b22ed8f
          args:
            - --model
            - openai/gpt-oss-20b
            - --host
            - 0.0.0.0
            - --port
            - "8000"
            - --dtype
            - auto
          ports:
            - containerPort: 8000
          # Optional: only needed if your model registry requires auth.
          env:
            - name: HUGGING_FACE_HUB_TOKEN
              valueFrom:
                secretKeyRef:
                  name: hf-token
                  key: token
          resources:
            limits:
              nvidia.com/gpu: "1"
```

Then expose it inside the cluster:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: vllm-gpt-oss
spec:
  selector:
    app: vllm-gpt-oss
  ports:
    - name: http
      port: 80
      targetPort: 8000
```

That is enough to see the deployment shape, but it is not a full production setup. For production, pin image tags, use GPU node selectors or runtime classes, set requests as well as limits, plan for model download and warmup time, and decide how rollouts should behave when a pod takes minutes to become ready.

Be careful with CPU limits. CPU requests are useful because they tell the scheduler how much CPU capacity the pod expects. Memory limits are useful because memory is not compressible: if the process uses too much, Kubernetes needs a hard boundary before the node is in trouble. CPU is different. A CPU limit does not kill the pod when it is busy; Kubernetes throttles the container. That can be quiet. The pod stays `Running`, readiness may still pass, and the symptom may look like worse latency unless you alert on CPU throttling metrics. For a vLLM pod, throttling can slow tokenization, request handling, streaming, metrics, and coordination around the GPU. If CPU-side work cannot feed or coordinate GPU work fast enough, the GPU can look underused even though the root cause is the CPU quota. In many production clusters, it is common to set CPU requests, set memory requests and limits, and avoid tight CPU limits unless you have measured the workload and need a hard fairness boundary.

The `nvidia.com/gpu: "1"` line depends on the NVIDIA device plugin, or an equivalent GPU device plugin, being installed in the cluster. The device plugin is what advertises GPU capacity to Kubernetes and makes `nvidia.com/gpu` available as a schedulable resource. Without it, the scheduler does not know which nodes have GPUs in the Kubernetes resource model.

`runtimeClassName` is a different thing. A runtime class selects the container runtime handler for the pod, for example an NVIDIA-aware runtime handler on clusters that are configured that way. It does not advertise GPU capacity by itself. Think of the device plugin as "Kubernetes can schedule GPU resources" and the runtime class as "this pod should run with the runtime setup that can expose those GPUs correctly." Some clusters make the NVIDIA runtime the default for GPU nodes, so you only request `nvidia.com/gpu`. Others require both a GPU resource request and something like `runtimeClassName: nvidia` at the pod spec level.

## Using replicas without dropping requests

Multiple replicas of the same model help when each replica has enough GPU capacity to serve real traffic. In practice that means one vLLM pod per GPU, all serving the same model name, behind one Service or router.

One request is not split across those replicas. Kubernetes, an ingress, or a model router picks one ready pod for the HTTP request. That pod runs the full prefill, owns the KV cache for that request, generates the decode tokens, and streams the response back. If the pod dies halfway through, the request fails and a retry starts over on another pod.

So replicas give you request-level parallelism: three pods can handle three different requests at the same time. They do not combine into one bigger brain for a single request. If you need one model instance to span multiple GPUs, that is tensor parallelism or pipeline parallelism inside the vLLM deployment, not Kubernetes replicas.

| Pattern | What it scales | How it works | What it does not do |
| --- | --- | --- | --- |
| **Kubernetes replicas** | More independent requests | Runs multiple vLLM pods serving the same model | Does not split one request across pods |
| **Tensor parallelism** | One model instance across multiple GPUs | Splits tensor computation for a large model across GPUs | Does not create more independent serving replicas by itself |
| **Pipeline parallelism** | One model instance across stages | Splits model layers/stages across GPUs | Does not remove coordination cost |

Use replicas when one GPU can hold the model and you need more request capacity. Use tensor or pipeline parallelism when one model instance needs more than one GPU. Sometimes you use both: each replica is itself a multi-GPU vLLM deployment.

The simple Kubernetes version is:

```yaml
spec:
  replicas: 3
  template:
    spec:
      terminationGracePeriodSeconds: 120
      containers:
        - name: vllm
          startupProbe:
            httpGet:
              path: /health
              port: 8000
            periodSeconds: 10
            failureThreshold: 60
          readinessProbe:
            httpGet:
              path: /health
              port: 8000
            periodSeconds: 10
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /health
              port: 8000
            periodSeconds: 30
```

Readiness matters. A pod should not receive traffic just because the container process exists. It should receive traffic after the model is loaded and the server can answer. Otherwise Kubernetes can send requests to a pod that is still downloading weights or warming kernels. The startup probe gives slow model loads time to finish before the liveness probe starts judging the container.

### Startup time and probes

vLLM startup is often the slowest part of the rollout. The container has to start Python, resolve model files, download or mount weights, initialize the engine, allocate KV cache, compile or capture optimized execution paths depending on configuration, and only then become useful. On a large model, that can take minutes.

Startup time is not one thing. It is a chain:

1. Kubernetes schedules the Pod onto a GPU node.
2. The node pulls the container image if it is not already present.
3. vLLM resolves model config, tokenizer files, generation config, and model implementation.
4. Weights are downloaded, read from a cache, mounted from a volume, or streamed from a storage system.
5. The engine loads weights into CPU and GPU memory, starts workers, initializes distributed communication when parallelism is enabled, and reserves KV cache.
6. The first real work may trigger CUDA kernels, graph capture, compilation, or other warmup behavior depending on the model and vLLM configuration.

The slowest piece depends on the deployment:

| Startup contributor | Why it matters | What helps |
| --- | --- | --- |
| Image pull | vLLM images and CUDA dependencies can be large, and cold nodes may not have the image. | Pin the image, pre-pull on GPU nodes, keep node image caches warm, and avoid changing image tags for model-only changes. |
| Model download | Pulling weights from Hugging Face or object storage during startup makes readiness depend on network and registry behavior. | Sync weights to a PVC or node-local cache before vLLM starts; use `--download-dir` so the cache location is explicit. |
| Storage read path | Loading hundreds of GB from slow network storage can dominate startup. Random reads from a network filesystem can be especially painful. | Prefer local NVMe or a warmed PVC when possible; for safetensors on network storage, evaluate `--safetensors-load-strategy eager` or `prefetch` and size CPU RAM accordingly. |
| Checkpoint format | Safetensors, PyTorch `.bin`, pre-sharded state, GGUF, quantized formats, and specialized loaders have different load behavior. | Prefer formats and loaders that match your storage and parallelism setup. For tensor-parallel models, pre-sharded checkpoints or `--load-format sharded_state` can reduce unnecessary loading work. |
| Model size and dtype | More parameters mean more bytes to read and copy. BF16/FP16 weights are larger than many quantized formats. | Use the smallest model that meets quality goals; choose `--dtype` and `--quantization` deliberately, then measure startup and runtime quality/latency. |
| Context length and KV cache | vLLM reserves KV cache based on memory policy and usable context. Very long contexts can reduce headroom and change initialization behavior. | Set `--max-model-len` to the context you actually serve, not the largest advertised context, and tune `--gpu-memory-utilization` or `--kv-cache-memory-bytes`. |
| Parallelism | Tensor, pipeline, data, and expert parallelism add worker startup, communication setup, and sometimes more complicated weight loading. | Use parallelism when the model needs it or throughput justifies it. For a model that fits on one GPU, independent replicas are usually simpler to start and operate. |
| Model architecture | Dense decoder-only models, MoE models, multimodal models, and models that fall back to a Transformers implementation do not start the same way. | Test the exact model family. MoE and multimodal setups can add expert placement, encoder initialization, preprocessing, or different kernels. |
| CPU and host memory | Tokenizer/model config parsing, safetensors prefetch, weight staging, and worker startup need CPU and RAM before the GPU is busy. | Set realistic CPU and memory requests, avoid tight CPU limits, and watch host memory when using eager/prefetch loading. |

Different models change the startup budget in predictable ways. A small dense 7B-style model with local safetensors may come up quickly. A larger dense model may be dominated by raw weight read and GPU copy time. A long-context model can spend more of the startup budget reserving usable KV cache and may need a lower `--max-model-len` in production than the theoretical maximum. A quantized model may read fewer bytes, but the quantization method can add loader-specific work and can change runtime kernel behavior. A MoE model may have many more total parameters than active parameters per token, so storage layout, expert placement, and whether each rank has to read non-local expert weights can matter a lot.

The useful configuration stance is to make startup deterministic before making it clever:

- Put model artifacts somewhere predictable: a PVC, node-local cache, or object-store sync into local disk.
- Make the cache path explicit with `--download-dir` or environment variables used by your model registry tooling.
- Set `--max-model-len` to the maximum context you actually admit at the API boundary.
- Use `--gpu-memory-utilization` or `--kv-cache-memory-bytes` to make KV allocation intentional instead of accidental.
- Use `--load-format` only when you know why that format matches your checkpoint and storage path.
- Use `--max-parallel-loading-workers` carefully for large tensor-parallel models; more parallel loading can help, but it can also increase CPU RAM pressure.
- Treat `--enforce-eager` as a tradeoff knob, not a default fix. Avoiding CUDA graph behavior may change cold-start work, but it can also give up steady-state performance.
- Measure startup as its own SLO: image pull time, model artifact sync time, engine init time, readiness time, and first successful inference time.

Treat startup as an operating condition, not an exception:

- **Keep model weights close to the pod.** Downloading from the public internet during every rollout makes readiness depend on registry bandwidth and rate limits. Prefer a PVC, node-local cache, object-store sync into local storage, or a prewarmed image for smaller artifacts.
- **Use `startupProbe` generously.** It should cover the worst expected model load plus some margin. Without it, an eager liveness probe can kill the container while it is doing exactly what it should be doing.
- **Make readiness stricter than "process is listening."** Readiness should only pass when the model is loaded and the server can handle real inference. If you use a sidecar or init container to stage weights, readiness should reflect the final serving state, not just the staging step.
- **Keep liveness boring.** Liveness is for stuck or broken processes. If it is too aggressive, it can turn temporary load, slow storage, or a long initialization into a restart loop.
- **Roll out slowly.** Use a Deployment strategy, PodDisruptionBudget, and termination grace period that assume cold pods are expensive. A rollout that replaces too many warm replicas at once is an outage pattern.

The practical split is: `startupProbe` protects slow initialization, `readinessProbe` controls whether the pod receives traffic, and `livenessProbe` restarts a process that is no longer recoverable.

The timings interlock like this:

- `periodSeconds` is how often kubelet runs that probe.
- `failureThreshold` is how many consecutive failures Kubernetes tolerates before acting.
- `successThreshold` is how many consecutive successes are needed after a failure before the container is considered healthy or ready again; for liveness and startup probes this must be `1`.
- `initialDelaySeconds` moves the first probe later, but for slow vLLM startup a `startupProbe` is usually clearer because it gates the other probes.
- `timeoutSeconds` matters too: a probe that times out counts as a failure, so do not set it lower than a normal `/health` response under load.

For a slow model, the important budget is roughly `startupProbe.failureThreshold * startupProbe.periodSeconds`, plus any initial delay. With `failureThreshold: 60` and `periodSeconds: 10`, the pod has about ten minutes to get through model loading before kubelet kills and restarts it. Once the startup probe succeeds, liveness and readiness begin doing their normal jobs.

<figure class="diagram" aria-labelledby="probe-timing-diagram">
  <figcaption id="probe-timing-diagram" class="diagram__caption">Probe timing examples</figcaption>
  <div class="diagram__probe-model">
    <div class="diagram__probe-case">
      <div class="diagram__group-title">Safe vLLM startup</div>
      <div class="diagram__probe-axis" aria-hidden="true">
        <span>0s</span>
        <span>60s</span>
        <span>120s</span>
        <span>300s</span>
        <span>600s</span>
      </div>
      <div class="diagram__probe-row">
        <div class="diagram__probe-label">
          Model load
          <span class="diagram__note">weights, engine, KV cache, warmup</span>
        </div>
        <div class="diagram__probe-track">
          <span class="diagram__probe-segment diagram__probe-segment--work" style="--start: 1; --span: 4;">loading</span>
          <span class="diagram__probe-segment" style="--start: 5; --span: 2;">usable</span>
        </div>
      </div>
      <div class="diagram__probe-row">
        <div class="diagram__probe-label">
          Startup probe
          <span class="diagram__note">10s period x 60 failures = 600s budget</span>
        </div>
        <div class="diagram__probe-track">
          <span class="diagram__probe-segment diagram__probe-segment--warn" style="--start: 1; --span: 4;">failures allowed</span>
          <span class="diagram__probe-segment diagram__probe-segment--good" style="--start: 5; --span: 2;">success</span>
          <span class="diagram__probe-segment diagram__probe-segment--muted" style="--start: 7; --span: 6;">startup gate open</span>
        </div>
      </div>
      <div class="diagram__probe-row">
        <div class="diagram__probe-label">
          Readiness probe
          <span class="diagram__note">controls Service endpoints</span>
        </div>
        <div class="diagram__probe-track">
          <span class="diagram__probe-segment diagram__probe-segment--muted" style="--start: 1; --span: 4;">not ready</span>
          <span class="diagram__probe-segment diagram__probe-segment--good" style="--start: 5; --span: 2;">ready</span>
          <span class="diagram__probe-segment diagram__probe-segment--good" style="--start: 7; --span: 6;">receives traffic</span>
        </div>
      </div>
      <div class="diagram__probe-row">
        <div class="diagram__probe-label">
          Liveness probe
          <span class="diagram__note">restarts only after startup succeeds</span>
        </div>
        <div class="diagram__probe-track">
          <span class="diagram__probe-segment diagram__probe-segment--muted" style="--start: 1; --span: 5;">disabled by startupProbe</span>
          <span class="diagram__probe-segment diagram__probe-segment--good" style="--start: 6; --span: 7;">watch for stuck process</span>
        </div>
      </div>
    </div>

    <div class="diagram__probe-case">
      <div class="diagram__group-title">Too aggressive</div>
      <div class="diagram__probe-axis" aria-hidden="true">
        <span>0s</span>
        <span>30s</span>
        <span>60s</span>
        <span>90s</span>
        <span>120s</span>
      </div>
      <div class="diagram__probe-row">
        <div class="diagram__probe-label">
          Model load
          <span class="diagram__note">needs about 110s</span>
        </div>
        <div class="diagram__probe-track">
          <span class="diagram__probe-segment diagram__probe-segment--work" style="--start: 1; --span: 11;">still loading</span>
        </div>
      </div>
      <div class="diagram__probe-row">
        <div class="diagram__probe-label">
          Liveness probe
          <span class="diagram__note">30s period x 3 failures = about 90s</span>
        </div>
        <div class="diagram__probe-track">
          <span class="diagram__probe-segment diagram__probe-segment--warn" style="--start: 4; --span: 2;">fail 1</span>
          <span class="diagram__probe-segment diagram__probe-segment--warn" style="--start: 7; --span: 2;">fail 2</span>
          <span class="diagram__probe-segment diagram__probe-segment--danger" style="--start: 10; --span: 3;">restart / loop risk</span>
        </div>
      </div>
      <div class="diagram__probe-row">
        <div class="diagram__probe-label">
          Result
          <span class="diagram__note">pod never reaches readiness</span>
        </div>
        <div class="diagram__probe-track">
          <span class="diagram__probe-segment diagram__probe-segment--danger" style="--start: 1; --span: 10;">killed before model is usable</span>
          <span class="diagram__probe-segment" style="--start: 11; --span: 2;">would have loaded</span>
        </div>
      </div>
    </div>
  </div>
</figure>

The diagram is intentionally simplified. Real probe timing can drift a little because kubelet scheduling, probe timeouts, container startup, and HTTP response time all matter. The operational lesson is still useful: set the startup window from measured worst-case model load time, set readiness to protect users from cold or overloaded pods, and keep liveness conservative enough that it does not punish slow but healthy initialization.

### Performance tuning

Tune vLLM from a workload, not from a single benchmark number. Prompt length, output length, streaming behavior, concurrency, and cache reuse change the answer. A chat workload with short prompts and long decode has different pressure than a retrieval workload with long prompts and short answers.

Start with these questions:

- Is the bottleneck prefill, decode, queueing, CPU input processing, model weight loading, or KV cache pressure?
- Is the goal lower TTFT, lower inter-token latency, higher total tokens per second, or lower cost per token?
- Are you optimizing a single replica, or the fleet behavior behind a router?

The common knobs are:

| Knob | What it changes | Tradeoff |
| --- | --- | --- |
| `gpu_memory_utilization` | How much GPU memory vLLM can reserve for KV cache | More room can reduce preemption, but leaves less headroom for fragmentation and other GPU users |
| `max_num_seqs` | Maximum concurrent sequences in a batch | Higher concurrency can improve throughput, but increases KV pressure and tail latency |
| `max_num_batched_tokens` | Token budget per engine step | Larger values can improve TTFT and throughput; smaller values can improve inter-token latency |
| `max_model_len` | Maximum context length the server admits | Longer context increases KV cache demand and can lower concurrency |
| Tensor or pipeline parallelism | Spreads one model instance across GPUs | Allows larger models or more KV room, but adds communication and operational complexity |
| Quantization / dtype | Memory and compute format | Can reduce memory and cost, but requires measuring quality and latency |
| Prefix caching | Reuses repeated prompt prefixes | Helps repeated system prompts or retrieval prefixes, but only if traffic has reuse |

Chunked prefill is worth understanding because it directly affects perceived latency. It lets vLLM break large prefills into chunks and schedule them around decode work. Smaller `max_num_batched_tokens` values can favor inter-token latency because decode work gets less blocked by large prefills. Larger values can favor TTFT and throughput because more prefill tokens fit in a batch. That is a policy choice, not a universal best value.

CPU still matters. vLLM has an API server process, an engine process, and GPU worker processes. Tokenization, request parsing, scheduling coordination, metrics, and streaming all need CPU time. If CPU is starved or throttled, GPU metrics may look confusing: the GPU is not necessarily the bottleneck just because the workload is "GPU serving."

The tuning loop should be boring and repeatable:

1. Pick a representative workload: prompt lengths, output lengths, streaming, concurrency, and retry behavior.
2. Establish a baseline with one replica and stable model weights.
3. Change one thing at a time: batch token budget, sequence limit, context length, dtype, parallelism, or CPU allocation.
4. Compare TTFT, inter-token latency, end-to-end latency, request errors, queue depth, token throughput, and KV cache pressure.
5. Keep the setting only if it improves the metric you actually care about without breaking another one.

A Kubernetes Service normally routes to ready endpoints, but it is still a pretty blunt load balancer. It does not know that one vLLM pod has a long queue, another is holding a huge KV cache, and a third is mostly idle. For light traffic, the basic Service can be fine. For serious traffic, use a model-aware router or gateway that can look at per-replica health and load.

The layers have different jobs:

| Layer | What it sees | What it is good at | What it misses |
| --- | --- | --- | --- |
| **Kubernetes Service** | Ready pod endpoints | Basic service discovery and simple traffic spread | Queue depth, KV cache pressure, model identity, token load |
| **Ingress / edge load balancer** | HTTP traffic | TLS, auth, rate limits, external routing | Inference-specific worker state |
| **vLLM-aware router** | Model workers and inference stats | Model-aware routing, health, load, cache-aware decisions | Edge concerns like certificates and public auth policy |

FastAPI is not the load balancer here. vLLM uses a FastAPI/Uvicorn server inside each pod to expose the OpenAI-compatible HTTP API. That pod-local API server accepts a request, hands it to the vLLM engine, and streams the result back. It does not decide which replica in the fleet should get the next request.

For the fleet-level router, the usual progression is:

- **Small setup:** Kubernetes Service or an ingress routes to ready pods. Simple, but mostly unaware of model load.
- **Production setup:** use the vLLM production stack or vLLM Router so routing can consider model identity, replica health, pending/running requests, and cache-aware policies.
- **Edge/API layer:** keep Envoy, NGINX, HAProxy, or a cloud load balancer at the edge for TLS, auth, rate limits, and basic traffic management. Let the model-aware router make the inference-specific decision behind it.

A common request path is `client -> edge LB/ingress -> model-aware router -> one vLLM pod`.

<figure class="diagram" aria-labelledby="router-diagram">
  <figcaption id="router-diagram" class="diagram__caption">Model-aware routing</figcaption>
  <div class="diagram__stack">
    <div class="diagram__route">
      <div class="diagram__node">Client</div>
      <div class="diagram__connector" aria-hidden="true"></div>
      <div class="diagram__node">Edge LB / Ingress</div>
      <div class="diagram__connector" aria-hidden="true"></div>
      <div class="diagram__node diagram__node--accent">Model-aware router</div>
      <div class="diagram__connector diagram__connector--down diagram__connector--route-out" aria-hidden="true"></div>
    </div>
    <div class="diagram__group">
      <div class="diagram__group-title">Replica pool for one served model</div>
      <div class="diagram__node diagram__node--accent diagram__node--wide">Select one ready replica per request</div>
      <div class="diagram__connector diagram__connector--down" aria-hidden="true"></div>
      <div class="diagram__worker-grid">
        <div class="diagram__worker">
          <div class="diagram__node">vLLM pod A</div>
          <div class="diagram__node diagram__gpu">GPU</div>
        </div>
        <div class="diagram__worker">
          <div class="diagram__node">vLLM pod B</div>
          <div class="diagram__node diagram__gpu">GPU</div>
        </div>
        <div class="diagram__worker">
          <div class="diagram__node">vLLM pod C</div>
          <div class="diagram__node diagram__gpu">GPU</div>
        </div>
      </div>
    </div>
  </div>
</figure>

### What the router actually does

The router receives the OpenAI-style request, looks at the available vLLM workers, picks one worker, and forwards the request there. The selected worker still does the whole request. The router is not slicing one prompt across three pods.

A normal Kubernetes Service mostly sees ready endpoints. A vLLM-aware router can use inference-specific signals:

- Which replicas are healthy and registered.
- Which model each replica serves.
- How many requests are pending or running on each worker.
- Whether a routing key, session, or repeated prompt prefix should stick to the same worker.
- Whether a setup is using more advanced patterns like separate prefill and decode workers.

The router gets this information from a few places. Some of it is config: static backends, model names, aliases, and routing policy can be passed directly or managed through the production stack. In Kubernetes mode, the router uses the Kubernetes API with a namespace and label selector to discover vLLM pods. For load and health, it tracks what it sees while proxying requests and can scrape engine stats or metrics from the workers on an interval. The model-specific view is assembled from service discovery, router config, and live worker stats.

That helps with two common problems. First, it avoids sending new work to a replica that is already backed up while another one is open. Second, it can preserve locality when that matters, such as routing related requests back to the same worker to improve cache reuse. Plain round-robin does not have those signals.

The router also gives you a cleaner place to put inference-facing behavior: model aliases, endpoint discovery, health tracking, routing policy, and fleet metrics. Your edge ingress can stay focused on TLS, auth, rate limits, and public traffic policy. The router handles the "which model worker should get this?" decision.

To keep replicas effective:

- Give every replica the same served model name so clients do not care which pod answered.
- Use readiness probes so cold or broken pods are removed from the endpoint list.
- Use graceful shutdown so in-flight streaming requests get time to finish during rollouts.
- Set client and gateway timeouts long enough for streaming responses.
- Add retry behavior carefully. Retrying a failed prefill is usually fine; retrying halfway through a streamed response can duplicate work or return inconsistent output.
- Watch vLLM `/metrics`, especially queue depth, time-to-first-token, token throughput, request errors, and GPU memory pressure.
- Autoscale from inference signals, not plain CPU. CPU can look bored while the GPU is doing all the work.
- Use a PodDisruptionBudget so maintenance does not drain too much serving capacity at once.

Three pods only help when traffic reaches ready, healthy, not-overloaded replicas.

The official [vLLM production stack](https://docs.vllm.ai/en/stable/deployment/integrations/production-stack/) is a better starting point once you move past one pod and one model. It wraps upstream vLLM, deploys through Helm, and includes routing and observability patterns that become important quickly.

### Failure scenarios to plan for

Plan for these failure modes before users hit them:

- **Pod dies mid-stream:** the user sees a failed response. Retrying starts over on another pod because the KV cache lived in the dead pod.
- **Pod starts but model is not ready:** readiness probes must keep it out of service until weights are loaded and `/health` is actually useful.
- **Rollout replaces too much capacity:** a PodDisruptionBudget and slow rollout strategy keep maintenance from draining the fleet.
- **Router sends work to a hot pod:** use model-aware routing and watch queue depth, TTFT, and GPU memory pressure.
- **Gateway timeout is too short:** long generations can be killed by an HTTP timeout even though the model is still working.
- **Client retries after partial streaming:** the replacement request can duplicate work and confuse the user experience.
- **GPU OOM:** the process may fail the request, restart, or become unhealthy depending on how the failure surfaces. Watch memory pressure before it becomes a user-facing outage.
- **Cold model download during deploy:** a new pod may spend minutes pulling weights before it can serve anything. Cache weights or plan rollout timing.

## What to watch in production

The production questions are direct:

- Are requests waiting in a queue?
- Is decode throughput high enough?
- Is time-to-first-token acceptable?
- Is GPU memory full because of weights, KV cache, or fragmentation?
- Are long-context requests crowding out short ones?
- Are rollouts causing cold-start latency spikes?
- Are clients retrying and accidentally multiplying load?

Useful metric categories:

- **Queue depth:** waiting requests or waiting sequences.
- **Running load:** active/running requests and active sequences.
- **TTFT:** time from request arrival to first streamed token.
- **Inter-token latency:** how fast tokens arrive after streaming starts.
- **Prompt throughput:** prompt/prefill tokens processed per second.
- **Generation throughput:** decode/output tokens generated per second.
- **GPU KV cache usage:** cache blocks used/free, cache utilization, or related memory pressure.
- **Request outcomes:** success, cancellation, timeout, and error counts.
- **Scheduler pressure:** pending work, preemptions, or signs that long requests are crowding the batch.

For Kubernetes specifically, also watch:

- GPU node capacity and scheduling failures.
- Model weight download time.
- Persistent volume performance if weights are cached.
- Readiness probes that only pass after the model is actually usable.
- Pod disruption budgets for serving capacity.
- Autoscaling signals that reflect inference pressure, not just CPU.

LLM serving does not scale like a typical web API. CPU, request rate, and latency are not enough. CPU can look calm while the GPU is out of memory, the decode queue is backed up, or one long-context request is eating the KV cache. The expensive resources are GPU memory, GPU compute, and the scheduling policy that decides which tokens get generated next.

## Autoscaling vLLM

Horizontal Pod Autoscaling is useful, but vLLM makes the usual CPU-based HPA weak. The HPA controller is a periodic control loop. It reads metrics, calculates a desired replica count, and updates the target workload's scale. That works well when new replicas become useful quickly. vLLM replicas may take minutes to pull an image, stage weights, load the model, and pass readiness, so reactive scaling can arrive late.

CPU utilization is usually the wrong primary signal. CPU can be low while the GPU is full, the KV cache is tight, or requests are waiting in the scheduler. Better signals come from vLLM and the router:

| Signal | Why it helps | How to use it |
| --- | --- | --- |
| `vllm:num_requests_waiting` | Direct queue pressure | Good scale-up trigger when sustained above a small per-replica target |
| `vllm:num_requests_running` | Active batch pressure | Useful paired with waiting requests so you know whether replicas are busy or idle |
| `vllm:request_queue_time_seconds` | User-visible waiting before execution | Better SLO signal than raw request rate |
| `vllm:time_to_first_token_seconds` | Streaming user experience | Good alert and scaling input, but use percentiles carefully |
| `vllm:inter_token_latency_seconds` | Decode smoothness | Helps catch overloaded decode after the first token |
| `vllm:kv_cache_usage_perc` | KV cache pressure | Good guardrail; high values may mean scale out, lower concurrency, shorter context, or more KV capacity |
| Router pending/running requests | Fleet-level load before a pod is selected | Often better than per-pod metrics when the router owns admission and load balancing |

In Kubernetes, HPA can scale from resource metrics, custom metrics, or external metrics. For vLLM, that usually means Prometheus scrapes `/metrics`, then a Prometheus adapter exposes a cleaned-up metric through `custom.metrics.k8s.io` or `external.metrics.k8s.io`. Do not assume the raw Prometheus metric name is the exact HPA metric name; many adapters map `vllm:num_requests_waiting` into a Kubernetes-friendly name such as `vllm_requests_waiting_per_pod`.

An HPA sketch might look like this:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: vllm-gpt-oss
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: vllm-gpt-oss
  minReplicas: 2
  maxReplicas: 12
  metrics:
    - type: Pods
      pods:
        metric:
          # Example adapter metric derived from vllm:num_requests_waiting.
          name: vllm_requests_waiting_per_pod
        target:
          type: AverageValue
          averageValue: "2"
    - type: Pods
      pods:
        metric:
          # Example adapter metric derived from vllm:kv_cache_usage_perc.
          name: vllm_kv_cache_usage_ratio
        target:
          type: AverageValue
          averageValue: "0.75"
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Percent
          value: 100
          periodSeconds: 60
        - type: Pods
          value: 2
          periodSeconds: 60
      selectPolicy: Max
    scaleDown:
      stabilizationWindowSeconds: 600
      policies:
        - type: Pods
          value: 1
          periodSeconds: 300
```

Those thresholds are placeholders, not recommendations. You have to load test your own model and hardware. The shape is the important part: scale up quickly from sustained queue or cache pressure, scale down slowly, and keep enough warm capacity to absorb normal bursts.

Fast scale-up matters because new vLLM capacity is late capacity. HPA can ask for more replicas as soon as queue pressure appears, but those replicas still have to schedule onto GPU nodes, pull an image if needed, mount or download weights, initialize the engine, allocate KV cache, and pass readiness. If startup takes several minutes, a conservative scale-up policy can spend those minutes watching the queue get worse. That is why the example allows scale-up by either 100 percent or two pods per minute and uses `selectPolicy: Max`.

Slow scale-down matters for the opposite reason. A warm vLLM pod is valuable, and it might still be serving long streaming responses even after the aggregate HPA metric has dropped below the target. HPA decides based on sampled metrics, not on whether a specific HTTP stream has finished. If you remove too much capacity as soon as the queue clears, you can kill useful warm replicas, shrink into the next burst, or terminate pods that are still carrying user-visible responses.

The scale-down policy should therefore be deliberately boring:

- Use a long `scaleDown.stabilizationWindowSeconds` so a short quiet period does not immediately remove replicas.
- Limit downscale rate to a small number of pods per window, often one pod at a time for expensive GPU replicas.
- Keep `minReplicas` high enough for normal warm capacity, not just for theoretical availability.
- Pair HPA with a PodDisruptionBudget so voluntary maintenance and autoscaling do not drain too much of the serving pool at once.

Some practical HPA rules:

- Use `minReplicas` for warm capacity. Do not expect HPA to save you from zero if model startup takes minutes.
- Prefer queue pressure and queue time over raw request rate. One long-context request and one short chat turn are not equal.
- Watch high-percentile TTFT and inter-token latency, but be careful using percentile histograms directly as HPA inputs. They can be noisy and adapter-dependent.
- Use multiple metrics when they represent different failure modes. HPA chooses the largest recommended replica count across metrics.
- Scale down slowly. A vLLM pod is expensive to warm, and removing a warm replica can make the next burst worse.
- Pair HPA with cluster autoscaling only if GPU nodes can appear fast enough. If cloud GPU nodes take several minutes to provision, HPA may ask for pods that sit Pending.
- Keep router behavior aligned with autoscaling. New pods should not receive traffic until ready, and draining pods should stop receiving new long-running streams before termination.

Zero-downtime scale-down is not just an HPA setting. It is a drain path:

1. HPA lowers the Deployment replica count.
2. Kubernetes chooses a pod to terminate and sets a deletion timestamp.
3. The pod should stop receiving new traffic. For normal Services, terminating endpoints are marked not ready, and load balancers should stop using them for regular traffic. A model-aware router should also stop assigning new requests to that worker as soon as it sees the pod terminating or not ready.
4. The pod keeps serving existing in-flight requests during `terminationGracePeriodSeconds`.
5. The vLLM process handles `SIGTERM` by refusing new work, finishing or timing out existing streams, flushing metrics/logs, and exiting before the grace period ends.

That means your application and router need a real drain behavior. Readiness removes the pod from new Service traffic, but readiness alone does not finish a streaming response already in progress. For vLLM, that matters because a completion stream can run longer than a normal web request. Use a `preStop` hook or shutdown handler to mark the worker draining before the process exits, have the router respect that drain state, and set `terminationGracePeriodSeconds` longer than your expected long-running stream or gateway timeout. If the grace period expires, kubelet can force-kill the container, and any active stream dies.

The safest pattern is: stop admitting new requests first, wait for in-flight requests to finish or hit an explicit maximum drain time, then exit. If you cannot implement graceful drain in the vLLM worker itself, put that behavior in the model-aware router: it should remove the terminating worker from its candidate set, keep existing proxied streams open, and only let Kubernetes finish termination after the grace window.

### Testing graceful scale-down

Do not trust graceful termination because the YAML looks right. Test it with real streaming traffic.

At minimum, test three paths:

- **Manual pod termination:** start long streaming requests, then delete one vLLM pod and verify those streams finish.
- **Deployment scale-down:** run traffic through the Service or router, scale the Deployment down by one replica, and verify new requests avoid the terminating pod while existing streams continue.
- **HPA downscale:** generate enough traffic to scale up, let traffic fall below the HPA target, and verify the HPA removes pods one at a time without request failures.

The basic shape is:

```sh
kubectl get pods -l app=vllm-gpt-oss -w
kubectl get endpointslice -l kubernetes.io/service-name=vllm-gpt-oss -w
kubectl logs -f deploy/vllm-gpt-oss
```

In another terminal, run a load generator that keeps streaming requests open. Use whatever tooling your team already trusts: `k6`, `Locust`, `vegeta`, a small Python script using the OpenAI client, or the vLLM benchmark tools. The important part is not the tool; it is the request shape. Use prompts and `max_tokens` values that create streams long enough to overlap with pod termination.

Then trigger termination while traffic is active:

```sh
kubectl delete pod <one-vllm-pod>
kubectl scale deployment/vllm-gpt-oss --replicas=2
```

Watch for the actual behavior:

- The pod should enter `Terminating`.
- EndpointSlices should stop advertising that pod as a normal ready endpoint for new Service traffic.
- The router should mark the worker draining or remove it from the candidate set for new requests.
- Existing streams should keep receiving tokens until they finish or hit your explicit drain timeout.
- The container should exit before `terminationGracePeriodSeconds` expires.
- Clients should not see mid-stream disconnects, 502/503 spikes, or duplicated retries.

Add a negative test too. Set `terminationGracePeriodSeconds` too low in a staging environment and prove that long streams get cut off. That gives you a concrete lower bound for the real value. Then test the production value with a margin above your longest expected stream or gateway timeout.

The useful metrics during this test are request errors, canceled requests, active streams per replica, router selected-backend counts, pod termination time, EndpointSlice readiness changes, and the gap between `SIGTERM` and process exit. If you cannot observe those, you cannot really know whether scale-down is zero-downtime.

## Production checklist

Before calling a vLLM deployment production, I would want at least this:

- Pin the vLLM image tag and digest. Do not deploy `latest` on purpose.
- Set GPU requests/limits and use the right node selectors, tolerations, or runtime class for your cluster.
- Use startup, readiness, and liveness probes with timings that match model load time.
- Add graceful shutdown and enough termination time for streaming requests.
- Use a PodDisruptionBudget so maintenance cannot remove too much serving capacity.
- Decide where model weights live and how new pods warm them quickly.
- Put realistic request, stream, and gateway timeouts in front of the service.
- Scrape vLLM metrics and alert on queue depth, TTFT, token throughput, request errors, and GPU memory pressure.
- Autoscale from inference signals, not plain CPU.
- Load test with realistic prompt lengths, output lengths, concurrency, and streaming clients.
- Decide retry policy explicitly. Failed prefill and failed mid-stream are not the same thing.
- Keep a rollback path for model, image, and router changes.

## Common misconceptions

- **"Replicas split one request."** They do not. One HTTP request goes to one selected pod unless you are using model parallelism inside a deployment.
- **"FastAPI is the fleet load balancer."** It is the pod-local HTTP server. Fleet routing happens before the request reaches a specific vLLM pod.
- **"CPU is the bottleneck."** Sometimes, but GPU memory, GPU compute, KV cache pressure, and scheduling are usually the first things to inspect.
- **"Bigger context is always better."** Bigger context can reduce concurrency and make KV cache pressure worse.
- **"More replicas fix routing."** More replicas help only if traffic reaches ready, healthy, not-overloaded pods.
- **"Quantization is free."** Quantization can reduce memory, but it changes the storage and math tradeoffs. Measure quality and latency.
- **"A Kubernetes Service knows model load."** It mostly knows endpoints. It does not understand tokens, cache, or model-specific queues.
- **"Retrying is harmless."** Retrying can multiply load, especially if clients retry while the original request is still running.

## The takeaway

vLLM targets a specific serving problem: keeping high-throughput LLM inference from wasting GPU memory and starving the batch scheduler.

Start with KV cache. PagedAttention is the memory-management technique that makes the cache easier to pack. Kubernetes lets you run the service with scheduling, rollouts, and health checks, but it does not remove the need to measure token throughput, queueing, latency, and GPU memory.

Start with one model, one GPU, one clear workload, and one good dashboard. Then scale from evidence.

Further reading:

- [Efficient Memory Management for Large Language Model Serving with PagedAttention](https://arxiv.org/abs/2309.06180)
- [vLLM Online Serving](https://docs.vllm.ai/en/stable/serving/online_serving/)
- [vLLM Production Stack](https://docs.vllm.ai/en/stable/deployment/integrations/production-stack/)
- [vLLM Optimization and Tuning](https://docs.vllm.ai/en/stable/configuration/optimization/)
- [vLLM Production Metrics](https://docs.vllm.ai/en/stable/usage/metrics/)
- [Kubernetes Horizontal Pod Autoscaling](https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/)
