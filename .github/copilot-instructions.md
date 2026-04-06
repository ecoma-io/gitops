# GitHub Copilot Instructions — Ecoma GitOps Repo

This file defines the conventions, patterns, and rules for AI-assisted code generation in this repository. All AI-generated code must follow these rules consistently.

---

## Project Overview

This is a **GitOps monorepo** for the Ecoma platform. It is the **single source of truth** for all Kubernetes resources managed by **ArgoCD** on a single-node **K3s** cluster (24 vCPU / 48 GB RAM, Debian 12).

- ArgoCD version: `v3.3.6`
- Kustomize version: `v5.8.1` (inside ArgoCD repo-server)
- Pattern: **ArgoCD Autopilot-inspired** — ApplicationSets discover services by scanning `config.json` files
- Ingress: **Traefik** via **Cloudflare Tunnel** (no LoadBalancer IP needed)
- Secrets: **Sealed Secrets** (kubeseal) — never plain-text secrets in Git

---

## Directory Structure

```
declarative/
  platform/         → Core cluster infra (ArgoCD, Traefik, cert-manager, OpenEBS, etc.)
  observability/    → Monitoring stack (Prometheus, Loki, Mimir, Tempo, Alloy, Grafana)
  infras/           → Shared services (PostgreSQL, Redis, NATS, SeaweedFS, Kratos, Keto, Hydra)
  tools/            → Developer tools (Coder, Mailpit)
  applications/     → Ecoma application manifests (base + overlays per environment)
docs/               → Project documentation (architecture, runbooks, ADRs)
.github/workflows/  → CI pipeline (yamllint, kubeconform, helm lint, k3d gitops-test)
bootstrap.sh        → One-time bootstrap script (6 steps, never re-run)
sealed-secrets.cert → Public key for encrypting secrets (safe to commit)
```

---

## Namespaces

| Namespace                | Used By                                                                      |
|--------------------------|------------------------------------------------------------------------------|
| `argocd`                 | ArgoCD                                                                       |
| `cert-manager`           | cert-manager — TLS certificate management                                    |
| `ingress`                | Traefik, cloudflared                                                         |
| `infra`                  | PostgreSQL, Redis, NATS, SeaweedFS, Kratos, Keto, Hydra, token-hook         |
| `monitoring`             | kube-prometheus-stack, Loki, Mimir, Tempo, Alloy, Grafana                   |
| `kube-system`            | CoreDNS, Sealed Secrets, metrics-server, OpenEBS LVM-LocalPV CSI            |
| `cnpg-system`            | CloudNativePG operator                                                       |
| `coder`                  | Coder                                                                        |
| `mailpit`                | Mailpit                                                                      |
| `ecoma-staging`          | Staging environment applications                                             |
| `ecoma-prod`             | Production environment applications                                          |
| `ecoma-preview-{pr}`     | Preview environments (auto-created by CI per PR)                             |
| `ecoma-dev-{username}`   | Developer workspaces (created via Coder)                                     |

---

## Sync Waves

All infrastructure uses **negative waves** (-10 → -1). Applications use waves ≥ 0.

| Wave  | Components                                            | Group        |
|-------|-------------------------------------------------------|--------------|
| `-10` | `argocd`                                              | platform     |
| `-9`  | `openebs-lvm`                                         | platform     |
| `-8`  | `sealed-secrets`, `cert-manager`                      | platform     |
| `-7`  | `coredns`, `traefik`, `cloudflared`, `metrics-server` | platform     |
| `-6`  | `cloudnative-pg`                                      | platform     |
| `-5`  | `seaweedfs`, `kube-prometheus-stack`                  | infras / obs |
| `-4`  | `postgresql`, `redis`, `nats`                         | infras       |
| `-3`  | `loki`, `mimir`, `tempo`, `alloy`                     | observability|
| `-2`  | `kratos`, `keto`, `hydra`, `mailpit`                  | infras/tools |
| `-1`  | `coder`, `token-hook`                                 | tools/infras |
| `0+`  | Ecoma application services                            | applications |

