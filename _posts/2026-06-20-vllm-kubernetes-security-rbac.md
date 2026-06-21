---
title: Securing vLLM on Kubernetes
excerpt: "A practical security model for vLLM on Kubernetes: model access, gateway policy, router authorization, TLS, service mesh controls, NetworkPolicy, secrets, metrics, and admission guardrails."
tags:
  - ai
  - inference
  - kubernetes
  - security
  - vllm
series: vllm-inference
---

The RBAC post covered Kubernetes management access: users, groups, service accounts, Roles, ClusterRoles, bindings, verbs, and dangerous permissions. This post is about the model-serving security layer on top of that.

The core split is simple: Kubernetes RBAC controls who can manage the serving platform. It does not decide who can use a model.

<!--more-->

{% include series-nav.html %}

## Two planes

Security for vLLM on Kubernetes has two different control planes:

- **The Kubernetes API plane:** who can create, read, update, delete, exec into, or port-forward Kubernetes objects.
- **The inference API plane:** who can call `/v1/models`, `/v1/chat/completions`, `/v1/completions`, `/v1/responses`, metrics endpoints, and any admin endpoints exposed by the serving stack.

Kubernetes RBAC protects the first one. It does not automatically protect the second one.

That distinction matters. A developer might have no permission to edit a Deployment but still be able to call a public inference endpoint. A cluster admin might have full Kubernetes access but no business reason to call a restricted model. A router might need to discover pods and forward traffic, but it should not be able to list every Secret in the cluster.

Treat model serving like a small platform, not like one Deployment.

## Trust boundaries

A production vLLM setup usually has these pieces:

| Layer | Example | Security job |
| --- | --- | --- |
| **Identity provider** | Okta, Entra ID, Google, Keycloak | Authenticates humans and service clients |
| **Edge/API gateway** | Cloud LB, Envoy, NGINX, Istio ingress gateway | Terminates public TLS, validates user tokens, applies coarse policy, rate limits traffic |
| **Model-aware router** | vLLM Router or production stack router | Chooses a model worker, enforces model routing policy, hides worker topology |
| **Model workers** | vLLM pods | Serve the model and stream tokens |
| **Kubernetes API** | kube-apiserver | Controls cluster objects through authentication, authorization, admission, and audit |
| **Secrets and model storage** | Kubernetes Secrets, external secret store, PVCs, object storage | Holds tokens, cert keys, model registry credentials, and sometimes cached weights |
| **Mesh/network policy** | Istio, CNI NetworkPolicy | Controls service-to-service traffic inside the cluster |

The request path and the management path are different:

`user -> gateway -> router -> one vLLM worker`

`admin/developer/CI -> Kubernetes API -> Kubernetes objects`

Do not use one policy layer and assume it solved both paths.

## RBAC is not model authorization

Kubernetes RBAC can answer:

- Can this CI service account update the vLLM Deployment?
- Can this operator patch the router ConfigMap?
- Can this developer port-forward to the router Service?
- Can this observability service account read EndpointSlices?

It cannot answer:

- Can this application call `gpt-oss-20b`?
- Can this tenant call the larger GPU-backed model?
- Can this user stream 10,000 output tokens?
- Can this client use tool calling or structured output?
- Can this group see `/metrics` or `/v1/models`?

Those are inference API authorization questions. Put them at the gateway, router, mesh, or application layer.

The rule of thumb:

- Use **Kubernetes RBAC** for people and controllers managing cluster resources.
- Use **gateway/router/API policy** for clients using models.
- Use **NetworkPolicy and mesh authorization** for pod-to-pod reachability.
- Use **admission policy** for guardrails on what can be deployed.

## Model access belongs above Kubernetes RBAC

A model access policy usually needs to answer:

- Which users or service clients can call each served model?
- Which groups can use expensive long-context models?
- Which clients can request tool use, JSON schema output, or higher token limits?
- Which tenants can see `/v1/models`?
- Which teams can access model metrics?
- Which requests must be retained, redacted, or blocked?

That policy belongs in front of the router or inside the router:

`client identity -> gateway auth -> model authorization -> router -> worker`

Do not let clients pick arbitrary backend URLs. Clients should call a stable API hostname and model name. The router should translate model names into backends.

For example:

| Client model name | Router policy | Backend |
| --- | --- | --- |
| `general-chat` | most authenticated developers | vLLM workers serving `openai/gpt-oss-20b` |
| `code-large` | engineering group only | larger GPU pool |
| `finance-summary` | finance apps only | restricted namespace and logs policy |
| `eval-sandbox` | CI/eval service accounts | dev model pool |

The worker should not decide who is a finance user. The worker should receive traffic only after the gateway/router has already authenticated and authorized the request.

## OIDC and identity headers

OIDC often shows up in two places:

1. **Kubernetes API access:** admins and developers authenticate to the Kubernetes API with identity provider tokens. Kubernetes maps user and group claims into usernames and groups, then RBAC decides what they can do.
2. **Inference API access:** users and applications authenticate to the gateway or mesh with JWT/OIDC tokens. Gateway, mesh, or router policy decides which model endpoints they can call.

