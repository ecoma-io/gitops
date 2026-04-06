# CD Pipeline

## Tổng quan

Gitops repo chứa toàn bộ cấu hình triển khai. **ArgoCD** theo dõi repo này và đồng bộ lên K3s cluster thông qua cơ chế **Push (Event-driven Webhook)** để đạt tốc độ deploy thời gian thực (real-time).

```
Pull Request (source repo) ──► CI commit overlay vào gitops repo
                                    │
                          GitHub Webhook trigger ArgoCD
                                    │
                                    ▼
                               ArgoCD Sync ──► K3s Cluster
                                    │
                          ArgoCD Notifications gọi Deployments API
                                    │
                                    ▼
                          GitHub PR (Hiển thị ✅ Deployment Status)


Push to main (source repo) ──► docker build + push ghcr.io
                                    │
                          ArgoCD Image Updater
                          detect image mới → tự update tag → sync
                                    │
                                    ▼
                              K3s Cluster
```

> CI pipeline (build, test, publish image) nằm trong [source repo](https://github.com/ecoma/source/blob/main/docs/development/ci-pipeline.md).

---

## App Manifests

Kubernetes manifests tổ chức theo 2 loại:

### Infrastructure services (Kustomize + Helm)

```
declarative/
├── platform/traefik/
│   ├── kustomization.yaml     ← Kustomize config (helmCharts section)
│   └── traefik.values.yaml    ← Helm values
├── observability/loki/
├── infras/postgresql/
└── tools/coder/
```

Mỗi nhóm có ApplicationSet riêng scan `declarative/<group>/*/config.json` → tự tạo ArgoCD Application cho mỗi folder. Mỗi folder chứa `kustomization.yaml` với `helmCharts` section (Helm) hoặc `resources` (plain manifests). Thêm service mới = tạo folder trong nhóm tương ứng + commit.

### Ecoma applications

```
declarative/applications/
└── landing/
    ├── base/
    │   ├── deployment.yaml
    │   └── service.yaml
    └── overlays/
        ├── staging/
        │   └── config.json          ← Metadata cho ApplicationSet
        └── prod/
            └── config.json
```

Root App sử dụng ApplicationSet quét `declarative/applications/*/overlays/{env}/` → tự deploy.

Tách manifests ra gitops repo giúp:

- ArgoCD có single source of truth cho toàn bộ cấu hình hạ tầng
- Code change (source repo) và config change (gitops repo) có vòng đời CI/CD độc lập
- Không cần CI của source repo commit ngược manifest — ArgoCD Image Updater tự update image tag

---

## ArgoCD Image Updater

**ArgoCD Image Updater** tự watch ghcr.io, phát hiện image tag mới → tự override tag → trigger ArgoCD sync. CI chỉ build + push image. Không cần CI commit manifest.

---

> Kiến trúc Autopilot-inspired Pattern (bootstrap flow, ApplicationSet discovery): xem [Architecture Overview](../architecture/overview.md#argocd--autopilot-inspired-pattern).

---

## Sync Policy

| Environment | Auto sync   | Self heal          | Prune |
| ----------- | ----------- | ------------------ | ----- |
| `preview`   | ✅          | ✅                 | ✅    |
| `staging`   | ❌ (manual) | N/A (requires auto)| ❌    |
| `prod`      | ❌ (manual) | N/A (requires auto)| ❌    |

- `preview`: Đồng bộ **thời gian thực** thông qua GitHub Webhook (Push) thay vì chờ chu kỳ 3 phút của ArgoCD.
- `staging` và `prod`: cần vào ArgoCD UI hoặc CLI để trigger sync thủ công

> `dev` không nằm trong bảng này — developer chạy code trực tiếp qua Coder workspace (`nx serve`), không deploy qua ArgoCD.

---

## Event-Driven GitOps (Push Mechanism)

Để loại bỏ độ trễ của việc ArgoCD định kỳ pull (3 phút/lần) và cung cấp feedback loop trực tiếp cho developer, hệ thống sử dụng cơ chế Push:

### 1. GitHub Webhook -> ArgoCD (Cập nhật thời gian thực)

Khi có thay đổi trên nhánh (VD: source repo commit manifest mới vào đây khi mở PR), GitHub gửi webhook (`push` event) trực tiếp tới endpoint `/api/webhook` của ArgoCD trên cụm K3s. ArgoCD lập tức sync bypass chu kỳ 3 phút.

### 2. ArgoCD Notifications -> GitHub PR (Feedback Loop)

Sử dụng **ArgoCD Notifications** controller: Khi App `preview` được deploy xong và pods đạt trạng thái `Healthy`, ArgoCD tự động gọi chuẩn lên **GitHub Deployments API**. Trạng thái Deployment (Pending / Success) và URL môi trường (`https://pr{id}.ecoma.io`) sẽ được cập nhật trực tiếp dưới dạng tích xanh (✅) trên giao diện Pull Request của source repo.

---

## Preview Environments

### Deploy

Trigger: PR opened/synchronized trong source repo. GitHub Actions tạo overlay `declarative/applications/<service>/overlays/preview-{pr}/` vào **gitops repo**. GitHub Webhook lập tức báo ArgoCD deploy. Sau khi deploy xong, ArgoCD Notifications cập nhật `Deployment status` trên PR.

### Cleanup

Trigger: PR closed trong source repo. GitHub Actions xóa folder `declarative/applications/<service>/overlays/preview-{pr}/`, commit. Webhook kích hoạt ArgoCD dọn dẹp (cascade delete) ngay lập tức.

---

> Hướng dẫn promote staging/prod step-by-step: xem [Runbook: Deploy](../runbooks/deploy.md).

---

## CI cho GitOps Repo

Bản thân gitops repo cũng cần CI để đảm bảo thay đổi không làm gãy cluster trước khi merge vào `main`.

### PR Validation (GitHub Actions)

Mọi Pull Request vào `main` phải pass pipeline sau:

```
PR opened/updated
      │
      ▼
┌─────────────────────────────────────────────┐
│  lint                                       │
│  • yamllint — kiểm tra syntax YAML          │
│  • kubeconform — validate schema K8s        │
│  • helm lint — render + lint Helm values    │
└─────────────────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────────────────┐
│  gitops-test (k3d)                          │
│  • Spin up k3d cluster                      │
│  • Bootstrap ArgoCD                         │
│  • Apply platform-appset                    │
│  • Chờ ApplicationSets sync                 │
│  • Verify tất cả Apps đạt Healthy/Synced    │
│  • Teardown cluster                         │
└─────────────────────────────────────────────┘
      │
      ▼
   Merge allowed
```

**Lý do dùng k3d:**
- k3d tạo K3s cluster trong Docker — nhẹ, tạo/xóa trong < 1 phút
- Test toàn bộ luồng ArgoCD ApplicationSet discovery thật sự, không phải mock
- Bắt được lỗi manifest schema, Helm values invalid, hoặc ApplicationSet template sai trước khi merge

**Giới hạn:**
- k3d test không thể kết nối external Helm charts offline (cần stub hoặc cache) — chạy `helm template` thay vì full sync cho infra charts
- SealedSecrets trong test cluster dùng key riêng, không phải production key

### Branch Protection Rules

```
Branch: main
✅ Require status checks:
   - lint
   - gitops-test
✅ Require at least 1 approving review
✅ Dismiss stale reviews on new commits
❌ Allow force push
```

Chi tiết: xem [Contributing — Branch Protection Rules](../contributing.md#branch-protection-rules-github).

---

## Secrets Management (CD)

Secret được quản lý bằng **Sealed Secrets**:

```
# App secrets
declarative/applications/<app>/overlays/{env}/secrets/   # SealedSecret (encrypted, safe to commit)

# Infra secrets
declarative/infras/<service>/sealed-secret.yaml          # SealedSecret cho infra services
declarative/platform/<service>/sealed-secret.yaml        # SealedSecret cho platform services
```

Private key chỉ tồn tại trong cluster. Backup key pair ngay sau install (xem Sprint 3 trong [roadmap](./roadmap.md)).

---

## Gitops CI Pipeline

Gitops repo có CI pipeline riêng tại `.github/workflows/`:

- YAML/Helm values validation
- Drift detection
