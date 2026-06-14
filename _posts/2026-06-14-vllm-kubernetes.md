---
title: Running vLLM in Kubernetes
excerpt: A practical look at vLLM pods, GPU scheduling, replicas, model-aware routing, readiness probes, and production checks.
tags:
  - ai
  - inference
  - kubernetes
  - vllm
series: vllm-inference
---

The first post covered the serving path, prefill, decode, KV cache, and PagedAttention. This post moves the same vLLM service into Kubernetes: GPU scheduling, replicas, routing, probes, and production failure modes.

<!--more-->

{% include series-nav.html %}

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
          image: vllm/vllm-openai:latest
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

## Production checklist

Before calling a vLLM deployment production, I would want at least this:

- Pin the vLLM image tag. Do not deploy `latest` on purpose.
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