---

## config.json — Required in Every Component Folder

Every folder under `declarative/<group>/<component>/` **must** have a `config.json`.

**For infrastructure, observability, platform, tools:**
```json
{
  "syncWave": "-N",
  "namespace": "<namespace>"
}
```

**For application overlays** (`declarative/applications/<app>/overlays/<env>/`):
```json
{ "name": "<app>-<env>", "namespace": "ecoma-<env>" }
```

Examples:
```json
{ "name": "account-staging", "namespace": "ecoma-staging" }
{ "name": "account-prod", "namespace": "ecoma-prod" }
{ "name": "account-preview-42", "namespace": "ecoma-preview-42" }
```

---

## Kustomization Pattern for Helm Charts

When deploying a Helm chart via kustomize, **always** use this pattern:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: <namespace>

helmCharts:
  - name: <chart-name>
    repo: <helm-repo-url>
    releaseName: <release-name>
    namespace: <namespace>
    version: <chart-version>
    valuesFile: <name>.values.yaml

# MANDATORY: kustomize v5.8.1 does NOT apply namespace transformer to helmCharts.
# Always add this explicit patch to inject namespace into all generated resources.
patches:
  - target:
      kind: ".*"
    patch: |-
      - op: add
        path: /metadata/namespace
        value: <namespace>

  # MANDATORY for StatefulSets: declare persistentVolumeClaimRetentionPolicy explicitly.
  # Without this, K8s injects {whenDeleted: Retain, whenScaled: Retain} at runtime,
  # causing ArgoCD ServerSideDiff to show a perpetual diff.
  - target:
      group: apps
      kind: StatefulSet
    patch: |-
      - op: add
        path: /spec/persistentVolumeClaimRetentionPolicy
        value:
          whenDeleted: Retain
          whenScaled: Retain
```

> The StatefulSet `persistentVolumeClaimRetentionPolicy` patch is only needed if the chart contains StatefulSets.

---

## Application Manifests Structure

```
declarative/applications/<app>/
  base/
    deployment.yaml
    service.yaml
    ingressroute.yaml    ← Traefik IngressRoute (traefik.io/v1alpha1)
    middleware.yaml      ← Optional: Traefik Middleware
    kustomization.yaml
  overlays/
    staging/
      kustomization.yaml
      config.json        ← { "name": "<app>-staging", "namespace": "ecoma-staging" }
    prod/
      kustomization.yaml
      config.json        ← { "name": "<app>-prod", "namespace": "ecoma-prod" }
    preview-{pr}/        ← Auto-created by GitHub Actions, DO NOT create manually
      kustomization.yaml
      config.json
```

### Base Deployment Template

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <app>
  labels:
    app: <app>
spec:
  replicas: 1
  selector:
    matchLabels:
      app: <app>
  template:
    metadata:
      labels:
        app: <app>
    spec:
      containers:
        - name: <app>
          image: <image>:<tag>
          ports:
            - containerPort: <port>
              name: http
          resources:         # MANDATORY — always set requests AND limits
            requests:
              cpu: <value>
              memory: <value>
            limits:
              memory: <value>   # CPU limit optional for stateless apps
          livenessProbe:
            httpGet:
              path: /health/alive
              port: http
            initialDelaySeconds: 10
            periodSeconds: 30
          readinessProbe:
            httpGet:
              path: /health/ready
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
```

### IngressRoute (Traefik) — Ecoma Applications

For services under `declarative/applications/`, always use `traefik.io/v1alpha1` IngressRoute CRD.

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: <app>
spec:
  entryPoints:
    - web
  routes:
    - kind: Rule
      match: Host(`<app>.ecoma.io`)
      services:
        - name: <app>
          port: 80
