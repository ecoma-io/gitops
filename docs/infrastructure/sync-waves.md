# Sync Waves — Infrastructure Ordering

## Tổng quan

Hệ thống sử dụng **ArgoCD sync waves** để kiểm soát thứ tự triển khai infrastructure components. Toàn bộ infrastructure sử dụng **wave âm (< 0)** để dành wave ≥ 0 cho application deployments.

Sync wave được khai báo trong `config.json` tại mỗi component directory (ví dụ `declarative/platform/<component>/config.json`), được ApplicationSet tương ứng đọc và gán annotation `argocd.argoproj.io/sync-wave` cho từng Application.

---

## Quy ước

| Phạm vi        | Wave Range   | Ghi chú                      |
| -------------- | ------------ | ---------------------------- |
| Infrastructure | `-10` → `-1` | Foundation → Developer tools |
| Applications   | `0` → `+N`   | Dành cho ecoma services      |

---

## Wave Assignment

| Wave    | Components                                            | Lý do                  |
| ------- | ----------------------------------------------------- | ---------------------- | ----------------------------------------------------------------------------------- |
| Wave    | Components                                            | Nhóm                   | Lý do                                                                               |
| ------  | -----------                                           | -------                | -------                                                                             |
| **-10** | `argocd`                                              | platform               | ArgoCD tự bootstrap và adopt toàn bộ AppSets                                        |
| **-9**  | `openebs-lvm`                                         | platform               | CSI driver phải sẵn sàng để provision PVC cho stateful services                     |
| **-8**  | `sealed-secrets`, `cert-manager`                      | platform               | Security layer: decrypt SealedSecrets, quản lý TLS certificates                     |
| **-7**  | `coredns`, `traefik`, `cloudflared`, `metrics-server` | platform               | Networking: DNS, ingress, tunnel, metrics API                                       |
| **-6**  | `cloudnative-pg`                                      | platform               | CloudNativePG operator phải chạy trước khi tạo Postgres Cluster CR                  |
| **-5**  | `seaweedfs`, `kube-prometheus-stack`                  | infras / observability | Object storage + Prometheus Operator CRDs (cần cho ServiceMonitor)                  |
| **-4**  | `postgresql`, `redis`, `nats`                         | infras                 | Data layer: databases, message broker                                               |
| **-3**  | `loki`, `mimir`, `tempo`, `alloy`                     | observability          | Observability stack (phụ thuộc SeaweedFS/S3, tự khởi tạo bucket qua ArgoCD PreSync Job) |
| **-2**  | `kratos`, `keto`, `mailpit`                           | infras / tools         | Identity, authorization, email (phụ thuộc PostgreSQL)                               |
| **-1**  | `coder`                                               | tools                  | Developer workspace platform (phụ thuộc PostgreSQL, networking)                     |

---

## Cách thêm component mới

1. Xác định nhóm phù hợp: `platform/` (cluster infra), `observability/`, `infras/` (shared services), hoặc `tools/`
2. Tạo directory trong nhóm tương ứng, ví dụ `declarative/infras/<component-name>/`
3. Thêm `config.json`:
   ```json
   {
     "syncWave": "-N"
   }
   ```
4. Thêm `kustomization.yaml` và các file cấu hình
5. ApplicationSet của nhóm đó tự động phát hiện và tạo Application với sync-wave tương ứng

---

## Cách hoạt động

```
declarative/platform/argocd/
    ├── platform-appset.yaml      → Pattern: declarative/platform/*/config.json
    ├── observability-appset.yaml → Pattern: declarative/observability/*/config.json
    ├── infras-appset.yaml        → Pattern: declarative/infras/*/config.json
    └── tools-appset.yaml         → Pattern: declarative/tools/*/config.json

Mỗi AppSet → Template: Application với annotation
    argocd.argoproj.io/sync-wave: {{.syncWave}}
```

Mỗi `config.json` chứa `syncWave` value. ApplicationSet đọc file này và inject annotation vào Application CR được tạo ra.

---

## Lưu ý

- **S3 bucket initialization**: Mỗi observability service (Loki, Tempo, Mimir) tự tạo S3 bucket cần thiết trong SeaweedFS thông qua một **ArgoCD PreSync Job** (`bucket-init-job.yaml`, image `amazon/aws-cli`) chạy trước mỗi sync. Bucket được tạo với `--region us-east-1`; SeaweedFS mặc định yêu cầu auth (access key/secret) nên tất cả bucket là private. Không còn centralized `bucket-init` job — mỗi service tự khai báo và quản lý bucket của mình.
- **KubeDB resources** (Postgres, Redis): ApplicationSet template chứa `ignoreDifferences` với `jqPathExpressions` để bỏ qua các field được KubeDB provisioner tự động thêm vào CR spec (authSecret, clientAuthMode, leaderElection, securityContext, sidecar containers, v.v). Cách tiếp cận `managedFieldsManagers` không hoạt động vì KubeDB thêm field qua controller reconciliation chứ không qua admission webhook, và server-side diff dry-run không predict được các thay đổi này.
- **Prometheus Operator CRDs**: kube-prometheus-stack dùng `ServerSideApply=true` vì CRDs vượt quá 256KB annotation limit.
- **Helm hooks**: Các chart dùng `helm.sh/hook` cần convert sang `argocd.argoproj.io/hook` khi deploy qua kustomize (xem `kubedb/kustomization.yaml` làm ví dụ).
