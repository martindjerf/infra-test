# Infrastructure Setup Guide

A reference manual covering the full setup of this security-first Kubernetes infrastructure on Civo Cloud. Each section explains what was built, why it was done that way, and how it works under the hood.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Phase 1 — Infrastructure with Terraform](#phase-1--infrastructure-with-terraform)
3. [Phase 2 — Cluster Hardening](#phase-2--cluster-hardening)
4. [Phase 3 — Helm](#phase-3--helm)
5. [Phase 4 — ArgoCD and GitOps](#phase-4--argocd-and-gitops)
6. [Phase 5 — Sealed Secrets](#phase-5--sealed-secrets)
7. [Phase 6 — Kyverno Policy Enforcement](#phase-6--kyverno-policy-enforcement)
8. [Key Concepts Reference](#key-concepts-reference)

---

## Architecture Overview

```
Civo Cloud
└── Network + Firewall (Terraform)
    └── k3s Cluster (Terraform)
        ├── kube-system       — cluster internals, sealed-secrets controller
        ├── argocd            — GitOps controller
        ├── apps              — workloads (demo-app)
        ├── monitoring        — observability stack
        ├── falco             — runtime security
        └── kyverno           — policy enforcement
```

**Core philosophy:** defense in depth. No single control protects everything. Each layer assumes the one before it can fail:

- Terraform controls what infrastructure exists
- NetworkPolicies control what can talk to what
- Pod Security Standards control what containers can do
- Kyverno enforces what gets deployed
- Sealed Secrets ensures credentials never appear in plaintext in Git
- ArgoCD ensures the cluster always matches Git (no manual drift)

---

## Phase 1 — Infrastructure with Terraform

### What was built

A Civo network, firewall, and k3s cluster, split into reusable Terraform modules:

```
infra/
  environments/dev/    — environment-specific config and variables
modules/
  network/             — civo_network + civo_firewall
  cluster/             — civo_kubernetes_cluster
```

### Why modules

Splitting network and cluster into separate modules means they can be versioned, reused across environments (dev/staging/prod), and replaced independently. The `dev` environment just wires the two modules together via outputs.

### Firewall

```hcl
create_default_rules = false
```

Civo creates permissive default firewall rules unless you opt out. Setting this to `false` means we start with nothing and only open what we need:

- **Ingress 6443** — the Kubernetes API port. Required for `kubectl` to reach the cluster.
- **Egress 1-65535** — all outbound traffic allowed. Nodes need to pull images, reach DNS, etc.

The firewall operates at the cloud/VM level — it controls what traffic reaches the nodes at all. This is separate from Kubernetes NetworkPolicies, which control traffic between pods inside the cluster.

### `write_kubeconfig = false`

Prevents Terraform from writing the kubeconfig to state. Kubeconfig contains cluster credentials — storing it in Terraform state (which may be committed or stored remotely) is a security risk.

---

## Phase 2 — Cluster Hardening

### Namespaces

Three application namespaces were created manually:

```
k8s/namespaces/
  apps.yaml
  argocd.yaml
  monitoring.yaml
```

Namespaces provide the boundary for most Kubernetes security controls. NetworkPolicies, PSS labels, and RBAC all scope to a namespace.

### Pod Security Standards (PSS)

PSS is a built-in Kubernetes admission controller that enforces security profiles at the namespace level via labels.

The `apps` namespace enforces the `restricted` profile:

```yaml
pod-security.kubernetes.io/enforce: restricted
pod-security.kubernetes.io/enforce-version: latest
pod-security.kubernetes.io/audit: restricted
pod-security.kubernetes.io/warn: restricted
```

Three label modes:
- **enforce** — reject pods that violate the policy
- **audit** — log violations but allow the pod
- **warn** — return a warning to the client but allow the pod

The `restricted` profile requires every pod to set:

| Requirement | Why |
|---|---|
| `runAsNonRoot: true` | Prevents the container process from running as UID 0. Root in a container maps to root on the host if the container escapes. |
| `allowPrivilegeEscalation: false` | Prevents processes inside the container from gaining more privileges than they started with (e.g. via setuid binaries). |
| `capabilities.drop: [ALL]` | Strips all Linux capabilities. Without this, containers retain a default set of capabilities that can be abused even without being root. |
| `seccompProfile.type: RuntimeDefault` | Restricts which syscalls the container can make. The RuntimeDefault profile blocks dangerous syscalls like `ptrace` and `mount`. |
| `readOnlyRootFilesystem: true` | (restricted best practice) Prevents attackers from writing to the container filesystem — can't drop tools, write scripts, or modify configs. |

PSS runs at the API server level, before any admission webhook (including Kyverno). It is the first gate.

### NetworkPolicies

Kubernetes NetworkPolicy uses an **additive allow-list model**:

- By default, all pod-to-pod traffic is allowed
- Once any NetworkPolicy selects a pod, only traffic explicitly allowed by a policy is permitted
- Policies are additive — multiple policies apply to the same pod and the union of all rules is what's allowed

#### Default deny

A `default-deny-all` policy was applied to every namespace:

```yaml
spec:
  podSelector: {}    # selects all pods in this namespace
  policyTypes:
    - Ingress
    - Egress
  # no ingress or egress rules = deny everything
```

An empty `podSelector` selects all pods. Listing the policy types with no rules means every connection is blocked by default. Additional policies then open up only what is needed.

#### DNS egress

All namespaces need DNS to resolve service names. Without this, nothing works:

```yaml
egress:
  - to:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: kube-system
    ports:
      - protocol: UDP
        port: 53
      - protocol: TCP
        port: 53
```

DNS uses UDP port 53 primarily. TCP port 53 is used for large responses. Both are needed.

#### ArgoCD network policies

ArgoCD has several internal components (application-controller, repo-server, Redis, server) that all need to communicate. Three policies were applied to the `argocd` namespace:

**allow-intra-namespace** — allows all pods in `argocd` to talk to each other freely:

```yaml
ingress:
  - from:
    - podSelector: {}    # all pods in this namespace
egress:
  - to:
    - podSelector: {}    # all pods in this namespace
```

**allow-https-egress** — allows outbound HTTPS to the internet (needed to pull from GitHub):

```yaml
egress:
  - to:
      - ipBlock:
          cidr: 0.0.0.0/0
          except:
            - 10.0.0.0/8
            - 172.16.0.0/12
            - 192.168.0.0/16
    ports:
      - protocol: TCP
        port: 443
```

Excludes RFC1918 private ranges so this policy cannot be used to reach internal services on port 443.

**allow-k8s-api-egress** — allows ArgoCD to reach the Kubernetes API:

```yaml
egress:
  - ports:
      - protocol: TCP
        port: 6443
```

No `to:` block — allows port 6443 to any destination. This is intentional due to a Civo-specific behavior described below.

#### Civo DNAT issue

On Civo managed k3s, the Kubernetes control plane runs externally (not inside the cluster). The `kubernetes` ClusterIP service (`10.43.0.1:443`) is a virtual IP that gets DNAT'd by kube-proxy to the actual external control plane endpoint (e.g. `74.220.23.49:6443`).

The Civo CNI evaluates NetworkPolicies **after DNAT** has already rewritten the destination address. This means a policy that allows traffic to `10.43.0.1:443` never matches — by the time the CNI sees the packet, the destination is already `74.220.23.49:6443`. The packet hits `default-deny-all` and is dropped.

The fix is to allow port 6443 with no destination restriction. See [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) for the full debugging process.

### Service Accounts

The default service account in each namespace was patched to disable automatic token mounting:

```yaml
automountServiceAccountToken: false
```

By default, Kubernetes mounts a service account token into every pod. This token can be used to call the Kubernetes API. Most application pods have no reason to talk to the API, so mounting a token unnecessarily gives an attacker a credential they can use if they compromise the pod.

Disabling this on the default SA means a pod must explicitly request a service account with API access to get a token. Principle of least privilege.

---

## Phase 3 — Helm

### What Helm does

Helm is a package manager for Kubernetes. Instead of maintaining separate YAML files for each environment, you define a chart with templates and inject environment-specific values at install time.

### Chart structure

```
k8s/charts/demo-app/
  Chart.yaml           — chart metadata (name, version, appVersion)
  values.yaml          — default values
  templates/
    deployment.yaml    — Deployment template
    service.yaml       — Service template
```

### Templating

Templates use Go template syntax with `{{ }}` delimiters:

- `.Release.Name` — the name given at `helm install` time
- `.Release.Namespace` — the namespace the chart is installed into
- `.Values.*` — values from `values.yaml` (or overridden at install time)

This means the same chart can be deployed multiple times with different names, namespaces, and configurations.

### demo-app

The demo app uses `nginxinc/nginx-unprivileged` instead of the official `nginx` image. The official image runs as root, which violates `runAsNonRoot: true` from the PSS `restricted` profile. The unprivileged variant runs as a non-root user and listens on port 8080 instead of 80.

A writable `emptyDir` volume is mounted at `/tmp` to satisfy `readOnlyRootFilesystem: true` — nginx needs to write temporary files.

---

## Phase 4 — ArgoCD and GitOps

### What GitOps means

GitOps is the practice of using Git as the single source of truth for cluster state. Instead of running `kubectl apply` manually, a controller (ArgoCD) watches a Git repository and continuously reconciles the cluster to match it. If someone makes a manual change to the cluster, ArgoCD detects the drift and reverts it.

Benefits:
- All changes go through Git — full audit trail
- Rollback = `git revert`
- No one needs `kubectl` access to deploy
- Cluster state is always reviewable without connecting to the cluster

### ArgoCD Application

An `Application` resource tells ArgoCD what to sync and where to deploy it:

```yaml
spec:
  source:
    repoURL: https://github.com/martindjerf/infra-test
    targetRevision: main
    path: k8s/charts/demo-app         # what to sync from Git
  destination:
    server: https://kubernetes.default.svc
    namespace: apps                   # where to deploy it
  syncPolicy:
    automated:
      prune: true       # delete resources removed from Git
      selfHeal: true    # revert manual changes to the cluster
```

`prune: true` means if you remove a file from Git, ArgoCD deletes the corresponding resource from the cluster. Without it, resources would be orphaned.

`selfHeal: true` means if someone runs `kubectl edit` or `kubectl delete` on a managed resource, ArgoCD detects the drift and reverts it within a few seconds.

### App of Apps pattern

Rather than applying each ArgoCD `Application` manifest manually, the App of Apps pattern uses a single root Application that manages all other Applications:

```
root-app (applied once manually)
└── watches k8s/argocd/apps/
    ├── demo-app.yaml        → creates demo-app Application
    ├── sealed-secrets.yaml  → creates sealed-secrets-apps Application
    └── policies.yaml        → creates policies Application
```

After the one-time `kubectl apply -f k8s/argocd/root-app.yaml`, all future Application changes happen through Git. Add a file to `k8s/argocd/apps/`, push, and ArgoCD creates the Application automatically.

The destination namespace for the root app is `argocd` because `Application` resources themselves live in the `argocd` namespace.

---

## Phase 5 — Sealed Secrets

### The problem

Secrets cannot be committed to Git in plaintext. A `Secret` resource contains base64-encoded values — base64 is not encryption, it is trivially reversible. Committing secrets to Git exposes them to anyone with repo access, in perpetuity (git history).

### How Sealed Secrets works

Sealed Secrets uses asymmetric encryption (public/private key pair):

1. The sealed-secrets controller generates a key pair at startup and stores it in `kube-system`
2. You use `kubeseal` to encrypt a secret using the **public key** — produces a `SealedSecret` resource
3. The `SealedSecret` is safe to commit — the ciphertext is useless without the private key
4. The controller watches for `SealedSecret` resources and decrypts them using the **private key**, creating a regular `Secret` in the cluster

Only the controller can decrypt. Even the person who encrypted the secret cannot reverse it without cluster access.

### Encryption is namespace and name scoped

By default, a `SealedSecret` is bound to a specific namespace and name. The same ciphertext cannot be reused in a different namespace or with a different secret name. This prevents an attacker from copying a sealed secret into another namespace to decrypt it in a different context.

### Key backup

The private key lives in `kube-system`. If the cluster is deleted, the private key is gone and all `SealedSecrets` become permanently unreadable. In production, back up the key before destroying a cluster:

```bash
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-key-backup.yaml
```

Store this backup somewhere secure and offline — it is the master key for all your secrets.

---

## Phase 6 — Kyverno Policy Enforcement

### What Kyverno does

Kyverno is a Kubernetes-native policy engine that runs as an admission webhook. Every time a resource is created or updated, the API server calls Kyverno before persisting the resource. Kyverno can:

- **Validate** — reject resources that violate a rule
- **Mutate** — automatically patch resources to meet a standard
- **Generate** — automatically create related resources (e.g. NetworkPolicies when a namespace is created)

### How admission webhooks work

When you run `kubectl apply`, the request goes to the API server. The API server runs it through:

1. Authentication — who are you?
2. Authorization — are you allowed to do this?
3. Admission controllers — should this be allowed? (PSS runs here)
4. Validating webhooks — does this pass policy? (Kyverno runs here)
5. Mutating webhooks — should this be modified? (Kyverno can also run here)
6. Persist to etcd

Kyverno sits at step 4/5. It receives the full resource manifest and returns allow or deny.

### Policies

**disallow-latest-tag** — two rules working together:

```yaml
# rule 1: image must have a tag at all
- image: "?*:?*"    # at least one character, colon, at least one character

# rule 2: tag cannot be 'latest'
- image: "!*:latest"    # must NOT match anything ending in :latest
```

Both rules are needed because there are two ways to get the latest image:
- `nginx` — no tag, implicitly pulls latest
- `nginx:latest` — explicit latest tag

**require-resource-limits** — every container must declare CPU and memory limits:

```yaml
pattern:
  spec:
    containers:
      - resources:
          limits:
            cpu: "?*"
            memory: "?*"
```

Without limits, a single runaway pod can consume all node resources and starve other workloads. Limits bound the blast radius of a misbehaving container.

### Namespace exclusions

Both policies exclude `kube-system`, `kyverno`, and `argocd`. System components often cannot satisfy application-level policies — for example, Kyverno's own pods may use specific images that predate your tagging convention. Excluding system namespaces prevents policies from breaking the infrastructure that runs them.

### Layered enforcement

PSS and Kyverno both run at admission time but they are independent:

- PSS checks pod security settings (runAsNonRoot, capabilities, etc.)
- Kyverno checks whatever you define (image tags, resource limits, labels, etc.)

PSS fires first (it is a built-in controller). If PSS rejects a pod, Kyverno never sees it. If PSS passes, Kyverno runs next. Both must pass for the pod to be admitted.

---

## Key Concepts Reference

### Linux Capabilities

Linux capabilities are fine-grained units of root privilege. Instead of a binary root/non-root distinction, the kernel breaks privileged operations into ~40 individual capabilities. Examples:

| Capability | What it allows | Why it is dangerous |
|---|---|---|
| `CAP_NET_ADMIN` | Modify network interfaces, routing, firewall rules | Can bypass NetworkPolicies at the kernel level |
| `CAP_SYS_PTRACE` | Attach to and inspect other processes | Can read secrets from other process memory on the same node |
| `CAP_SYS_ADMIN` | ~30 privileged operations including mounting and namespace manipulation | Effectively equivalent to full root on the node |
| `CAP_NET_RAW` | Create raw network sockets, packet sniffing | Can sniff traffic from other pods on the node |

`capabilities.drop: [ALL]` removes every capability. A container then has no kernel-level privileges even if it somehow runs as root. Most web applications need zero capabilities to serve HTTP.

### NetworkPolicy model

Key rules to remember:

- **Default allow** — without any NetworkPolicy, all pod traffic is allowed
- **Default deny** — a NetworkPolicy with no rules but with `policyTypes` blocks everything for selected pods
- **Additive** — multiple policies apply to the same pod; the union of all rules is what is allowed
- **Unidirectional** — an egress policy on pod A allowing traffic to pod B does not automatically allow ingress to pod B; pod B needs its own ingress policy (or no NetworkPolicy selecting it)
- **podSelector: {}** — selects all pods in the namespace when used in `spec.podSelector`; selects all pods in the referenced namespace when used in `from/to`

### Pod Security Standards levels

| Level | What it enforces |
|---|---|
| `privileged` | No restrictions. For system components that need full access. |
| `baseline` | Blocks the most dangerous escalations (privileged containers, hostNetwork, hostPID). Minimal restrictions. |
| `restricted` | Full hardening. Requires non-root, dropped capabilities, seccomp, no privilege escalation. |

### Helm vs kubectl apply

| | kubectl apply | Helm |
|---|---|---|
| Templating | No | Yes |
| Release tracking | No | Yes (stored as Secrets in the namespace) |
| Rollback | Manual (keep old manifests) | `helm rollback` |
| Upgrade | Manual diff and apply | `helm upgrade` |
| Uninstall | Must track and delete each resource | `helm uninstall` removes everything |

Helm is appropriate when you need parameterisation or lifecycle management. For simple static resources (NetworkPolicies, namespaces, RBAC), plain YAML applied via ArgoCD is simpler.

### ArgoCD sync options

| Option | Effect |
|---|---|
| `automated.prune: true` | Delete cluster resources that were removed from Git |
| `automated.selfHeal: true` | Revert manual cluster changes back to the Git state |
| `CreateNamespace=false` | Do not create the destination namespace if it does not exist (fail instead) |

`CreateNamespace=false` is used here because namespaces are managed separately with their own PSS labels. Letting ArgoCD create them would skip the security labels.