```

### Standard Ingress — Infrastructure Services

For services under `declarative/infras/` that need external access (e.g., Kratos, Hydra), use `networking.k8s.io/v1 Ingress` with `ingressClassName: traefik`. **Do NOT use IngressRoute CRD for infra services.**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: <service>
  annotations:
    # Optional: reference a Traefik Middleware for path stripping etc.
    traefik.ingress.kubernetes.io/router.middlewares: <namespace>-<middleware-name>@kubernetescrd
spec:
  ingressClassName: traefik
  rules:
    - host: api.ecoma.io
      http:
        paths:
          - path: /<prefix>
            pathType: Prefix
            backend:
              service:
                name: <service>-public
                port:
                  number: 80
```

### Overlay Kustomization Pattern

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ecoma-<env>
resources:
  - ../../base
patches:
  # Patch IngressRoute hostname
  - target:
      group: traefik.io
      version: v1alpha1
      kind: IngressRoute
      name: <app>
    patch: |-
      - op: replace
        path: /spec/routes/0/match
        value: "Host(`<env-subdomain>.ecoma.io`)"
  # Patch replica count for prod
  - target:
      kind: Deployment
      name: <app>
    patch: |-
      - op: replace
        path: /spec/replicas
        value: 2
```

---

## URL Routing Convention

| Environment | URL Pattern                              | Example                          |
|-------------|------------------------------------------|----------------------------------|
| prod        | `<app>.ecoma.io`                         | `account.ecoma.io`               |
| staging     | `staging-<app>.ecoma.io`                 | `staging-account.ecoma.io`       |
| preview     | `pr{N}-<app>.ecoma.io`                   | `pr42-account.ecoma.io`          |
| landing prod| `ecoma.io`                               | —                                |
| landing stg | `staging.ecoma.io`                       | —                                |
| landing prev| `pr{N}.ecoma.io`                         | `pr42.ecoma.io`                  |

> Cloudflare Universal SSL wildcard `*.ecoma.io` covers all single-level subdomains.
> **Only single-level subdomains** — no `a.b.ecoma.io` (not covered by wildcard).

---

## Resource Requests & Limits

**Mandatory** for all workloads in: `applications/`, `infras/`, `observability/`, `tools/`.
**Recommended** for: `platform/` (vendor defaults often sufficient).

| Service Type       | CPU Request | CPU Limit  | Mem Request | Mem Limit |
|--------------------|-------------|------------|-------------|-----------|
| Small stateless app| `50m`       | not req.   | `64Mi`      | `256Mi`   |
| Medium app         | `100m`      | `500m`     | `128Mi`     | `512Mi`   |
| PostgreSQL         | `500m`      | **none**   | `1Gi`       | `2Gi`     |
| Redis              | `100m`      | `200m`     | `256Mi`     | `512Mi`   |
| NATS JetStream     | `200m`      | `500m`     | `512Mi`     | `1Gi`     |
| SeaweedFS master   | `100m`      | `400m`     | `256Mi`     | `512Mi`   |
| SeaweedFS volume   | `200m`      | `800m`     | `512Mi`     | `1Gi`     |

**Rules:**
- **Stateless apps**: set CPU request + limit (3–4× request); memory both required.
- **Stateful databases (PostgreSQL, Redis)**: do NOT set CPU limit — throttle causes query latency. Stateful apps manage their own concurrency.
- Memory limit: always set. OOMKill is immediate and unrecoverable without restart.
- Memory limit = 1.5–2× memory request minimum.

---

## Secrets — Sealed Secrets (CRITICAL)

**NEVER commit plain-text secrets.** Use `kubeseal` with the public key `sealed-secrets.cert`.

```bash
# 1. Create a dry-run secret
kubectl create secret generic <name> \
  --from-literal=<key>=<value> \
  --namespace=<namespace> \
  --dry-run=client -o yaml > secret.yaml

# 2. Encrypt with the public key
kubeseal --cert sealed-secrets.cert --format yaml < secret.yaml > sealed-secret.yaml

