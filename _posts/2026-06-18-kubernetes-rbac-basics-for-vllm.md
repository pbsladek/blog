---
title: Kubernetes RBAC Basics for vLLM Operators
excerpt: "A practical Kubernetes RBAC primer for vLLM operators: authentication, authorization, service accounts, Roles, ClusterRoles, bindings, dangerous verbs, router discovery, and kubectl auth can-i."
tags:
  - ai
  - inference
  - kubernetes
  - security
  - vllm
series: vllm-inference
---

The cluster basics post covered the API server, kubeconfig, control-plane components, workers, networking, and storage. The running-vLLM post put model servers onto GPU workers. Before talking about vLLM-specific security, it is worth separating Kubernetes RBAC from model API authorization.

RBAC is how Kubernetes decides who can do what to Kubernetes API objects. It is not how you decide which end user may call a model.

<!--more-->

{% include series-nav.html %}

## The API request path

Most Kubernetes operations start with an API request:

`kubectl, CI, controller, or Pod -> API server -> authentication -> authorization -> admission -> stored state`

Authentication answers "who is calling?" The caller might be a human user from an OIDC login flow, a CI identity, a controller, or a Pod service account.

Authorization answers "is that caller allowed to do this verb against this resource?" Kubernetes supports several authorizer modes, including RBAC, Node, Webhook, ABAC, AlwaysAllow, and AlwaysDeny. In normal production clusters, RBAC is the main authorizer you use for human users, service accounts, CI, and controllers, while the Node authorizer handles kubelet-specific access. When RBAC is enabled, Kubernetes checks Role, ClusterRole, RoleBinding, and ClusterRoleBinding objects.

Admission runs after authorization. Admission controls can validate or mutate the request before it is persisted. For example, admission policy can reject privileged containers, require labels, require image digests, or enforce Pod Security Admission.

RBAC sits in the middle. It does not authenticate the caller by itself, and it does not inspect prompts going to a model API. It authorizes Kubernetes API actions.

<figure class="diagram" aria-labelledby="k8s-rbac-auth-flow-diagram">
  <figcaption id="k8s-rbac-auth-flow-diagram" class="diagram__caption">Kubernetes API auth flow</figcaption>
  <div class="diagram__auth-flow">
    <div class="diagram__auth-lane">
      <div class="diagram__node">
        Client request
        <span class="diagram__note">kubectl, CI, controller, or Pod</span>
      </div>
      <div class="diagram__connector" aria-hidden="true"></div>
      <div class="diagram__group">
        <div class="diagram__group-title">API server</div>
        <div class="diagram__auth-stack">
          <div class="diagram__node diagram__node--accent">
            Authentication
            <span class="diagram__note">client cert, bearer token, service account token, OIDC, or webhook</span>
          </div>
          <div class="diagram__node">
            Authorization
            <span class="diagram__note">RBAC checks subject, verb, resource, namespace, and API group</span>
          </div>
          <div class="diagram__node">
            Admission
            <span class="diagram__note">mutating and validating admission controls</span>
          </div>
        </div>
      </div>
      <div class="diagram__connector" aria-hidden="true"></div>
      <div class="diagram__node">
        Stored state
        <span class="diagram__note">object is persisted to etcd when the request is allowed</span>
      </div>
    </div>
    <div class="diagram__auth-side">
      <div class="diagram__node">
        RBAC policy objects
        <span class="diagram__note">Roles, ClusterRoles, RoleBindings, and ClusterRoleBindings</span>
      </div>
      <div class="diagram__node">
        Control-plane components
        <span class="diagram__note">scheduler and kube-controller-manager use the same API path; kubelets do too</span>
      </div>
    </div>
  </div>
</figure>

The API server is the enforcement point. `kubectl` talks to it, controllers talk to it, the scheduler talks to it, and kubelets talk to it. Those components may run inside the control plane, but they still use authenticated and authorized API requests when they read or update Kubernetes objects. Etcd stores the resulting state; normal clients do not talk to etcd directly.

### Admission controls

Admission is the last policy checkpoint before an allowed write changes cluster state. Authentication has already identified the caller. Authorization has already decided that the caller is allowed to attempt the operation. Admission then asks a different question: "is this object acceptable for this cluster right now?"

