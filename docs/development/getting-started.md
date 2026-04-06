# Getting Started — GitOps

Hướng dẫn làm việc với gitops repo: quản lý hạ tầng, cấu hình ArgoCD, và vận hành cluster.

## Yêu cầu

| Tool           | Mục đích                          | Cài đặt                                        |
| -------------- | --------------------------------- | ---------------------------------------------- |
| **kubectl**    | Quản lý K3s cluster               | Có sẵn trên server qua Tailscale               |
| **kubeseal**   | Tạo SealedSecrets                 | `brew install kubeseal` hoặc binary release    |
| **argocd** CLI | Quản lý ArgoCD apps               | `brew install argocd` hoặc binary release      |
| **helm**       | Render Helm values (debug)        | `brew install helm`                            |
| **mirrord**    | Intercept traffic từ cluster      | `brew install metalbear-co/mirrord/mirrord`    |
| **k3d**        | Spin up local K3s cluster (CI)    | `brew install k3d`                             |
| **Tailscale**  | Kết nối vào server                | https://tailscale.com                          |
| **Git**        | Version control                   | Bất kỳ                                         |

> Hầu hết thao tác thực hiện qua SSH vào server (qua Tailscale) hoặc qua ArgoCD UI tại `argocd.ecoma.io`.

> Cấu trúc thư mục repo: xem [Architecture Overview — Repo Structure](../architecture/overview.md#repo-structure).

---

## Workflow thường gặp

### Thêm/sửa cấu hình infra service

1. Sửa `values.yaml` trong folder tương ứng:
   - Core cluster infra: `declarative/platform/<service>/`
   - Monitoring/logging/tracing: `declarative/observability/<service>/`
   - Shared services (DB, queue, auth): `declarative/infras/<service>/`
   - Developer tools: `declarative/tools/<service>/`
2. Commit + push lên `main`
3. ArgoCD tự detect thay đổi → sync

### Thêm infra service mới

1. Xác định nhóm: `platform/`, `observability/`, `infras/`, hoặc `tools/`
2. Tạo folder `declarative/<group>/<service>/` với `kustomization.yaml`, `config.json` (chứa `syncWave`), và values file nếu dùng Helm
3. Commit + push → ApplicationSet của nhóm đó tự discover → deploy

### Thêm Ecoma app mới

1. Tạo manifests trong `declarative/applications/<service>/base/`
2. Tạo overlays: `declarative/applications/<service>/overlays/staging/` (+ `config.json`)
3. Commit + push → ApplicationSet tự discover → deploy

### Tạo SealedSecret

```bash
# 1. Tạo secret thường
kubectl create secret generic my-secret \
  --from-literal=password=xxx \
  --dry-run=client -o yaml > secret.yaml

# 2. Seal với public key
kubeseal --format yaml < secret.yaml > sealed-secret.yaml

# 3. Commit sealed-secret.yaml vào repo
# 4. Xóa secret.yaml (không commit plain secret!)
```

### Debug service với mirrord (intercept traffic từ cluster)

Khi đang sửa một service và muốn test với traffic thật từ cluster (thay vì phải spin up toàn bộ stack):

```bash
# Intercept traffic của service-b từ cluster, chạy local code
mirrord exec --target deployment/ecoma-service-b -- nx serve service-b
```

Service đang chạy trong workspace sẽ nhận traffic thật như thể nó đang chạy trong cluster. Xem chi tiết tại [Environments — mirrord](../infrastructure/environments.md#mirrord--traffic-intercept-cho-service-đang-sửa).

### Test thay đổi gitops với k3d (local cluster)

Trước khi tạo PR, có thể test locally bằng k3d:

```bash
# Tạo cluster test
k3d cluster create gitops-test

# Bootstrap ArgoCD
kubectl apply -k https://github.com/argoproj/argo-cd/manifests/crds

# Apply platform ApplicationSet
kubectl apply -f declarative/platform/argocd/platform-appset.yaml

# Theo dõi sync
argocd app list --watch

# Dọn dẹp
k3d cluster delete gitops-test
```

### Kiểm tra trạng thái ArgoCD

```bash
# Qua CLI
argocd app list
argocd app get <app-name>

# Qua UI
# Truy cập https://argocd.ecoma.io
```

---

## Liên kết

- [CD Pipeline](./cd-pipeline.md) — Chi tiết về ArgoCD, Image Updater, sync policy
- [Infrastructure](../infrastructure/) — Hardware, K3s cluster, environments
- [Runbooks](../runbooks/) — Deploy, incident response, rollback
- [Roadmap](./roadmap.md) — Phase 1 sprints cho gitops