# 3. Commit sealed-secret.yaml — delete secret.yaml (DO NOT commit)
```

Naming convention:
- `declarative/<group>/<service>/sealed-secret.yaml` — general infra/app secrets
- `declarative/infras/hydra/hydra-sealed-secret.yaml` — service-specific named secrets

> ⚠️ **Hydra**: SECRETS_SYSTEM and SECRETS_COOKIE **must** be managed as SealedSecrets (`hydra-sealed-secret.yaml`), NOT via Helm-generated random values. Set `secret.enabled: false` in `hydra.values.yaml`. Random values on each render cause Hydra to lose its JWK signing keys.

---

## Storage Classes

| StorageClass | LVM VG    | Use For                                                 |
|--------------|-----------|--------------------------------------------------------|
| `nvme`       | `vg-nvme` | Default. PostgreSQL, Redis, NATS, SeaweedFS hot tier.  |
| `hdd`        | `vg-hdd`  | SeaweedFS cold tier, backups.                          |

Use `reclaimPolicy: Retain` for stateful data PVCs.

---

## PostgreSQL — CloudNativePG Cluster

PostgreSQL is **NOT deployed via Helm**. It uses the CloudNativePG operator with a `postgresql.cnpg.io/v1 Cluster` CR.

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgresql
  namespace: infra
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:16.6
  storage:
    storageClass: nvme
    size: 20Gi
  enableSuperuserAccess: true
```

- CloudNativePG operator runs in `cnpg-system` (sync wave `-6`); Cluster CR is in `declarative/infras/postgresql/cluster.yaml`
- Auto-creates Secret `postgresql-superuser` with keys `username` and `password`
- Read-write endpoint: `postgresql-rw.infra.svc.cluster.local:5432`
- Alias Service `postgresql.infra.svc.cluster.local:5432` also exists (for simpler DNS)
- **First deploy only:** extract superuser password and re-seal all DSN SealedSecrets with real credentials

**Database Init Pattern (Kratos, Hydra, any service using PostgreSQL):**

Each service creates its own database via `extraInitContainers` before automigration runs:

```yaml
extraInitContainers:
  - name: db-init
    image: postgres:16-alpine
    env:
      - name: DSN
        valueFrom:
          secretKeyRef:
            name: <service>-db-url
            key: dsn
    command:
      - sh
      - -c
      - |
        ADMIN_DSN=$(echo "$DSN" | sed 's|/<dbname>?|/postgres?|')
        psql "$ADMIN_DSN" -c "SELECT 1 FROM pg_database WHERE datname='<dbname>'" | grep -q 1 || \
          psql "$ADMIN_DSN" -c "CREATE DATABASE <dbname>"
```

- DSN secret naming: `<service>-db-url` with key `dsn` (encoded as a SealedSecret)
- Automigration type: **always `initContainer`**, never `job` — Helm hook Jobs are silently stripped by ArgoCD kustomize app sources

---

## Observability — S3 Buckets via PreSync Jobs

Each observability service creates its own S3 buckets in SeaweedFS through a dedicated **ArgoCD PreSync Job** (`bucket-init-job.yaml`). Do NOT use init containers or a centralized job.

- S3 endpoint (internal): `http://seaweedfs-s3.infra.svc:8333`
- Region: `us-east-1` (SeaweedFS default)
- Credentials: `AWS_ACCESS_KEY_ID=ecoma`, `AWS_SECRET_ACCESS_KEY=ecoma` (fixed values for local SeaweedFS auth)
- Job image: `amazon/aws-cli:2.34.28`

| Service | Buckets                                               |
|---------|-------------------------------------------------------|
| Mimir   | `mimir-blocks`, `mimir-ruler`, `mimir-alertmanager`   |
| Loki    | `loki-chunks`, `loki-ruler`, `loki-admin`             |
| Tempo   | `tempo-traces`                                        |

---

## ArgoCD ApplicationSet Discovery Pattern

ApplicationSets scan `config.json` files via git generator. Adding a new service = adding the right folder with a `config.json`.