That distinction matters. RBAC might allow a CI service account to create Pods in `inference-models`, but admission can still reject a Pod that is privileged, missing required labels, using an unpinned image tag, mounting a forbidden host path, or violating Pod Security Admission.

Admission has two broad phases:

| Phase | What it can do | Example |
| --- | --- | --- |
| **Mutating admission** | Change the incoming object before it is stored | Add default labels, inject a sidecar, set default resource requests, or rewrite fields your platform owns |
| **Validating admission** | Accept or reject the final object | Require image digests, block privileged containers, enforce namespace policy, or require GPU workloads to use approved RuntimeClasses |

Mutating admission runs before validating admission because validation should evaluate the final object Kubernetes is about to store. If a mutating webhook injects a sidecar, default label, or security context, validating admission should see that result.

Admission is not a replacement for RBAC. RBAC says whether the caller may perform the API action at all. Admission says whether the requested object is allowed under cluster policy. In vLLM environments, useful admission policies often enforce things like pinned images, required labels for model ownership, approved GPU node selectors, disallowed host mounts, non-root containers, and Secret-handling rules.

Kyverno is one common way to manage those admission policies. It runs in the cluster as a dynamic admission controller: the API server sends matching AdmissionReview requests to Kyverno, Kyverno evaluates policy, and Kyverno returns an allow, deny, or patch response. The useful part is that policies are Kubernetes resources, so platform teams can manage them with the same GitOps and review process they use for Deployments, Services, and RBAC.

Kyverno can help with both validating and mutating policy. For validation, it can reject a vLLM Deployment that uses `latest`, omits resource requests, mounts a host path, runs privileged, or schedules onto GPU nodes without the expected labels and tolerations. For mutation, it can add standard labels, inject default resource requests, set a default `runtimeClassName`, or add platform-owned annotations used by observability and cost tooling.

For example, this Kyverno `MutatingPolicy` modifies matching vLLM Pods as they are created. It adds platform labels and annotations, then defaults the Pod to the NVIDIA runtime class. The match condition keeps the policy scoped to Pods labeled as vLLM workloads.

```yaml
apiVersion: policies.kyverno.io/v1
kind: MutatingPolicy
metadata:
  name: default-vllm-pod-platform-fields
spec:
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["pods"]
  matchConditions:
    - name: is-vllm-pod
      expression: >-
        has(object.metadata.labels) &&
        object.metadata.labels["app.kubernetes.io/name"] == "vllm"
  mutations:
    - patchType: ApplyConfiguration
      applyConfiguration:
        expression: >
          Object{
            metadata: Object.metadata{
              labels: {
                "platform.example.com/workload": "inference"
              },
              annotations: {
                "prometheus.io/scrape": "true",
                "prometheus.io/port": "8000"
              }
            },
            spec: Object.spec{
              runtimeClassName: "nvidia"
            }
          }
```

The policy object is YAML, but the value under `applyConfiguration.expression` is a CEL expression. That is why the patch body uses `Object{...}` syntax instead of normal YAML indentation. Kyverno evaluates that expression and turns the resulting object into the admission patch.

This kind of mutation is useful for platform-owned defaults, but it should not hide important application choices. I would use it for labels, annotations, runtime defaults, and safe security defaults. I would be more careful about mutating model names, commands, image references, or GPU counts because those are application behavior.

For image pinning, use a validating policy. The secure form is an image digest such as `vllm/vllm-openai@sha256:...`, not a mutable tag such as `latest` or `v0.10.1`. This example rejects vLLM Pods unless every normal container image and init container image contains `@sha256:`.

```yaml
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata:
  name: require-vllm-image-digests
spec:
  validationActions:
    - Deny
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
  matchConditions:
    - name: is-vllm-pod
      expression: >-
        has(object.metadata.labels) &&
        object.metadata.labels["app.kubernetes.io/name"] == "vllm"
  validations:
    - message: >-
        vLLM Pods must use immutable image digests, for example
        registry.example.com/vllm/vllm-openai@sha256:<digest>.
      expression: >-
        object.spec.containers.all(container, container.image.contains("@sha256:")) &&
        (
          !has(object.spec.initContainers) ||
          object.spec.initContainers.all(container, container.image.contains("@sha256:"))
        )
```

Kyverno also has `ImageValidatingPolicy`, which is useful when you want to go beyond "does the image reference contain a digest?" and verify image metadata, signatures, attestations, or registry-backed image validation. The simple `ValidatingPolicy` above is still a good first guardrail because it blocks mutable image references before they reach the cluster.

