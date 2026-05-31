---
title: vLLM Inference 101
excerpt: A walkthrough of LLM inference, KV cache basics, PagedAttention, and running vLLM on Kubernetes.
tags:
  - ai
  - inference
  - kubernetes
  - vllm
---

[vLLM](https://docs.vllm.ai/) is an inference engine for serving large language models. The practical version: it helps keep GPUs busy and avoids wasting a bunch of memory while requests come and go.

That memory part matters. Inference is not just "load model, ask question, get answer." The server has to tokenize input, run model forward passes, keep attention state around, batch users together, stream tokens back, and somehow not run out of GPU memory while everyone sends prompts of wildly different sizes.

<!--more-->

This is a 101 walkthrough. The goal is to make the moving parts less mysterious: what inference is doing, why the KV cache matters, how PagedAttention helps, and what this looks like when you run it in Kubernetes.

## Inference is the serving path

Training changes model weights. Inference uses fixed weights to produce outputs.

A model weight is one of the learned numbers inside the model. During training, the optimizer nudges billions of these numbers around until the model gets better at predicting the next token. At serving time, those weights are loaded into GPU memory and mostly treated as read-only.

Weights are large because there are a lot of them, and each one takes space. A 7B parameter model has roughly seven billion learned values. If those values are stored as FP16 or BF16, that is about two bytes per weight, so the raw weights are already around 14 GB before you count runtime overhead. Bigger models add more layers, wider hidden dimensions, more attention heads, larger feed-forward blocks, and sometimes larger vocabularies. All of that means more learned numbers to store.

Precision matters too. FP32 weights take about four bytes each, FP16/BF16 take about two, and 8-bit or 4-bit quantized weights take less. Quantization can make a model much easier to fit on a GPU, but it is a storage and math tradeoff, not free magic.

LoRA is a little different. Instead of changing every base weight, a LoRA adapter adds a smaller set of learned weights on top of the base model. That lets you adapt behavior without shipping a whole new copy of the model. The base weights are still the big thing you load; the LoRA weights are the small overlay you can attach when you need that variant.

Autoregressive just means the model generates one token based on the tokens that came before it. It predicts "what comes next?", appends that token, then does it again. That is the usual shape for chat and text-generation models. Other model types do different jobs: an embedding model turns text into vectors, a classifier picks a label, and non-autoregressive generators try to produce output without that same one-token-at-a-time loop. Some encoder-decoder models still decode autoregressively, so this is more about the generation pattern than the model family name. vLLM can serve more than plain text generation, but this walkthrough is mostly about the autoregressive case because that is where prefill, decode, and KV cache behavior matter most.

For an autoregressive language model, inference usually has two phases worth knowing:

1. **Prefill** reads the prompt. The model processes the input tokens and builds the attention state it will need later.
2. **Decode** generates new tokens, usually one at a time, while reusing the state from previous tokens.

The model weights are big, but once they are loaded they mostly sit there. The request memory is the jumpy part. A short prompt asking for 20 tokens and a giant prompt asking for 2,000 tokens do not have the same shape. A good inference server has to deal with that without letting one chunky request drag down the whole batch.

vLLM sits in that serving path. It exposes an HTTP server with OpenAI-compatible endpoints such as `/v1/completions`, `/v1/chat/completions`, and `/v1/responses`, and handles the engine work underneath: batching, scheduling, decoding, and KV cache management.

## KV cache basics

A tensor is just a block of numbers with shape. A single number is a tiny tensor, a list of numbers is a vector, a grid of numbers is a matrix, and models usually deal with bigger stacks of these. GPUs are good at moving and multiplying tensors quickly, which is a large part of why they are useful for LLMs.

Transformer attention is the part of the model that lets each token look at other tokens for context. If the prompt is "the dog chased the ball because it was red," attention helps the model decide what "it" probably refers to. Under the hood, the model turns token representations into three sets of tensors: queries, keys, and values.

The rough idea:

- **Query:** what the current token is looking for.
- **Key:** what earlier tokens offer as lookup handles.
- **Value:** the actual information pulled from those earlier tokens.

The model compares queries to keys to decide which values matter. That is not the whole transformer, but it is enough to understand why the KV cache exists.

During generation, recomputing keys and values for the whole prompt every time would be expensive. The KV cache stores them so decode can reuse them.

At a high level:

- **K** means key tensors.
- **V** means value tensors.
- The cache grows with sequence length.
- It exists per active request.
- It lives in GPU memory, which is usually the thing you run out of first.

The cache is helpful because it makes token generation much cheaper than starting from scratch every time. It is also a bottleneck because long prompts, long outputs, larger batches, and lots of concurrent users all compete for the same GPU memory.

A useful mental model:

```text
model weights = mostly fixed memory
KV cache      = dynamic per-request memory
```

If the server cannot pack KV cache efficiently, it has to run smaller batches. Smaller batches usually mean lower throughput and worse GPU utilization. Nobody bought the expensive GPU so it could sit around politely waiting.

## Why naive cache allocation hurts

Requests do not arrive in neat little rows. One user sends a tiny chat message. Another sends a long document. Another starts streaming and disconnects early. Someone else turns on a decoding strategy that fans out multiple candidates.

If the serving system reserves big contiguous chunks for each request, memory gets wasted in two common ways:

- **Internal fragmentation:** a request reserves more memory than it actually uses.
- **External fragmentation:** free memory exists, but not in a shape that is easy to reuse.

The [PagedAttention paper](https://arxiv.org/abs/2309.06180) calls this out as a core problem for high-throughput LLM serving: KV cache memory is large, grows and shrinks dynamically, and inefficient management limits batch size.

## PagedAttention

PagedAttention borrows an old operating-system idea: split memory into blocks and map logical positions to physical blocks.

Instead of forcing each request's KV cache to live in one contiguous allocation, vLLM can store it in non-contiguous blocks. The request still has a logical sequence of tokens. The engine keeps track of where the matching KV blocks live.

That gives the serving layer a few nice properties:

- It can allocate KV cache as the sequence grows.
- It can reuse freed blocks when requests finish.
- It can waste less memory on uneven sequence lengths.
- It can support sharing patterns used by more complex decoding strategies.

That is the trick that made vLLM interesting: better KV cache packing means larger effective batches, which usually means better throughput at similar latency for many workloads.

## What vLLM adds around it

PagedAttention is the memory idea. vLLM is the serving system wrapped around it.

The pieces operators usually care about first are:

- **OpenAI-compatible serving:** point existing clients at a vLLM base URL.
- **Continuous batching:** serve active requests together as they arrive and finish at different times.
- **Streaming:** return tokens as they are generated.
- **Parallelism options:** spread larger models across GPUs when needed.
- **Cache controls:** tune context length, GPU memory usage, and KV cache behavior.
- **Observability hooks:** figure out whether the pain is tokens, memory, latency, or queueing.

A request is not usually handled as "one thread owns one request until it is done." The HTTP layer accepts the request asynchronously, then hands it to the vLLM engine. The engine tracks requests as sequences, keeps them in waiting and running sets, and the scheduler decides which sequences get work in the next step.

The GPU work is batched. During prefill, vLLM can process prompt tokens for one or more requests. During decode, it usually advances active requests token by token, batching multiple requests together when it can. So the unit of work is closer to "scheduled token and sequence work" than "thread per request." There are still CPU threads and processes around the server and workers, but the performance trick is scheduling and batching GPU work, not spinning up a dedicated thread for every user.

A local server can be as small as:

```sh
vllm serve openai/gpt-oss-20b \
  --host 0.0.0.0 \
  --port 8000 \
  --dtype auto
```

This is an OpenAI open-weight model. That distinction matters: vLLM serves model weights you can run in your own environment, not hosted API-only models.

Then call it like an OpenAI-style endpoint:

```sh
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "openai/gpt-oss-20b",
    "messages": [
      {"role": "user", "content": "Explain KV cache in one paragraph."}
    ],
    "max_tokens": 120
  }'
```

For `gpt-oss`, vLLM's guide points at `/v1/responses` as the better endpoint when you want the full reasoning/tool-use path. The chat completions call above is just the familiar "does the server answer?" version.

For a real service, the interesting flags are usually not the first ones you type. They are the ones that decide capacity and failure behavior:

- `--max-model-len` controls the maximum context length the server will accept.
- `--gpu-memory-utilization` controls how aggressively vLLM uses GPU memory.
- `--tensor-parallel-size` spreads a model across multiple GPUs.
- `--served-model-name` lets the API expose a stable model name even if the checkpoint path changes.

The exact values depend on the model, GPU, traffic pattern, and latency target. Tune them from measurements, not vibes. Vibes are great for playlists, less great for capacity planning.

## Running vLLM in Kubernetes

Kubernetes does not magically make inference efficient. It gives you scheduling, rollouts, service discovery, secrets, health checks, and resource boundaries. vLLM still needs the right GPU, enough memory, model access, and sane limits.

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

That is enough to see the pieces, but it is not a full production setup. For production, pin image tags, use GPU node selectors or runtime classes, set requests as well as limits, think through model download and warmup time, and decide how rollouts should behave when a pod takes minutes to become ready.

## Using replicas without dropping requests

Multiple replicas of the same model are useful when each replica has enough GPU capacity to serve real traffic. In practice that usually means one vLLM pod per GPU, all serving the same model name, behind one Service or router.

One request is not split across those replicas. Kubernetes, an ingress, or a model router picks one ready pod for the HTTP request. That pod runs the full prefill, owns the KV cache for that request, generates the decode tokens, and streams the response back. If the pod dies halfway through, the request usually fails and a retry starts over on another pod.

So replicas give you request-level parallelism: three pods can handle three different requests at the same time. They do not combine into one bigger brain for a single request. If you need one model instance to span multiple GPUs, that is tensor parallelism or pipeline parallelism inside the vLLM deployment, not Kubernetes replicas.

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

Readiness is the important bit. A pod should not receive traffic just because the container process exists. It should receive traffic after the model is loaded and the server can answer. Otherwise Kubernetes can send requests to a pod that is still downloading weights, warming kernels, or generally getting its shoes on. The startup probe gives slow model loads time to finish before the liveness probe starts judging the container.

A Kubernetes Service normally routes to ready endpoints, but it is still a pretty blunt load balancer. It does not know that one vLLM pod has a long queue, another is holding a huge KV cache, and a third is mostly idle. For light traffic, the basic Service can be fine. For serious traffic, use a model-aware router or gateway that can look at per-replica health and load.

FastAPI is not the load balancer here. vLLM uses a FastAPI/Uvicorn server inside each pod to expose the OpenAI-compatible HTTP API. That pod-local API server accepts a request, hands it to the vLLM engine, and streams the result back. It does not decide which replica in the fleet should get the next request.

For the fleet-level router, the usual progression is:

- **Small setup:** Kubernetes Service or an ingress routes to ready pods. Simple, but mostly unaware of model load.
- **Production setup:** use the vLLM production stack or vLLM Router so routing can consider model identity, replica health, pending/running requests, and cache-aware policies.
- **Edge/API layer:** keep Envoy, NGINX, HAProxy, or a cloud load balancer at the edge for TLS, auth, rate limits, and basic traffic management. Let the model-aware router make the inference-specific decision behind it.

So the shape is usually `client -> edge LB/ingress -> model-aware router -> one vLLM pod`.

### What the router actually does

The router is the traffic cop for the model fleet. It receives the OpenAI-style request, looks at the available vLLM workers, picks one worker, and forwards the request there. The selected worker still does the whole request. The router is not slicing one prompt across three pods.

What makes it useful is that it can make a better choice than a plain Kubernetes Service. A normal Service mostly sees ready endpoints. A vLLM-aware router can use inference-specific signals:

- Which replicas are healthy and registered.
- Which model each replica serves.
- How many requests are pending or running on each worker.
- Whether a routing key, session, or repeated prompt prefix should stick to the same worker.
- Whether a setup is using more advanced patterns like separate prefill and decode workers.

The router gets this information from a few places. Some of it is config: static backends, model names, aliases, and routing policy can be passed directly or managed through the production stack. In Kubernetes mode, the router uses the Kubernetes API with a namespace and label selector to discover vLLM pods. For load and health, it tracks what it sees while proxying requests and can scrape engine stats/metrics from the workers on an interval. So the model-specific view is assembled from service discovery plus router config plus live worker stats. No crystal ball, thankfully.

That helps with two common problems. First, it avoids sending new work to a replica that is already backed up while another one is open. Second, it can preserve locality when that matters, such as routing related requests back to the same worker to improve cache reuse. Plain round-robin does not know any of that. It just keeps dealing cards.

The router also gives you a cleaner place to put inference-facing behavior: model aliases, endpoint discovery, health tracking, routing policy, and fleet metrics. Your edge ingress can stay focused on boring-but-important things like TLS, auth, and rate limits. The router handles the "which model worker should get this?" decision.

To keep replicas useful:

- Give every replica the same served model name so clients do not care which pod answered.
- Use readiness probes so cold or broken pods are removed from the endpoint list.
- Use graceful shutdown so in-flight streaming requests get time to finish during rollouts.
- Set client and gateway timeouts long enough for streaming responses.
- Add retry behavior carefully. Retrying a failed prefill is usually fine; retrying halfway through a streamed response can duplicate work or return weird user experience.
- Watch vLLM `/metrics`, especially queue depth, time-to-first-token, token throughput, request errors, and GPU memory pressure.
- Autoscale from inference signals, not plain CPU. CPU can look bored while the GPU is doing all the work.
- Use a PodDisruptionBudget so maintenance does not drain too much serving capacity at once.

The goal is not "three pods exist." The goal is "traffic is spread across three ready, healthy, not-overloaded replicas." Those are different things, because distributed systems enjoy technicalities.

The official [vLLM production stack](https://docs.vllm.ai/en/stable/deployment/integrations/production-stack/) is a better starting point once you move past one pod and one model. It wraps upstream vLLM, deploys through Helm, and includes routing and observability patterns that become important quickly.

## What to watch in production

The questions are pretty practical:

- Are requests waiting in a queue?
- Is decode throughput high enough?
- Is time-to-first-token acceptable?
- Is GPU memory full because of weights, KV cache, or fragmentation?
- Are long-context requests crowding out short ones?
- Are rollouts causing cold-start latency spikes?
- Are clients retrying and accidentally multiplying load?

For Kubernetes specifically, also watch:

- GPU node capacity and scheduling failures.
- Model weight download time.
- Persistent volume performance if weights are cached.
- Readiness probes that only pass after the model is actually usable.
- Pod disruption budgets for serving capacity.
- Autoscaling signals that reflect inference pressure, not just CPU.

LLM serving feels weird if you are coming from normal web services. For a typical API, CPU, request rate, and latency often tell you enough to start scaling. For an LLM server, CPU can look calm while the GPU is out of memory, the decode queue is backed up, or one long-context request is eating the KV cache. The expensive resources are GPU memory, GPU compute, and the scheduling policy that decides which tokens get generated next.

## The takeaway

vLLM is useful because it attacks a specific serving problem: keeping high-throughput LLM inference from wasting GPU memory and starving the batch scheduler.

KV cache is the thing to understand first. PagedAttention is the memory-management trick that makes the cache easier to pack. Kubernetes is the operational wrapper that lets you run it as a service, but it does not remove the need to measure token throughput, queueing, latency, and GPU memory.

Start with one model, one GPU, one clear workload, and one good dashboard. Then scale from evidence.

Further reading:

- [Efficient Memory Management for Large Language Model Serving with PagedAttention](https://arxiv.org/abs/2309.06180)
- [vLLM Online Serving](https://docs.vllm.ai/en/stable/serving/online_serving/)
- [vLLM Production Stack](https://docs.vllm.ai/en/stable/deployment/integrations/production-stack/)