| Group              | AppSet file                          | Scans                                         |
|--------------------|--------------------------------------|-----------------------------------------------|
| `platform`         | `appsets/platform.yaml`              | `declarative/platform/*/config.json`          |
| `observability`    | `appsets/observability.yaml`         | `declarative/observability/*/config.json`     |
| `infras`           | `appsets/infras.yaml`                | `declarative/infras/*/config.json`            |
| `tools`            | `appsets/tools.yaml`                 | `declarative/tools/*/config.json`             |
| `applications`     | `appsets/applications.yaml`          | `declarative/applications/*/overlays/*/config.json` |

All AppSets use `goTemplate: true` and `goTemplateOptions: ["missingkey=error"]`.

---

## ArgoCD Projects

| Project           | Allowed Namespaces        | Used By                    |
|-------------------|---------------------------|----------------------------|
| `platform`        | `*`                       | platform AppSet            |
| `observability`   | `*`                       | observability AppSet       |
| `infras`          | `*`                       | infras AppSet              |
| `tools`           | `*`                       | tools AppSet               |
| `ecoma-production`| `ecoma-prod`              | applications AppSet (prod) |
| `ecoma-staging`   | `ecoma-staging`           | applications AppSet (stg)  |
| `ecoma-preview`   | `ecoma-preview-*`         | applications AppSet (prev) |
| `ecoma-dev`       | `ecoma-dev-*`             | applications AppSet (dev)  |

---

## Sync Policy

```yaml
syncPolicy:
  automated:
    selfHeal: true
    prune: true       # true for infras/platform; false for infras (see note)
  syncOptions:
    - CreateNamespace=true
    - ServerSideApply=true
    - ServerSideDiff=true
    - PruneLast=true
```

| Environment | Auto Sync | Self Heal | Prune |
|-------------|-----------|-----------|-------|
| preview     | ✅         | ✅        | ✅    |
| staging     | ❌ manual  | N/A       | ❌    |
| prod        | ❌ manual  | N/A       | ❌    |

> All infras/platform/observability/tools AppSets: `prune: true`.
> Removed resources from stale apps can keep Applications OutOfSync with requiresPruning=true.

---

## ArgoCD ignoreDifferences — Known Runtime Fields

These are applied globally in `argocd-cm` to suppress perpetual diffs:

**StatefulSet volumeClaimTemplates (ALL StatefulSets):**
```yaml
jqPathExpressions:
  - .spec.volumeClaimTemplates[].apiVersion
  - .spec.volumeClaimTemplates[].kind
  - .spec.volumeClaimTemplates[].status
  - .spec.volumeClaimTemplates[].spec.volumeMode
```

> Already configured globally — no need to add per-AppSet unless dealing with other controllers.

---

## ArgoCD Hooks Reference

Three hook patterns are used in this repo. Choose by use-case:

| Use-case | `hook` | `hook-delete-policy` | Example |
|----------|--------|---------------------|---------|
| S3 bucket creation, webhook setup | `PreSync` | `BeforeHookCreation` | `bucket-init-job.yaml` (Mimir, Loki, Tempo) |
| One-time seed (runs once, then deleted) | `PostSync` | `HookSucceeded` | `seed-job.yaml` (Kratos identity + Keto rules) |
| Idempotent registration (re-runs on each sync) | `PostSync` | `BeforeHookCreation` | `register-grafana-job.yaml` (Hydra OAuth2 client) |