It can also do policy reporting and background scans. That matters when you introduce a policy to a cluster that already has workloads: you can often start by reporting violations, fix existing resources, and then move the policy to enforcement. That rollout pattern is safer than immediately blocking every create or update.

Kyverno still does not replace RBAC or model-layer authorization. RBAC decides who can attempt the Kubernetes API action. Kyverno decides whether the object they submit satisfies cluster policy. Your gateway, router, or application layer still decides who can call the model API.

Admission also has a narrower scope than many people first expect. Normal read requests such as `get`, `list`, and `watch` do not go through admission. Admission is mostly about create, update, patch, delete, and API requests that connect to a subresource, such as exec or proxy-style operations. That is why read access to Secrets must be controlled with RBAC; a validating admission policy cannot save you from a user who is already authorized to read Secret values.

### Dex and OIDC

Dex is an OpenID Connect identity provider and broker. It can sit between Kubernetes clients and upstream identity systems such as LDAP, SAML, GitHub, Google, Microsoft Entra ID, or another OIDC provider. Users do not authenticate to the Kubernetes API with their upstream password. They authenticate through Dex, the client receives an ID token, and the API server validates that token using its OIDC issuer configuration.

The important split is identity versus permission. Dex proves identity and group claims. It is not a Kubernetes authorizer. After the API server authenticates the token, the token claims become the Kubernetes username and groups that RBAC evaluates.

<figure class="diagram" aria-labelledby="dex-oidc-auth-flow-diagram">
  <figcaption id="dex-oidc-auth-flow-diagram" class="diagram__caption">Kubernetes auth flow with Dex and OIDC</figcaption>
  <div class="diagram__auth-flow">
    <div class="diagram__auth-lane">
      <div class="diagram__node">
        User and kubectl login
        <span class="diagram__note">browser flow or exec plugin starts OIDC login</span>
      </div>
      <div class="diagram__connector" aria-hidden="true"></div>
      <div class="diagram__group">
        <div class="diagram__group-title">Dex OIDC issuer</div>
        <div class="diagram__auth-stack">
          <div class="diagram__node diagram__node--accent">
            Connector login
            <span class="diagram__note">LDAP, SAML, GitHub, Google, OIDC, and similar systems</span>
          </div>
          <div class="diagram__node">
            ID token
            <span class="diagram__note">issuer, audience, subject, groups, expiry, and signature</span>
          </div>
        </div>
      </div>
      <div class="diagram__connector" aria-hidden="true"></div>
      <div class="diagram__node">
        kubectl request
        <span class="diagram__note">bearer token is sent to the API server</span>
      </div>
    </div>
    <div class="diagram__auth-lane">
      <div class="diagram__node">
        API server OIDC config
        <span class="diagram__note">issuer URL, client ID, username claim, and groups claim</span>
      </div>
      <div class="diagram__connector" aria-hidden="true"></div>
      <div class="diagram__group">
        <div class="diagram__group-title">Control plane decision</div>
        <div class="diagram__auth-stack">
          <div class="diagram__node diagram__node--accent">
            Authenticate token
            <span class="diagram__note">validate issuer, audience, expiry, and signature</span>
          </div>
          <div class="diagram__node">
            Map claims
            <span class="diagram__note">turn token claims into Kubernetes username and groups</span>
          </div>
          <div class="diagram__node">
            RBAC authorizer
            <span class="diagram__note">RoleBindings and ClusterRoleBindings decide access</span>
          </div>
          <div class="diagram__node">
            Admission and etcd
            <span class="diagram__note">admission runs, then allowed writes are persisted</span>
          </div>
        </div>
      </div>
      <div class="diagram__connector" aria-hidden="true"></div>
      <div class="diagram__node">
        Allowed or denied
        <span class="diagram__note">Kubernetes API response</span>
      </div>
    </div>
  </div>
</figure>

Dex is useful when the upstream identity system is not exactly the OIDC shape Kubernetes expects, or when you want one stable issuer in front of several upstream connectors. Operationally, the API server needs an issuer URL, client ID, CA trust when required, username claim, and groups claim. The group names emitted by Dex need to match the RBAC subjects you bind, such as `oidc:inference-operators`.