For inference API access, validate tokens at the edge:

- Require TLS.
- Validate issuer, audience, expiration, and signature.
- Map claims or groups into model entitlements.
- Do not trust identity headers from the public internet.
- Strip and re-set internal identity headers at the gateway.
- Pass only the identity context the router needs.

The internal header pattern is useful, but only if the gateway is the only thing allowed to set it. For example, the gateway validates a JWT, then forwards:

```http
x-authenticated-subject: user:paul@example.com
x-authenticated-groups: inference-developers,finance-users
x-request-id: 4d6c...
```

The router trusts those headers only from the gateway workload identity, not from arbitrary callers.

## TLS at the edge

Public inference endpoints should use TLS. That is true even when requests are "just prompts." Prompts can contain source code, customer data, support transcripts, credentials, or unreleased product plans.

With cert-manager, the usual Kubernetes shape is:

- an `Issuer` or `ClusterIssuer` defines how certs are issued
- a `Certificate` requests a cert for a DNS name
- cert-manager stores the signed certificate and private key in a Kubernetes Secret
- an Ingress or Gateway uses that Secret for TLS termination

Example certificate:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: inference-api
  namespace: inference-system
spec:
  secretName: inference-api-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - inference.example.com
```

That Secret is powerful. Anyone who can read it can copy the TLS private key. Treat TLS Secrets like production credentials.

For private internal APIs, use a private CA or service mesh mTLS. Do not use public certificates as a substitute for internal authorization.

## Istio and service mesh controls

Istio can help with two different problems:

- **Peer identity:** which workload is talking to which workload?
- **Request identity:** which end user or client token is attached to the request?

For service-to-service traffic, use mTLS. In Istio, a `PeerAuthentication` can require STRICT mTLS for a namespace:

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: inference-mtls
  namespace: inference-models
spec:
  mtls:
    mode: STRICT
```

Then use `AuthorizationPolicy` to say who can call the model workers. For example, only the router service account should reach vLLM pods:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-router-to-vllm
  namespace: inference-models
spec:
  selector:
    matchLabels:
      app: vllm
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - cluster.local/ns/inference-system/sa/vllm-router
      to:
        - operation:
            ports: ["8000"]
```

This is different from Kubernetes RBAC. RBAC controls calls to the Kubernetes API. Istio authorization controls traffic between workloads.

For end-user JWTs, use request authentication at the gateway or selected workloads. The gateway can validate OIDC tokens, then AuthorizationPolicy can match claims. Keep the policy simple enough that application teams can reason about it.

## NetworkPolicy: default-deny the model pods

NetworkPolicy is lower-level than Istio. It controls pod traffic at IP and port level, assuming your CNI enforces it.

A useful baseline is:

1. Default-deny ingress to model pods.
2. Allow ingress only from the router namespace/pods.
3. Default-deny egress from model pods.
4. Allow only DNS, model registry/object storage, metrics sinks, and required control-plane endpoints.

Example ingress policy:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: vllm-workers-only-from-router
  namespace: inference-models
spec:
  podSelector:
    matchLabels:
      app: vllm
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: inference-system
          podSelector:
            matchLabels:
              app: vllm-router
      ports:
        - protocol: TCP
          port: 8000
```

NetworkPolicy does not replace gateway auth. It reduces lateral movement if something else in the cluster is compromised.

## Secrets, weights, and certificates

vLLM deployments commonly need secrets for:

- Hugging Face or model registry tokens
- object storage credentials
- private model artifact repositories
- TLS private keys
- signing or encryption keys
- observability exporters

Kubernetes Secrets are API objects. Base64 is encoding, not encryption. Use RBAC to restrict Secret reads, enable encryption at rest, and prefer external secret managers when the organization already has one.

Practical rules:

- Give each model worker its own service account.
- Mount only the Secret needed for that model.
- Do not put all model registry tokens in one namespace-wide Secret.
- Avoid environment variables for highly sensitive values when mounted files are workable; environment variables are easy to leak through process dumps and debug output.
- Rotate registry tokens and TLS keys.
- Audit who can `get`, `list`, or `watch` Secrets.
- Treat model weights as sensitive when the license, training data, customer customization, or business context makes them sensitive.

Encryption at rest helps if etcd is copied or compromised, but it does not protect against someone who is authorized to read the Secret through the Kubernetes API. KMS-backed envelope encryption is stronger than keeping raw encryption keys on the control-plane host.

## Admin endpoints and metrics

Do not expose every endpoint the same way.

Separate:

- public or tenant inference API
- internal router health
- worker health
- `/metrics`
- profiling/debug endpoints
- admin or model-management endpoints

Metrics can leak model names, request rates, errors, token counts, latency distributions, and sometimes route names or tenant labels. That is operationally useful and also sensitive. Put metrics behind cluster-local access, Prometheus service account permissions, NetworkPolicy, and mesh authorization.