**Typical hook Job spec:**

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: <name>
  annotations:
    argocd.argoproj.io/hook: PreSync           # or PostSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation  # or HookSucceeded
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: <name>
          image: curlimages/curl:8.11.1        # or amazon/aws-cli:2.34.28
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
```

> For PostSync jobs that make API calls: POST to create; on HTTP 409 Conflict, PUT to update (idempotent pattern).

---

## Auth Stack Architecture

Identity and authorization use three Ory components:

| Component | Purpose | Internal URL |
|-----------|---------|--------------|
| **Kratos** | Identity management (login, registration, identity CRUD) | public: `kratos-public.infra.svc.cluster.local:80`, admin: `kratos-admin.infra.svc.cluster.local:80` |
| **Hydra** | OAuth2/OIDC provider (authorization server, token issuance) | public: `hydra-public.infra.svc.cluster.local:4444`, admin: `hydra-admin.infra.svc.cluster.local:4445` |
| **Keto** | Permission/RBAC engine (relation tuples) | read: `keto-read.infra.svc.cluster.local:80`, write: `keto-write.infra.svc.cluster.local:80` |
| **token-hook** | Hydra token hook — injects Keto-based claims into JWTs | `token-hook.infra.svc.cluster.local:80/hook` |

**Auth flow:**
1. User authenticates via Kratos (returns session cookie/token)
2. Hydra OAuth2 authorization code flow uses Kratos as identity provider
3. At token issuance, Hydra calls the token-hook, which queries Keto for permissions
4. Resulting JWT contains injected claims (`grafana_role`, `platform#superadmin`) derived from Keto relation tuples
5. Services validate the JWT locally (`strategies.access_token: jwt` — signed JWTs, no introspection needed)

**Hydra Secrets (CRITICAL):** `secret.enabled: false` in `hydra.values.yaml`. SECRETS_SYSTEM lives in `hydra-sealed-secret.yaml` with a fixed stable value. Never allow Helm to generate it randomly.

**OAuth2 client registration** for internal tools is done via a PostSync Job (`register-grafana-job.yaml`). Pattern:
- POST to `http://hydra-admin.infra.svc.cluster.local:4445/admin/clients` to create
- On HTTP 409: PUT to `http://hydra-admin.infra.svc.cluster.local:4445/admin/clients/<client_id>` to update
- Set `skip_consent: true` for internal tools (Grafana, Coder, etc.)

---

## Observability Data Flow

**Collector:** Grafana Alloy runs as a DaemonSet in `monitoring`. It replaces Promtail, OTel Collector, and Faro Collector.

**Apps send telemetry to Alloy:**
- OTLP gRPC: `alloy.monitoring.svc.cluster.local:4317`
- OTLP HTTP: `alloy.monitoring.svc.cluster.local:4318`
- Browser RUM (Faro): `alloy.monitoring.svc.cluster.local:12347`

**Alloy routes to backends:**

| Signal | Backend | Header Required |
|--------|---------|-----------------|
| Logs | `loki-gateway.monitoring.svc:80` | `X-Scope-OrgID: ecoma` |
| Traces | `tempo.monitoring.svc:4318` | `X-Scope-OrgID: ecoma` |
| Metrics | Prometheus → `mimir-gateway.monitoring.svc:80` | `X-Scope-OrgID: ecoma` |

> **MANDATORY**: All writes to Loki, Tempo, and Mimir must include `X-Scope-OrgID: ecoma`. Requests without this header are rejected (multi-tenancy enforced).

**Grafana datasources** (pre-configured): Mimir (default metrics), Loki, Tempo with trace↔log cross-links.

**Grafana OAuth:** Uses Hydra as OIDC provider. `auth_url` is the external public URL; `token_url` and `api_url` use internal cluster DNS. Role mapping uses `grafana_role` claim injected by token-hook.

---

## Branching Strategy & Commit Convention

**Branching:** Trunk-Based Development. `main` is the only long-lived branch.

**Branch naming:**
```
<type>/<short-description>

feat/add-tempo-service
fix/redis-storage-class
chore/update-argocd-version
docs/update-sync-waves
ci/add-helm-lint
```

**Conventional Commits:**
```
<type>(<scope>): <description>

feat(nats): add jetstream persistent storage
fix(hydra): use sealed secret for SECRETS_SYSTEM
chore(argocd): update to v3.3.6
docs(runbook): add database rollback steps
```

**Types:** `feat`, `fix`, `chore`, `docs`, `ci`, `refactor`

**Scope:** component or service name — `postgresql`, `traefik`, `argocd`, `kratos`, `loki`

---

## PR Rules

- Title: Conventional Commits format
- **Squash merge** into `main`
- CI must pass (yamllint, kubeconform, helm lint, gitops-test)
- At least 1 approval required

---

## YAML Conventions (yamllint)