On the API server side, that usually looks like kube-apiserver OIDC configuration. The exact place you set these depends on how the cluster is built: static Pod manifest for many kubeadm-style clusters, managed-service configuration for managed control planes, or provider-specific flags.

```yaml
# kube-apiserver flags, shown as a static-Pod-style args snippet
# On a kubeadm-style Ubuntu control-plane node, this usually lives in:
# /etc/kubernetes/manifests/kube-apiserver.yaml
- --oidc-issuer-url=https://dex.example.com
- --oidc-client-id=kubernetes
- --oidc-username-claim=email
- --oidc-username-prefix=oidc:
- --oidc-groups-claim=groups
- --oidc-groups-prefix=oidc:
- --oidc-ca-file=/etc/kubernetes/pki/dex-ca.crt
```

With that configuration, a token claim like `email: paul@example.com` becomes the Kubernetes username `oidc:paul@example.com`. A token group like `inference-operators` becomes the Kubernetes group `oidc:inference-operators`, which can then appear in a RoleBinding or ClusterRoleBinding.

On the client side, kubeconfig still points at the Kubernetes API server. The OIDC part belongs under the user credentials. In many current setups, kubectl gets tokens through an exec plugin rather than storing refreshable OIDC credentials directly in the kubeconfig:

```yaml
apiVersion: v1
kind: Config
clusters:
  - name: production
    cluster:
      server: https://api-server.example.com:6443
      certificate-authority-data: LS0tLS1...
users:
  - name: paul@example.com
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1
        command: kubectl
        args:
          - oidc-login
          - get-token
          - --oidc-issuer-url=https://dex.example.com
          - --oidc-client-id=kubernetes
          - --oidc-extra-scope=groups
contexts:
  - name: production
    context:
      cluster: production
      user: paul@example.com
      namespace: inference-models
current-context: production
```

The `server` field is the Kubernetes API server endpoint: `https://api-server.example.com:6443`. It might sit behind a load balancer or managed-control-plane endpoint, but the client is talking to the API server, not to "the control plane" as a generic target. The exec plugin handles the login flow against Dex and returns a bearer token to kubectl. Kubectl sends that token to the API server, the API server validates it against the configured issuer, and RBAC evaluates the resulting username and groups.

Dex also makes self-service Kubernetes access easier to operate. Instead of asking platform engineers to hand-edit kubeconfigs for every user, you can publish a small internal page, CLI, or runbook that generates a kubeconfig from fixed cluster settings: API server endpoint, cluster CA, Dex issuer URL, client ID, scopes, default context, and default namespace. The user still has to complete the Dex login flow before they get a token.

That self-service flow should generate configuration, not permission. A generated kubeconfig can tell kubectl where the API server is and how to authenticate through Dex, but it should not grant Kubernetes access by itself. Access still comes from identity-provider groups and RBAC bindings. If Paul is not in the `inference-operators` group, generating the same kubeconfig as an operator should not make Paul an operator.

The usual pattern is:

1. Platform owns the Dex client, issuer URL, callback settings, cluster CA, and approved kubeconfig template.
2. Users download or generate a kubeconfig for the cluster and namespace they are allowed to use.
3. Kubectl opens the Dex login flow through the exec plugin.
4. Dex authenticates the user through the upstream identity provider and returns group claims.
5. The API server validates the token and RBAC decides what the user can do.

That gives developers a reasonable self-service path without spreading long-lived client certificates or hand-managed bearer tokens. It also keeps offboarding clean: remove the user from the identity-provider group, and the next token refresh no longer carries the group RBAC depends on.

Treat Dex like identity infrastructure. Give it a stable HTTPS issuer URL, monitor login failures and token validation failures, plan for certificate and signing-key rotation, and keep its Kubernetes permissions narrow. Dex should not get broad RBAC just because it participates in authentication; RBAC decisions still happen in the API server.

## Subjects, verbs, resources, and scope

RBAC rules are built from a few pieces:

| Concept | Meaning | Example |
| --- | --- | --- |
| **Subject** | Who receives permission | User, Group, or ServiceAccount |
| **Verb** | What action is allowed | `get`, `list`, `watch`, `create`, `update`, `patch`, `delete` |
| **Resource** | Which API object is affected | `pods`, `deployments`, `secrets`, `endpointslices` |
| **API group** | Which API group owns the resource | `""`, `apps`, `discovery.k8s.io`, `rbac.authorization.k8s.io` |
| **Scope** | Namespace-scoped or cluster-scoped | Role in `inference-models`, or ClusterRole across the cluster |