Health endpoints usually need to be reachable by kubelet, Service load balancing, ingress health checks, or mesh probes. Keep them narrow. A health endpoint should not expose request samples, model registry tokens, or loaded model internals.

## Admission controls and deployment policy

RBAC says who can submit a Deployment. Admission controls decide whether that Deployment is acceptable.

For vLLM workloads, admission policy can enforce:

- approved image registries
- pinned image tags and digests
- required resource requests and GPU limits
- required service account names
- no default service account
- no privileged containers
- no host networking unless explicitly approved
- allowed volume types
- required labels for owner, model, tenant, and data classification
- required NetworkPolicy in the namespace
- required sidecar injection or mesh labels where appropriate

This matters because anyone who can update a Deployment can change the runtime behavior of the model server. A small YAML change can swap images, mount different credentials, add a sidecar, or expose a new port.

## Reference policy shape

A reasonable production shape looks like this:

1. **Users authenticate through OIDC** at the gateway.
2. **Gateway terminates TLS** using cert-manager-managed certificates.
3. **Gateway validates JWTs** and removes untrusted identity headers.
4. **Gateway applies rate limits** and forwards only approved headers to the router.
5. **Router authorizes model access** based on identity, group, tenant, or client app.
6. **Router talks to workers over mTLS**.
7. **Workers accept traffic only from the router** through Istio AuthorizationPolicy and NetworkPolicy.
8. **Kubernetes RBAC limits management access** by namespace and role.
9. **Worker service accounts have narrow Secret access**.
10. **Secrets are encrypted at rest**, preferably with KMS.
11. **Metrics and admin endpoints stay internal**.
12. **Audit logs connect identity to model, route, namespace, and request ID**.

The important part is not the exact product stack. The important part is that each layer has one clear job.

## Failure modes to avoid

- **Using Kubernetes RBAC as API auth:** it does not protect `/v1/chat/completions`.
- **Letting users bypass the gateway:** port-forwarding or direct internal Service access can skip OIDC, rate limits, and model policy.
- **Giving the router cluster-admin:** discovery usually needs read-only access to a small set of resources.
- **Letting model pods read all Secrets:** a compromised worker should not become a cluster credential dump.
- **Trusting inbound identity headers:** only trust headers set by a gateway workload you authenticate.
- **Exposing `/metrics` publicly:** metrics often reveal operational and tenant information.
- **Skipping egress policy:** model pods with broad outbound internet access can leak data or fetch unexpected artifacts.
- **Treating cached weights as harmless:** model files and adapters can be proprietary assets.
- **Using permissive mTLS forever:** permissive mode is useful for migration; strict mode is the real security boundary.
- **Ignoring audit logs:** you need to answer who deployed a model, who changed routing policy, and who called a restricted model.

## Production checklist

Before calling the deployment secure, I would want at least this:

- OIDC-backed human access to the Kubernetes API.
- Group-based RoleBindings, not individual long-lived admin bindings.
- Separate service accounts for router, workers, CI, and observability.
- No routine use of the default service account.
- No broad Secret read permissions for developers, routers, or workers.
- Gateway TLS with cert-manager or equivalent certificate automation.
- JWT/OIDC validation at the gateway or mesh edge.
- Explicit model authorization before traffic reaches a worker.
- Router-to-worker mTLS where a mesh is used.
- NetworkPolicy limiting ingress to workers and egress from workers.
- Secret encryption at rest, preferably with KMS.
- External secret manager integration if that is the organization standard.
- Internal-only metrics and admin endpoints.
- Admission policy for images, service accounts, resource requests, GPU limits, and unsafe pod settings.
- Audit logs for Kubernetes API changes and inference API access.
- A break-glass path that is logged, time-bound, and reviewed.

## The takeaway

Securing vLLM on Kubernetes is not one RBAC file. It is a layered access model.

Kubernetes RBAC controls who can manage the serving platform. Gateway, router, mesh, and application policy control who can use the models. NetworkPolicy and mTLS reduce lateral movement. cert-manager and KMS reduce certificate and secret handling mistakes. OIDC gives you a real identity source for both humans and client applications.

The safest mental model is simple: users should reach models through the router, operators should manage resources through Kubernetes, and model workers should be boring private backends with as few permissions as possible.

Further reading:

- [Kubernetes RBAC authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [Kubernetes authentication and OIDC](https://kubernetes.io/docs/reference/access-authn-authz/authentication/)
- [Kubernetes NetworkPolicy](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [Kubernetes encryption at rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
- [cert-manager Certificate resources](https://cert-manager.io/docs/usage/certificate/)
- [Istio security concepts](https://istio.io/latest/docs/concepts/security/)
- [Istio AuthorizationPolicy](https://istio.io/latest/docs/reference/config/security/authorization-policy/)
- [vLLM production stack](https://docs.vllm.ai/en/stable/deployment/integrations/production-stack/)
