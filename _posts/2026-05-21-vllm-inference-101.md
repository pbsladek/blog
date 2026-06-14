---
title: A Dense Introduction to vLLM Inference
excerpt: A dense walkthrough of LLM inference, stochastic generation, KV cache basics, PagedAttention, and local serving options.
tags:
  - ai
  - inference
  - vllm
series: vllm-inference
---

[vLLM](https://docs.vllm.ai/) is an inference engine for serving large language models. It keeps GPUs busy and reduces memory waste while requests come and go.

That memory part matters. Inference is not just "load model, ask question, get answer." The server has to tokenize input, send those tokens through the model to produce the next-token probabilities, keep attention state around, batch users together, stream tokens back, and avoid running out of GPU memory while prompts vary in size.

<!--more-->

We start with the serving path, then move through KV cache, PagedAttention, and local serving.

{% include series-nav.html %}

The serving path:

<figure class="diagram diagram--flow" aria-labelledby="serving-path-diagram">
  <figcaption id="serving-path-diagram" class="diagram__caption">vLLM serving path</figcaption>
  <div class="diagram__pipeline">
    <div class="diagram__node diagram__node--wide">Client request</div>
    <div class="diagram__connector diagram__connector--down" aria-hidden="true"></div>
    <div class="diagram__group diagram__service">
      <div class="diagram__group-title">vLLM service</div>
      <div class="diagram__stages">
        <div class="diagram__node diagram__node--accent">
          API server
          <span class="diagram__note">HTTP request handling</span>
        </div>
        <div class="diagram__connector diagram__connector--down" aria-hidden="true"></div>
        <div class="diagram__node">
          Input processing
          <span class="diagram__note">Tokenization happens here</span>
        </div>
        <div class="diagram__connector diagram__connector--down" aria-hidden="true"></div>
        <div class="diagram__node">
          Engine core
          <span class="diagram__note">Scheduler and KV cache</span>
        </div>
        <div class="diagram__connector diagram__connector--down" aria-hidden="true"></div>
        <div class="diagram__node">
          GPU worker
          <span class="diagram__note">Prefill and decode passes</span>
        </div>
      </div>
    </div>
    <div class="diagram__connector diagram__connector--down" aria-hidden="true"></div>
    <div class="diagram__node diagram__node--wide">Stream response</div>
  </div>
</figure>

The HTTP API is just the boundary. Tokenization still happens inside the vLLM service, usually as part of input processing before the engine core schedules model work. The scheduler, KV cache, and decode loop are where the expensive serving decisions happen.

## Quick terms

| Term | Plain meaning |
| --- | --- |
| **Weight** | A learned number inside the model. Weights are loaded into GPU memory for serving. |
| **Parameter** | A count of learned weights. A 7B model has roughly seven billion parameters. |
| **Token** | A chunk of text after tokenization. Models read and generate tokens, not raw words. |
| **Context length** | The maximum number of input plus output tokens a request can use. |
| **Sequence** | One active request's token stream from the engine's point of view. |
| **Batch** | Multiple sequences served together in one scheduler step. |
| **Prefill** | The prompt-processing phase. It builds the attention state for the input tokens. |
| **Decode** | The generation phase. It usually advances active requests one token at a time. |
| **KV cache** | Per-request attention state stored so decode can reuse earlier keys and values. |
| **TTFT** | Time to first token. How long the user waits before the response starts streaming. |
| **Throughput** | How much work the system completes, usually measured in tokens per second. |
| **Stochastic** | Involving randomness. In generation, this usually means sampling from likely next tokens instead of always taking the top one. |

## Inference is the serving path

Training changes model weights. Inference uses fixed weights to produce outputs.

A model weight is one of the learned numbers inside the model. During training, the optimizer nudges billions of these numbers around until the model gets better at predicting the next token. At serving time, those weights are loaded into GPU memory and mostly treated as read-only.

Weights are large because there are a lot of them, and each one takes space. A 7B parameter model has roughly seven billion learned values. If those values are stored as FP16 or BF16, that is about two bytes per weight, so the raw weights are already around 14 GB before you count runtime overhead. Bigger models add more layers, wider hidden dimensions, more attention heads, larger feed-forward blocks, and sometimes larger vocabularies. All of that means more learned numbers to store.

Precision matters too. FP32 weights take about four bytes each, FP16/BF16 take about two, and 8-bit or 4-bit quantized weights take less. Quantization can make a model much easier to fit on a GPU, but it is a storage and math tradeoff.

For serving, quantization is usually about fitting the model, increasing concurrency, or lowering cost. If the weights take less memory, you may have more room for KV cache and more active requests. That is the upside.

The tradeoff is that quantization changes how the model is represented and sometimes how kernels run. AWQ, GPTQ, FP8, INT8, and INT4 are not interchangeable stickers. Measure output quality, TTFT, decode throughput, memory use, and hardware support before declaring victory. A smaller model that produces worse answers or runs on slow kernels is not automatically better.

LoRA is a little different. Instead of changing every base weight, a LoRA adapter adds a smaller set of learned weights on top of the base model. That lets you adapt behavior without shipping a whole new copy of the model. The base weights are still the big thing you load; the LoRA weights are the small overlay you can attach when you need that variant.

Autoregressive means the model generates one token based on the tokens that came before it. It predicts "what comes next?", appends that token, then does it again. That is the standard pattern for chat and text-generation models. Other model types do different jobs: an embedding model turns text into vectors, a classifier picks a label, and non-autoregressive generators try to produce output without that same one-token-at-a-time loop. Some encoder-decoder models still decode autoregressively, so this is about the generation pattern more than the model family name. vLLM can serve more than plain text generation, but prefill, decode, and KV cache behavior matter most in the autoregressive case.

### Stochastic generation

The model produces scores for possible next tokens, not a finished sentence. Those scores are turned into a probability distribution, and the decoding settings decide how to choose the next token.

- **What:** stochastic generation means randomness is part of token selection. Greedy decoding takes the highest-scoring token. Sampling can choose among likely tokens, so the same prompt can produce different valid continuations.
- **When:** the choice happens during decode, after the model has produced scores for the next token.
- **Where:** the serving engine applies the request's generation settings, such as temperature, top-p, top-k, maximum tokens, and sometimes a seed.
- **Why:** always taking the most likely token can be repetitive, brittle, or too narrow. Sampling gives the model room to vary phrasing, explore alternatives, and avoid getting stuck in the same continuation.
- **Impact on inference serving:** randomness makes retries, debugging, and load testing less predictable unless you log the prompt, model, generation settings, and seed if one is used. It can also change load indirectly: longer sampled answers consume more decode steps and more KV cache. Multi-output settings such as `n` and separate strategies such as beam search can multiply generated work even when the token choice itself is not random.
- **Impact on agents:** stochasticity can change plans, tool calls, and stopping points from the same starting prompt. That can help exploration, but it is risky around commands, payments, record updates, and other side effects. Agent systems usually constrain randomness around tool use with lower temperature, structured outputs, validation, careful retries, and persistent state. Once an agent picks a token, calls a tool, or observes a result, that chosen path becomes part of the next prompt.

For an autoregressive language model, inference has two phases worth knowing:

1. **Prefill** reads the prompt. The model processes the input tokens and builds the attention state it will need later.
2. **Decode** generates new tokens, usually one at a time, while reusing the state from previous tokens.

Those phases stress the server in different ways.

Prefill is about prompt size. A huge prompt can burn a lot of compute before the user sees the first token. That is why long documents can make TTFT worse even if the answer is short.

Decode is about active generation. Each step usually produces the next token for each running sequence, then does it again. This is where continuous batching matters: as some requests finish and new ones arrive, the engine tries to keep the GPU busy without forcing every request to start and stop at the same time.

Throughput and latency are connected, but they are not the same goal. Throughput asks, "how many tokens can this system produce per second?" Latency asks, "how long does this user wait?" Larger batches can improve total tokens per second while making an individual request wait longer for its turn. Smaller batches can reduce latency for one user while wasting GPU capacity under load.

That is why production tuning is not just "maximize tokens/sec." You usually pick a latency target, then increase batching and concurrency until TTFT, inter-token latency, and error rates stop being acceptable. The best setting is workload-specific: chat, summarization, code generation, and long-document analysis do not stress the server in the same way.

The model weights are big, but once they are loaded they mostly sit there. Request memory changes with traffic. A short prompt asking for 20 tokens and a large prompt asking for 2,000 tokens do not have the same cost. A serving engine has to handle that without letting one large request drag down the whole batch.

vLLM sits in that serving path. It exposes an HTTP server with OpenAI-compatible endpoints such as `/v1/completions`, `/v1/chat/completions`, and `/v1/responses`, and handles the engine work underneath: batching, scheduling, decoding, and KV cache management.

## KV cache basics

A tensor is a block of numbers with shape. A single number is a tiny tensor, a list of numbers is a vector, a grid of numbers is a matrix, and models usually deal with bigger stacks of these. GPUs are good at moving and multiplying tensors quickly, which is a large part of why they are useful for LLMs.

Transformer attention is the part of the model that lets each token look at other tokens for context. If the prompt is "the dog chased the ball because it was red," attention helps the model decide what "it" probably refers to. Under the hood, the model turns token representations into three sets of tensors: queries, keys, and values.

The rough idea:

- **Query:** what the current token is looking for.
- **Key:** what earlier tokens offer as lookup handles.
- **Value:** the actual information pulled from those earlier tokens.

The model compares queries to keys to decide which values matter. That is not the whole transformer, but it is enough to understand why the KV cache exists.

During generation, recomputing keys and values for the whole prompt every time would be expensive. The KV cache stores them so decode can reuse them.

The short version:

- **K** means key tensors.
- **V** means value tensors.
- The cache grows with sequence length.
- It exists per active request.
- It lives in GPU memory, which is usually the thing you run out of first.

The cache is helpful because it makes token generation much cheaper than starting from scratch every time. It is also a bottleneck because long prompts, long outputs, larger batches, and lots of concurrent users all compete for the same GPU memory.

Mental model: model weights are mostly fixed memory; KV cache is dynamic per-request memory.

A rough memory sketch looks like this:

<figure class="diagram" aria-labelledby="gpu-memory-diagram">
  <figcaption id="gpu-memory-diagram" class="diagram__caption">GPU memory during serving</figcaption>
  <div class="diagram__memory">
    <div class="diagram__pool">GPU memory</div>
    <div class="diagram__memory-items">
      <div class="diagram__node diagram__node--accent">
        Model weights
        <span class="diagram__note">Mostly fixed after load</span>
      </div>
      <div class="diagram__node">
        KV cache
        <span class="diagram__note">Grows with active tokens</span>
      </div>
      <div class="diagram__node">
        Runtime overhead
        <span class="diagram__note">Kernels, buffers, server state</span>
      </div>
      <div class="diagram__node">
        Safety margin
        <span class="diagram__note">Fragmentation and headroom</span>
      </div>
    </div>
  </div>
</figure>

Weights are the cover charge. KV cache is the tab that grows with traffic. More concurrent requests, longer prompts, longer outputs, and larger maximum context all increase the amount of active token state the server has to keep around.

If the server cannot pack KV cache efficiently, it has to run smaller batches. Smaller batches usually mean lower throughput and worse GPU utilization.

GPU memory pressure has symptoms:

- Requests sit in the queue longer.
- TTFT gets worse because requests wait for cache space.
- Concurrency stops improving even when more HTTP requests arrive.
- Long-context requests push out shorter work.
- Pods hit OOM, restart, or become unhealthy.
- Rollouts get unstable because warm pods need more memory than expected.
- Operators lower `--max-model-len`, batch size, or concurrency to keep the service alive.

If the dashboard says CPU is bored but users are waiting, look at GPU memory and the KV cache before blaming the web server.

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

That is the key idea behind vLLM: better KV cache packing allows larger effective batches, which usually means better throughput at similar latency for many workloads.

## What vLLM adds around it

PagedAttention is the memory idea. vLLM is the serving system wrapped around it.

Operators usually start with:

- **OpenAI-compatible serving:** point existing clients at a vLLM base URL.
- **Continuous batching:** serve active requests together as they arrive and finish at different times.
- **Streaming:** return tokens as they are generated.
- **Parallelism options:** spread larger models across GPUs when needed.
- **Cache controls:** tune context length, GPU memory usage, and KV cache behavior.
- **Observability hooks:** figure out whether the pain is tokens, memory, latency, or queueing.

A request is not handled as "one thread owns one request until it is done." The HTTP layer accepts the request asynchronously, then hands it to the vLLM engine. The engine tracks requests as sequences, keeps them in waiting and running sets, and the scheduler decides which sequences get work in the next step.

The GPU work is batched. During prefill, vLLM can process prompt tokens for one or more requests. During decode, it usually advances active requests token by token, batching multiple requests together when it can. So the unit of work is closer to "scheduled token and sequence work" than "thread per request." There are still CPU threads and processes around the server and workers, but the performance trick is scheduling and batching GPU work, not spinning up a dedicated thread for every user.

A local server can be as small as:

```sh
vllm serve openai/gpt-oss-20b \
  --host 0.0.0.0 \
  --port 8000 \
  --dtype auto
```

The example uses an OpenAI open-weight model. vLLM serves model weights you can run in your own environment, not hosted API-only models.

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

Use `/v1/chat/completions` when you want the familiar chat API shape. Use `/v1/responses` when you want the newer response format, especially for reasoning controls and tool-oriented flows:

```sh
curl http://localhost:8000/v1/responses \
  -H "Content-Type: application/json" \
  -d '{
    "model": "openai/gpt-oss-20b",
    "input": "Explain KV cache in one paragraph.",
    "reasoning": {
      "effort": "low"
    },
    "max_output_tokens": 120
  }'
```

If `gpt-oss-20b` does not fit locally, or it fits but feels too slow, use a smaller model for the laptop version of the experiment.

Simple starting points for local laptop runs:

| Laptop memory | Try first | Model memory | If it feels slow |
| --- | --- | --- | --- |
| 16 GB | [`llama3.2:3b`](https://ollama.com/library/llama3.2) | ~2 GB | `llama3.2:1b` (~1.3 GB) |
| 32 GB | [`gemma3:12b`](https://ollama.com/library/gemma3) or [`gpt-oss:20b`](https://ollama.com/library/gpt-oss) | ~8.1 GB / ~14 GB | `llama3.1:8b` (~4.9 GB) or `llama3.2:3b` (~2 GB) |
| 48 GB | [`gemma3:27b`](https://ollama.com/library/gemma3) or `gpt-oss:20b` | ~17 GB / ~14 GB | `gemma3:12b` (~8.1 GB) |

With Ollama:

```sh
ollama run gpt-oss:20b
ollama run gemma3:27b
ollama run gemma3:12b
ollama run llama3.2
ollama run llama3.2:1b
```

And Ollama can expose an OpenAI-compatible local endpoint:

```sh
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama3.2",
    "messages": [
      {"role": "user", "content": "Explain KV cache in one paragraph."}
    ],
    "max_tokens": 120
  }'
```

OpenAI-compatible does not mean OpenAI is serving the request. It means the HTTP path and JSON shape look like the OpenAI API, so tools that know how to call `/v1/chat/completions` can often point at `http://localhost:11434/v1` with a local model name instead. Llama itself is just the model family; Ollama is the runtime providing the OpenAI-compatible endpoint.

After the server starts, these flags are the ones that change capacity, memory use, and how the model is exposed:

- `--max-model-len` controls the maximum context length the server will accept.
- `--gpu-memory-utilization` controls how aggressively vLLM uses GPU memory.
- `--tensor-parallel-size` spreads a model across multiple GPUs.
- `--served-model-name` lets the API expose a stable model name even if the checkpoint path changes.

Context length is the total token budget for a request: prompt tokens plus generated output tokens. A 20,000-token document with a 500-token answer is a very different request from a 50-token chat message with a 500-token answer. The long prompt has to be tokenized, run through prefill, and have its attention state stored before decode can stream the answer.

Across multiple API calls, context is not one infinite memory pool. Each model turn still has to fit inside a context window. An agent keeps continuity by sending the relevant conversation history, tool results, files, plans, or summaries into the next request, whether that state is managed by the client or by an API layer. When that accumulated state gets too large, the agent has to compact it: summarize older details, drop irrelevant output, or move facts into some external store and retrieve only what matters. Compaction is not a serving trick; it is how the caller keeps the next prompt inside the model's context limit.

A larger `--max-model-len` tells the server to allow larger requests, but that capacity has to come from somewhere. Long prompts increase prefill work. Long prompts and long outputs both grow KV cache. Higher maximums increase the worst-case memory a request can consume, which can reduce practical concurrency or make admission/scheduling more constrained under load. Set the limit to the workload you actually need: support tickets, code snippets, and chat history do not need the same ceiling as full-document analysis.

The exact values depend on the model, GPU, traffic pattern, and latency target. Tune them from measurements.

## The takeaway

vLLM targets a specific serving problem: keeping high-throughput LLM inference from wasting GPU memory and starving the batch scheduler.

Start with KV cache. PagedAttention is the memory-management technique that makes the cache easier to pack. Context length, prompt size, output length, and concurrent users all feed back into the same capacity problem.

Start with one model, one clear workload, and one good dashboard. The Kubernetes deployment details are the next part of this series.

Further reading:

- [Efficient Memory Management for Large Language Model Serving with PagedAttention](https://arxiv.org/abs/2309.06180)
- [vLLM Online Serving](https://docs.vllm.ai/en/stable/serving/online_serving/)