The empty API group `""` means the core API group. That is where resources such as Pods, Services, ConfigMaps, Secrets, Events, and ServiceAccounts live. Deployments and ReplicaSets are in `apps`. EndpointSlices are in `discovery.k8s.io`. Roles and RoleBindings are in `rbac.authorization.k8s.io`.

Subresources matter. `pods` and `pods/exec` are different permissions. A user who can `get` Pods can inspect Pod objects. A user who can create `pods/exec` requests can run commands in containers, which is a much larger privilege.

## Role, ClusterRole, RoleBinding, ClusterRoleBinding

A `Role` grants permissions inside one namespace. A `ClusterRole` can describe cluster-scoped permissions, or reusable permissions that can be bound into one namespace.

A `RoleBinding` attaches a Role or ClusterRole to subjects in one namespace. A `ClusterRoleBinding` attaches a ClusterRole to subjects cluster-wide.

That distinction is where many mistakes happen:

- Use a **RoleBinding to a Role** for normal namespace-local app permissions.
- Use a **RoleBinding to a ClusterRole** when you want a common permission set, such as a reusable viewer role, but only inside one namespace.
- Use a **ClusterRoleBinding** only when the subject really needs cluster-wide permission.

For model serving, most human and service-account access should be namespace-scoped. A router that discovers workers in `inference-models` does not need to read Pods in every namespace. A model operator who deploys one model namespace does not need cluster-admin.

## Users, groups, and service accounts

Humans usually authenticate to the Kubernetes API through an external identity system such as OIDC. Kubernetes maps claims into usernames and groups. RBAC then binds permissions to those users or groups.

Prefer group-based bindings:

```yaml
subjects:
  - kind: Group
    name: oidc:inference-operators
    apiGroup: rbac.authorization.k8s.io
```

Do not bind routine access to individual people if the identity provider already manages groups. Let the identity provider handle joiners, movers, and leavers.

Pods use service accounts. A service account is a Kubernetes identity for workloads inside the cluster. If a vLLM router calls the Kubernetes API to discover model workers, it should use its own service account. If a vLLM worker only serves HTTP traffic and reads one mounted model registry token, it usually does not need Kubernetes API discovery permissions at all.

Avoid the default service account for real workloads. Create named service accounts so permissions are intentional and auditable.

## A viewer role

A developer who only needs to inspect model-serving resources should not be able to mutate Deployments or read Secrets.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: inference-viewer
  namespace: inference-models
rules:
  - apiGroups: [""]
    resources: ["pods", "services", "endpoints", "events"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets"]
    verbs: ["get", "list", "watch"]
```

Bind it to an OIDC group:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: inference-viewers
  namespace: inference-models
subjects:
  - kind: Group
    name: oidc:inference-developers
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: inference-viewer
  apiGroup: rbac.authorization.k8s.io
```

That gives developers read-only visibility into the model-serving namespace. It does not let them update the model image, exec into Pods, or read Secret values.

## An operator role

An operator role can mutate Deployments and Services, but still avoid broad Secret reads:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: inference-operator
  namespace: inference-models
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "patch", "update"]
  - apiGroups: [""]
    resources: ["services", "configmaps"]
    verbs: ["get", "list", "watch", "create", "patch", "update"]
  - apiGroups: [""]
    resources: ["pods", "events"]
    verbs: ["get", "list", "watch"]
```

Whether this is enough depends on your release process. Some teams let operators update Deployments directly. Others require all changes to flow through GitOps or CI, so humans get read-only access and the CI service account gets the narrow write permission.

## Router discovery RBAC

If the router discovers workers through Kubernetes labels, it needs read access to the objects it watches. It does not need cluster-admin.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vllm-router
  namespace: inference-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: vllm-router-discovery
  namespace: inference-models
rules:
  - apiGroups: [""]
    resources: ["pods", "services", "endpoints"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["discovery.k8s.io"]
    resources: ["endpointslices"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: vllm-router-discovers-models
  namespace: inference-models
subjects:
  - kind: ServiceAccount
    name: vllm-router
    namespace: inference-system
roleRef:
  kind: Role
  name: vllm-router-discovery
  apiGroup: rbac.authorization.k8s.io
```