- Indentation: **2 spaces** (always)
- Line length: max 150 chars (warning only, not error)
- Document start marker `---`: **not required**
- `truthy` allowed values: `true`, `false`
- No trailing whitespace
- Always end files with a newline

---

## EditorConfig

```ini
charset = utf-8
indent_style = space
indent_size = 2
insert_final_newline = true
trim_trailing_whitespace = true
```

---

## Known Gotchas — DO NOT Violate

1. **Kustomize v5.8.1 namespace transformer** does NOT apply to `helmCharts:` resources. Always add an explicit `patches:` block with `target: { kind: '.*' }` to inject namespace.

2. **StatefulSet `persistentVolumeClaimRetentionPolicy`**: Must be explicitly declared as `{whenDeleted: Retain, whenScaled: Retain}`. Without it, K8s injects these values at runtime, causing perpetual ArgoCD ServerSideDiff.

3. **Hydra SECRETS_SYSTEM**: Must be a fixed SealedSecret. If `secret.enabled: true` in Hydra chart, each Helm render generates new random SECRETS_SYSTEM, breaking JWK key decryption for existing tokens.

4. **Helm `helm.sh/hook` resources in kustomize**: ArgoCD silently strips resources with `helm.sh/hook` annotations from kustomize-type apps. Convert to `argocd.argoproj.io/hook: PreSync` + `argocd.argoproj.io/hook-delete-policy: BeforeHookCreation`. JSON Patch annotation keys use `~1` to escape `/` (e.g., `helm.sh~1hook`). All 4 hook resource types (ServiceAccount, ClusterRole, ClusterRoleBinding, Job) must be converted.

5. **ArgoCD CRDs**: Use `Replace=true` sync option (annotation `argocd.argoproj.io/sync-options`) because CRDs exceed the 262144-byte annotation limit for server-side apply patch.

6. **Ingress health in ArgoCD**: Custom health check configured to return `Healthy` without LoadBalancer IP (Cloudflare Tunnel means no LB IP is ever assigned).

7. **ArgoCD admin API token**: Requires `accounts.admin: apiKey, login` in `argocd-cm`. Already configured.

8. **NATS subject isolation per dev environment**: Services must read `NATS_SUBJECT_PREFIX` env var and prepend it when publishing/subscribing. Format: `dev.{username}.subject`.

9. **kube-prometheus-stack on k3s**: Disable the following exporters that do not exist on k3s — set `enabled: false` for `kubeControllerManager`, `kubeScheduler`, `kubeEtcd`, `kubeProxy`. Enabling these creates ServiceMonitors targeting non-existent endpoints, causing perpetual scrape failures.

10. **Mimir rollout-operator webhook TLS**: The Mimir chart generates `ValidatingWebhookConfiguration` resources whose `clientConfig.service.name` does not match the deployed Service. Fix: add a `rollout-operator-svc.yaml` alias Service named `rollout-operator` and patch all 4 webhook `clientConfig.service.name` values in `kustomization.yaml`.

11. **Grafana `deploymentStrategy: Recreate`**: Grafana uses a `ReadWriteOnce` PVC. Set `deploymentStrategy.type: Recreate` — `RollingUpdate` will hang because two pods cannot mount the same RWO volume simultaneously.

12. **Kratos/Hydra `automigration.type: initContainer`**: Always use `initContainer`, never `job`. Helm hook Jobs are silently stripped by ArgoCD kustomize app sources. With `initContainer`, migration runs inside the main pod before the app container starts.

---

## Adding a New Infrastructure Service

1. Choose group: `platform/`, `observability/`, `infras/`, or `tools/`
2. Create `declarative/<group>/<service>/`:
   - `config.json` — with correct `syncWave` and `namespace`
   - `kustomization.yaml` — with Helm chart or raw resources
   - `<service>.values.yaml` — if using Helm
   - `sealed-secret.yaml` — if service needs secrets (use kubeseal)
3. Assign a sync wave consistent with dependencies (see Sync Waves table above)
4. Commit + push → ApplicationSet auto-discovers and deploys

