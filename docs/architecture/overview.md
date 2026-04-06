# Infrastructure Architecture

## Tổng quan

GitOps repo quản lý toàn bộ cấu hình hạ tầng và triển khai cho hệ thống Ecoma. Repo này là **single source of truth** cho Kubernetes cluster, được ArgoCD theo dõi và tự động sync.

> Kiến trúc tổng quan hệ thống (applications, tech stack): xem [source repo](https://github.com/ecoma/source/blob/main/docs/architecture/overview.md).

---

## Kiến trúc hạ tầng

```
┌──────────────────────────────────────────────────────────────────┐
│  Server (Debian 12)                                │
│  24 vCPU / 48 GB RAM                                             │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐   │
│  │  K3s Cluster                                               │   │
│  │                                                            │   │
│  ┌─────────┐ ┌─────────┐ ┌──────────────────────────────┐   │   │
│  │ ingress │ │ argocd  │ │         kube-system          │   │   │
│  │Traefik  │ │ ArgoCD  │ │ CoreDNS  metrics-srv         │   │   │
│  │cloudfl. │ │         │ │ Sealed Secrets (+ key)       │   │   │
│  └─────────┘ └─────────┘ └──────────────────────────────┘   │   │
│  │                                                            │   │
│  │  ┌──────────────┐ ┌──────────────┐ ┌──────────────────┐   │   │
│  │  │     infra    │ │  monitoring  │ │   cnpg-system    │   │   │
│  │  │PG,Redis,     │ │Prom,Mimir,  │ │  CloudNativePG   │   │   │
│  │  │NATS,SW,      │ │Loki,Alloy,  │ │  Operator        │   │   │
│  │  │Kratos,Keto   │ │Tempo,Grafana │ │                  │   │   │
│  │  └──────────────┘ └──────────────┘ └──────────────────┘   │   │
│  │                                                            │   │
│  │  ┌──────────┐ ┌─────────┐ ┌────────────────────────────┐  │   │
│  │  │  coder   │ │mailpit  │ │          openebs           │  │   │
│  │  │  Coder   │ │Mailpit  │ │       LVM-LocalPV          │  │   │
│  │  └──────────┘ └─────────┘ └────────────────────────────┘  │   │
│  │                                                            │   │
│  │  ┌──────────────┐ ┌──────────────┐ ┌──────────────────┐   │   │
│  │  │ecoma-staging │ │ ecoma-prod  │ │ecoma-dev-{user}  │   │   │
│  │  │              │ │             │ │ecoma-preview-{pr}│   │   │
│  │  └──────────────┘ └──────────────┘ └──────────────────┘   │   │
│  └────────────────────────────────────────────────────────────┘   │
│                                                                  │
│  Storage: vg-nvme (900GB NVMe) + vg-hdd (5TB HDD)               │
│  Network: Tailscale (mgmt) + Cloudflare Tunnel (apps)            │
└──────────────────────────────────────────────────────────────────┘
```

---

## ArgoCD — Autopilot-inspired Pattern

Cấu trúc lấy cảm hứng từ [ArgoCD Autopilot](https://github.com/argoproj-labs/argocd-autopilot), tổ chức trong thư mục `declarative/` với 5 concerns tách biệt và 8 ArgoCD Projects:

1. **`declarative/platform/`** — Core cluster infra: ArgoCD tự quản lý chính nó + Traefik, cert-manager, sealed-secrets, CoreDNS, ... Tất cả managed bởi `platform-appset`. Project: `platform`
2. **`declarative/observability/`** — Monitoring/logging/tracing stack: Prometheus, Loki, Mimir, Tempo, Alloy. Project: `observability`
3. **`declarative/infras/`** — Shared services được apps consume trực tiếp: PostgreSQL, Redis, NATS, SeaweedFS, Kratos, Keto. Project: `infras`
4. **`declarative/tools/`** — Developer/ops tools: Coder, Mailpit. Project: `tools`
5. **`declarative/applications/`** — Ecoma application manifests. Projects: `ecoma-production`, `ecoma-staging`, `ecoma-preview`, `ecoma-dev`

```
bootstrap.sh (repo root)                 ← Run once (6-step script, direct kubectl)
    Step 1 → Inject Sealed Secrets key vào kube-system
    Step 2 → Install Sealed Secrets controller (direct URL)
    Step 3 → Install Traefik CRDs (direct URL)
    Step 4 → Install ArgoCD (direct URL)
    Step 5 → Install Prometheus Operator CRDs (direct URL)
    Step 6 → Apply platform-appset (scan declarative/platform/*/config.json)
                │
                ▼
          declarative/platform/argocd/    ← syncWave -10: ArgoCD adopted first
          │   kustomization.yaml          ← ArgoCD tự quản lý (Kustomize)
          │   projects.yaml              ← 8 ArgoCD Projects
          │   platform-appset.yaml       ← scan declarative/platform/*/
          │   observability-appset.yaml  ← scan declarative/observability/*/
          │   infras-appset.yaml         ← scan declarative/infras/*/
          │   tools-appset.yaml          ← scan declarative/tools/*/
          │   applications-appset.yaml   ← scan declarative/applications/*/overlays/*/
          │
          ├── declarative/platform/      (traefik, cert-manager, sealed-secrets, ...)
          ├── declarative/observability/ (prometheus, loki, mimir, tempo, alloy)
          ├── declarative/infras/        (postgresql, redis, nats, seaweedfs, ...)
          ├── declarative/tools/         (coder, mailpit)
          └── declarative/applications/  (ecoma apps per environment overlay)
```

### Ưu điểm so với App of Apps truyền thống

- **Không cần tạo ArgoCD Application thủ công** cho mỗi service — mỗi ApplicationSet tự discover qua git generator
- **Thêm service mới** = tạo folder trong đúng nhóm + commit → ArgoCD tự phát hiện và deploy
- **Xóa service** = xóa folder + commit → ArgoCD cascade delete
- **Phân quyền rõ ràng** theo ArgoCD Projects — production cô lập hoàn toàn khỏi dev/preview ở cấp ArgoCD
- **Tách biệt** giữa bootstrap (one-time script), platform self-management, và từng layer infrastructure
- **Bootstrap chỉ chạy 1 lần** — sau đó ArgoCD tự tiếp quản toàn bộ, kể cả chính nó

---

## Repo Structure

```
gitops/
├── bootstrap.sh                           ← One-time bootstrap (6-step, direct kubectl)
├── sealed-secrets.cert                    ← Public key for encrypting secrets
├── sealed-secrets.key                     ← Private key (from Password Manager, NEVER commit)
├── declarative/                           ← Kubernetes declarative configs
│   ├── argocd/                            ← Root App — ArgoCD self-management (Kustomize) + ApplicationSet
│   │   ├── kustomization.yaml             ← ArgoCD install + patches (Kustomize remote base)
│   │   ├── infras-appset.yaml             ← Infrastructure ApplicationSet (git directory generator)
│   │   ├── ingress.yaml                   ← ArgoCD Ingress (argocd.ecoma.io)
│   │   └── dex-secret.yaml                ← GitHub OAuth SealedSecret cho Dex
│   ├── infrastructure/                    ← Shared infrastructure services
│   │   └── <service>/
│   │       ├── kustomization.yaml         ← Kustomize config (helmCharts hoặc resources)
│   │       └── *.values.yaml              ← Helm values (nếu dùng Helm)
│   └── applications/                      ← Ecoma application manifests
│       └── <service>/
│           ├── base/
│           └── overlays/{staging,prod,preview-{pr}}/
├── docs/                                  ← Tài liệu (VitePress)
│   ├── architecture/
│   ├── development/
│   ├── infrastructure/
│   └── runbooks/
└── .github/workflows/                    ← CI pipeline (validate, lint)
```

---

## Chi tiết

- [Server & Storage](../infrastructure/server.md)
- [K8s Cluster](../infrastructure/k8s-cluster.md)
- [Resource Management](../infrastructure/resource-management.md)
- [Environments](../infrastructure/environments.md)
- [CD Pipeline](../development/cd-pipeline.md)
