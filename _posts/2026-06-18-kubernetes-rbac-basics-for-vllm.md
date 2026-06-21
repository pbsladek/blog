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

Authorization answers "is that caller allowed to do this verb against this resource?" In clusters that use RBAC, Kubernetes checks Role, ClusterRole, RoleBinding, and ClusterRoleBinding objects.

Admission runs after authorization. Admission controls can validate or mutate the request before it is persisted. For example, admission policy can reject privileged containers, require labels, require image digests, or enforce Pod Security Admission.

RBAC sits in the middle. It does not authenticate the caller by itself, and it does not inspect prompts going to a model API. It authorizes Kubernetes API actions.

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
  --as=user:alice@example.com \
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
- [Kubernetes service accounts](https://kubernetes.io/docs/concepts/security/service-accounts/)