---

## Adding a New Ecoma Application

1. Create `declarative/applications/<app>/base/`:
   - `deployment.yaml` — with resources requests/limits, liveness/readiness probes
   - `service.yaml`
   - `ingressroute.yaml` — Traefik IngressRoute
   - `middleware.yaml` — if needed
   - `kustomization.yaml` — listing all resources
2. Create `declarative/applications/<app>/overlays/staging/` and `prod/`:
   - `kustomization.yaml` — with namespace, IngressRoute hostname patch
   - `config.json` — `{ "name": "<app>-staging", "namespace": "ecoma-staging" }`
3. Commit + push → applications-appset auto-discovers

---

## HA Readiness Guidelines

> The cluster is currently **single-node** by design (see [ADR-0001](../docs/architecture/decisions/0001-single-node-with-ha-migration-path.md)). All configs must be written with HA migration in mind.

**When generating StatefulSet-based infra configs:**
- Always keep `replicas: 1` as current value for stateful services (single-node constraint)
- For PostgreSQL: use CloudNativePG `instances: 1` — upgrading to `instances: 3` requires only changing this field
- For NATS: `replicas: 1` now; add cluster config block commented out for future use
- Document that `storageClass: nvme` and `storageClass: hdd` are **node-local** and not portable to other nodes

**When generating Deployment configs for stateless apps:**
- Base overlay: `replicas: 1`
- Prod overlay: `replicas: 2` with `podAntiAffinity` to spread pods across nodes

**Standard `podAntiAffinity` pattern for stateless apps (add to prod overlay):**
```yaml
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchExpressions:
              - key: app
                operator: In
                values:
                  - <app>
          topologyKey: kubernetes.io/hostname
```

**Storage classes — node-local constraint:**
- `nvme` → `vg-nvme` LVM on local NVMe disk — cannot migrate between nodes automatically
- `hdd` → `vg-hdd` LVM on local HDD — same constraint
- When multi-node arrives, these will be replaced by Longhorn or Rook-Ceph StorageClasses — do NOT hardcode the class name in ways that make migration difficult

---

## Internal Service DNS

| Service              | Internal DNS                                         | Port  |
|----------------------|------------------------------------------------------|-------|
| PostgreSQL (RW)      | `postgresql-rw.infra.svc.cluster.local`              | 5432  |
| PostgreSQL (alias)   | `postgresql.infra.svc.cluster.local`                 | 5432  |
| Redis                | `redis-master.infra.svc.cluster.local`               | 6379  |
| NATS                 | `nats.infra.svc.cluster.local`                       | 4222  |
| SeaweedFS S3         | `seaweedfs-s3.infra.svc:8333`                        | 8333  |
| Kratos public API    | `kratos-public.infra.svc.cluster.local`              | 80    |
| Kratos admin API     | `kratos-admin.infra.svc.cluster.local`               | 80    |
| Hydra public API     | `hydra-public.infra.svc.cluster.local`               | 4444  |
| Hydra admin API      | `hydra-admin.infra.svc.cluster.local`                | 4445  |
| Keto read API        | `keto-read.infra.svc.cluster.local`                  | 80    |
| Keto write API       | `keto-write.infra.svc.cluster.local`                 | 80    |
| Token hook           | `token-hook.infra.svc.cluster.local`                 | 80    |
| Mailpit SMTP         | `mailpit-smtp.infra.svc.cluster.local`               | 25    |
| Alloy OTLP gRPC      | `alloy.monitoring.svc.cluster.local`                 | 4317  |
| Alloy OTLP HTTP      | `alloy.monitoring.svc.cluster.local`                 | 4318  |
| Alloy Faro (RUM)     | `alloy.monitoring.svc.cluster.local`                 | 12347 |
| Loki gateway         | `loki-gateway.monitoring.svc`                        | 80    |
| Mimir gateway        | `mimir-gateway.monitoring.svc`                       | 80    |
| Tempo                | `tempo.monitoring.svc`                               | 4318  |