If the router only talks to a static Service name and does not query the Kubernetes API, it may not need this RBAC at all. Grant permissions because the process actually calls the Kubernetes API, not because the component feels like infrastructure.

## Dangerous permissions

RBAC is not only about broad roles. Some narrow-looking permissions are powerful:

- `get`, `list`, or `watch` on Secrets exposes Secret contents.
- `create` on Pods can become arbitrary workload execution.
- `update` or `patch` on Deployments can change images, commands, ports, mounted Secrets, and service accounts.
- `pods/exec` and `pods/attach` can become interactive access inside containers.
- `pods/portforward` can bypass gateway auth, rate limits, request logging, and model authorization.
- `create` on RoleBindings plus permission to `bind` privileged ClusterRoles can become privilege escalation.
- `impersonate` can become privilege escalation if it lets a caller act as a stronger user, group, or service account.
- Wildcards such as `resources: ["*"]` and `verbs: ["*"]` age badly because they grant future permissions too.

For vLLM, `pods/portforward` deserves special attention. If a developer can port-forward directly to a vLLM pod or router Service, they may bypass the clean API path you designed. That might be fine for a break-glass operator. It should not be casual developer access.

## Testing permissions

Use `kubectl auth can-i` before assuming an RBAC rule does what you intended:

```sh
kubectl auth can-i get pods -n inference-models
kubectl auth can-i update deployment/vllm-gpt-oss -n inference-models
kubectl auth can-i get secrets -n inference-models
kubectl auth can-i create pods/exec -n inference-models
kubectl auth can-i list endpointslices.discovery.k8s.io -n inference-models
```

You can also test as another identity when your own permissions allow impersonation:

```sh
kubectl auth can-i get pods \
  --as=user:paul@example.com \
  --as-group=oidc:inference-developers \
  -n inference-models
```

Use negative tests too. A good role should answer "no" to permissions it should not have. For a viewer, `get pods` should pass, while `update deployments`, `get secrets`, `create pods/exec`, and `create pods/portforward` should fail.

## Namespaces and boundaries

Use namespaces as administrative and policy boundaries. They are not hard security boundaries by themselves, but they give RBAC, NetworkPolicy, quotas, Pod Security Admission, and admission policies something concrete to attach to.

A simple layout:

| Namespace | Contents |
| --- | --- |
| `inference-system` | ingress gateway, model router, shared policy, dashboards |
| `inference-models` | vLLM workers for shared production models |
| `inference-dev` | dev/test model workers |
| `cert-manager` | cert-manager controllers |
| `istio-system` | mesh control plane and ingress gateway |

For stronger multi-tenancy, split tenants or environments into separate namespaces:

- `inference-team-a`
- `inference-team-b`
- `inference-sensitive`

Then bind human groups and service accounts to the smallest namespace that matches their job.

## What RBAC does not solve

RBAC controls the Kubernetes API. It does not control the model API.

RBAC can answer:

- Can this developer update the vLLM Deployment?
- Can this CI service account create a Service?
- Can this router service account list EndpointSlices?
- Can this user exec into a model Pod?

RBAC cannot answer:

- Can this application call `gpt-oss-20b`?
- Can this tenant call the expensive long-context model?
- Can this client stream 10,000 tokens?
- Can this user access `/v1/models` or `/metrics`?

Those are inference API authorization questions. Put them at the gateway, router, service mesh, or application layer. That is the topic of the next post.

## The takeaway

Kubernetes RBAC is a management-plane control. It decides who can manage Kubernetes objects.

For vLLM operators, the practical RBAC stance is simple: bind groups instead of individuals, use namespace-scoped roles by default, give every workload a named service account, avoid broad Secret access, treat `exec` and `portforward` as privileged, and test permissions with `kubectl auth can-i`.

Further reading:

- [Kubernetes RBAC authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [kubectl auth can-i](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_auth/kubectl_auth_can-i/)
- [Kubernetes authentication](https://kubernetes.io/docs/reference/access-authn-authz/authentication/)
- [Dex Kubernetes authentication guide](https://dexidp.io/docs/guides/kubernetes/)
- [Kubernetes service accounts](https://kubernetes.io/docs/concepts/security/service-accounts/)
