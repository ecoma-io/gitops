# Roadmap — GitOps Repo

## Phase 1 — Infrastructure & CD Foundation

**Mục tiêu:** Hoàn thiện toàn bộ hạ tầng và CD pipeline. Kết thúc phase này, hệ thống phải có khả năng: ArgoCD detect image mới → deploy preview/staging/prod, monitoring hoạt động, rollback thử thành công.

> Phase 1 bao gồm cả phần CI pipeline trong [source repo](https://github.com/ecoma/source/blob/main/docs/roadmap.md). Hai repo phát triển song song và kết nối với nhau qua CI/CD pipeline.

**Yêu cầu hoàn thành:** Deploy được một sample app đơn giản chạy qua toàn bộ flow, monitoring hoạt động, rollback thử thành công.

---

### Sprint 1: Server & K3s Setup

Setup server, cấu hình LVM và cài K3s thủ công.

| Task | Mô tả                                                                                                     | Deliverable                     |
| ---- | --------------------------------------------------------------------------------------------------------- | ------------------------------- |
| 1.1  | Cài Tailscale trên Proxmox host (quảng bá subnet 192.168.168.0/24 vào private mesh VPN) + tạo VM ecoma (24 vCPU / 48 GB RAM) | Server/VM accessible qua Tailscale |
| 1.2  | Setup LVM trong VM ecoma trên Data NVMe (~430 GB) → tạo `vg-nvme`, trên HDD (~11 TB) → tạo `vg-hdd`       | `vgs` output chính xác          |
| 1.3  | Cài K3s (disable traefik, local-storage, servicelb, metrics-server), `--node-name ecoma-01` | `kubectl get nodes` → Ready     |
| 1.4  | Verify kubeconfig hoạt động                                                                               | `kubectl cluster-info` OK       |

**Dependency:** Không. Đây là sprint đầu tiên.

---

### Sprint 2: Cloudflare Setup

Cấu hình Cloudflare resources thủ công qua dashboard.

| Task | Mô tả                                                               | Deliverable                     |
| ---- | ------------------------------------------------------------------- | ------------------------------- |
| 2.1  | Tạo Cloudflare Tunnel trên dashboard                                | Tunnel tạo thành công           |
| 2.2  | Cấu hình DNS records: `ecoma.io` + `*.ecoma.io` → tunnel            | DNS resolve đúng                |
| 2.3  | Cấu hình Zero Trust Access Application + Policy cho staging/preview | Zero Trust chặn staging/preview |
| 2.4  | Verify tunnel connectivity từ server                                | Traffic qua tunnel OK           |

**Dependency:** Sprint 1 (cần server để test tunnel connectivity).

---

### Sprint 3: Cluster Bootstrap & Core Services

Bootstrap cluster cơ bản giải quyết bài toán "con gà quả trứng". Quá trình bao gồm cài đặt ArgoCD, Sealed Secrets (kèm inject Private Key ban đầu), sau đó apply Root App. Root App sẽ kích hoạt ArgoCD tự động tiếp quản chính nó và triển khai các cấu hình phức tạp (CRDs, HA, v.v.) cũng như các dịch vụ core khác (traefik, cloudflared).

| Task | Mô tả                                                                                                                                                                                                                                                                | Deliverable                            |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| 3.1  | Lập cấu trúc thư mục Gốc (Root): Tạo thư mục `declarative/` chứa 3 phần riêng biệt: `argocd/` (Root App — ArgoCD tự quản lý + ApplicationSets), `infrastructure/` (những hệ thống dùng chung như Ingress, Sealed-secrets...), và `applications/` (apps của dự án). | Cấu trúc `declarative` sẵn sàng        |
| 3.2  | Lưu Public Key của Sealed Secrets vào thư mục repository (`sealed-secrets.cert`) để Developers dùng mã hóa secret ở local.                                                                                                                                      | Public Key được commit vào repo        |
| 3.3  | Tạo script `bootstrap.sh` tại root repo với 6 bước: Step 1 (inject Sealed Secrets key) → Step 2 (install Sealed Secrets) → Step 3 (install Traefik CRDs) → Step 4 (install ArgoCD) → Step 5 (install Prometheus CRDs) → Step 6 (apply platform-appset scan `declarative/platform/*/config.json`).       | Script bootstrap hoàn thành            |
| 3.4  | Deploy cấu hình đầy đủ của **ArgoCD** và **Sealed Secrets**, cùng với **OpenEBS**, **CoreDNS**, **metrics-server** qua `declarative/platform/`. ArgoCD tự tiếp quản và "đè" cấu hình bootstrap.                                                        | Các core apps hoạt động full tính năng |
| 3.5  | Deploy **Traefik** và **cloudflared** qua GitOps (`declarative/platform/traefik`, `declarative/platform/cloudflared`) để kết nối Cloudflare Tunnel vào Ingress.                                                                                          | Traffic từ Cloudflare → Traefik OK     |
| 3.6  | Cài đặt **ArgoCD Notifications controller** như một phần của cấu hình đầy đủ của ArgoCD trong `declarative/platform/argocd/`.                                                                                                                              | Notifications controller chạy          |
| 3.7  | Verify cấu trúc Root App tự động đồng bộ và quản lý toàn bộ hệ sinh thái của `infrastructure/` và sẵn sàng nhận `applications/`.                                                                                                                                     | Tất cả apps Healthy trên ArgoCD UI     |

**Dependency:** Sprint 1 + Sprint 2 (cần tunnel cho external access).

---

### Sprint 4: Data Layer

Deploy stateful services: database, cache, messaging, object storage.

| Task | Mô tả                                                                                                                              | Deliverable               |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------- | ------------------------- |
| 4.1  | Deploy **PostgreSQL** → `declarative/infras/postgresql/` (namespace `infra`, storage trên nvme)                            | `psql` connect thành công |
| 4.2  | Deploy **Redis** → `declarative/infras/redis/` (namespace `infra`, storage trên nvme)                                      | `redis-cli ping` → PONG   |
| 4.3  | Deploy **NATS JetStream** → `declarative/infras/nats/` (namespace `infra`, storage trên nvme)                              | `nats server check` OK    |
| 4.4  | Deploy **SeaweedFS** → `declarative/infras/seaweedfs/` — master (nvme), filer (nvme), volume-hot (nvme), volume-cold (hdd) | S3 endpoint hoạt động     |
| 4.5  | Deploy **Mailpit** → `declarative/tools/mailpit/` (namespace `infra`)                                                     | SMTP + Web UI accessible  |

**Dependency:** Sprint 3 (cần StorageClasses, ArgoCD, ingress).

---

### Sprint 5: Observability Stack

Deploy full monitoring, logging, tracing pipeline.

| Task | Mô tả                                                                                                                            | Deliverable                                  |
| ---- | -------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| 5.1  | Deploy **kube-prometheus-stack** vào `declarative/observability/` (Prometheus, Alertmanager, node-exporter, kube-state-metrics) | Prometheus targets healthy                   |
| 5.2  | Deploy **Mimir** — cấu hình SeaweedFS làm S3 backend                                                                             | Prometheus remote_write → Mimir OK           |
| 5.3  | Deploy **Loki** + **Promtail** — cấu hình SeaweedFS backend                                                                      | Logs query hoạt động                         |
| 5.4  | Deploy **Tempo** — cấu hình SeaweedFS backend                                                                                    | Traces hiển thị trên Grafana                 |
| 5.5  | Deploy **OpenTelemetry Collector**                                                                                               | OTLP endpoint nhận traces/metrics            |
| 5.6  | Deploy **Grafana** + **Faro Collector**                                                                                          | Grafana UI accessible, datasources connected |
| 5.7  | Cấu hình Alertmanager routes (email qua Mailpit)                                                                                 | Test alert gửi email thành công              |
| 5.8  | Tạo basic dashboards (cluster overview, app health)                                                                              | Dashboards hiển thị data                     |

**Dependency:** Sprint 4 (cần SeaweedFS cho long-term storage).

---

### Sprint 6: Coder — Development Environment

Setup Cloud Development Environment cho developer.

| Task | Mô tả                                                                                                                                     | Deliverable                   |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------- |
| 6.1  | Build workspace Docker image (`declarative/tools/coder/images/workspace/Dockerfile`)                                             | Image pushed lên ghcr.io      |
| 6.2  | Viết Coder Terraform template (`declarative/tools/coder/templates/ecoma-dev/`) — namespace, deployment, PVC, init job, configmap | Template validated            |
| 6.3  | Deploy **Coder** → `declarative/tools/coder/` (namespace `coder`)                                                                | Coder UI tại `coder.ecoma.io` |
| 6.4  | Cấu hình Coder GitHub OAuth                                                                                                               | Login bằng GitHub OK          |
| 6.5  | Import template `ecoma-dev` vào Coder                                                                                                     | Template hiển thị trong UI    |
| 6.6  | Test tạo workspace: namespace tạo, DB tạo, VS Code connect, Nx serve hoạt động                                                            | Developer workflow end-to-end |
| 6.7  | Test xóa workspace: DB drop, namespace xóa sạch                                                                                           | Cleanup hoàn chỉnh            |
| 6.8  | Test CI/CD cho Coder: thay đổi template → ArgoCD detect → auto sync                                                                       | Coder update flow hoạt động   |

**Dependency:** Sprint 4 (cần PostgreSQL, Valkey, NATS cho dev workspace).

---

### Sprint 7: Sample App Manifests (GitOps)

Tạo Kustomize manifests và ArgoCD Application definitions cho sample app (app code được tạo trong [source repo](https://github.com/ecoma/source/blob/main/docs/roadmap.md)).

| Task | Mô tả                                                                                           | Deliverable                  |
| ---- | ----------------------------------------------------------------------------------------------- | ---------------------------- |
| 7.3  | Tạo Kustomize manifests: `declarative/applications/sample/base/`, và `overlays/{staging,prod}/` | `kubectl apply --dry-run` OK |
| 7.4  | Verify ApplicationSet tự discover sample app qua `config.json`                                  | ArgoCD nhận apps             |
| 7.9  | Test: image trên ghcr.io → ArgoCD Image Updater detect → app accessible                         | Full pipeline chạy           |
| 7.10 | **Cấu hình GitHub Webhook** đẩy sự kiện Push về `argocd.ecoma.io/api/webhook`                   | ArgoCD sync bypass delay 3m  |
| 7.11 | **Cấu hình ArgoCD Notifications** gọi API GitHub Deployment (cập nhật trạng thái PR bằng HTTPS) | GitHub PR hiện ✅ deploy     |

**Dependency:** Sprint 3 (ArgoCD, ingress, notifications). Task 7.9 cần source repo Sprint 7 hoàn thành (CI push image/overlay).

---

### Sprint 8: Validation & Sign-off

Kiểm tra end-to-end toàn bộ hệ thống, xác nhận kiến trúc.

| Task | Mô tả                                                                                                                                                | Deliverable                           |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------- |
| 8.1  | **E2E flow test:** Developer tạo workspace → code sample app → commit → push → PR → preview deploy → review → merge → staging promote → prod promote | Toàn bộ flow từ code đến prod         |
| 8.2  | **Rollback test:** Deploy version lỗi → phát hiện → rollback qua ArgoCD → verify                                                                     | Rollback < 5 phút                     |
| 8.3  | **Monitoring test:** Gây load trên sample app → verify metrics/logs/traces xuất hiện trên Grafana                                                    | Dashboard hiển thị đúng data          |
| 8.4  | **Alert test:** Trigger alert condition → verify email notification                                                                                  | Alert email đến Mailpit               |
| 8.5  | **Backup test:** Restore VM từ Proxmox Backup Server (PBS) trên môi trường test, verify dữ liệu OK                                                   | Restore thành công, service hoạt động |
| 8.6  | **Coder template update test:** Thay đổi template → commit → ArgoCD detect → auto sync                                                               | Template update flow hoạt động        |
| 8.7  | Review & cập nhật docs: ghi nhận các thay đổi so với thiết kế ban đầu, cập nhật ADRs                                                                 | Docs phản ánh thực tế                 |
