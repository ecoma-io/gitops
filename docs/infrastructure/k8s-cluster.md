# Kubernetes Cluster (K3s)

## Tổng quan

Cluster chạy **K3s** bên trong một **VM trên Proxmox** — phiên bản Kubernetes nhẹ, phù hợp single-node. VM được cấu hình 24 vCPU / 48 GB RAM (overcommit từ host vật lý 32 GB + ZSwap). Các thành phần built-in (Traefik, ServiceLB, metrics-server, local-storage) được disable để cài riêng qua Helm/ArgoCD, kiểm soát cấu hình đầy đủ hơn. CoreDNS giữ nguyên built-in để đảm bảo DNS sẵn sàng cho quá trình bootstrap, sau đó ArgoCD tiếp quản và cấu hình thêm qua `declarative/platform/coredns/`.

---

## Provisioning

K3s được cài thủ công trong **VM ecoma** (trên Proxmox). Sau khi LVM Volume Groups (`vg-nvme`, `vg-hdd`) đã được tạo trong VM (xem [Server & Storage](./server.md#storage--lvm)), cài K3s với các flags:

```bash
curl -sfL https://get.k3s.io | sh -s - \
  --disable traefik \
  --disable local-storage \
  --disable servicelb \
  --disable-cloud-controller \
  --disable metrics-server \
  --data-dir /var/lib/rancher \
  --node-name ecoma-01 \
  --kubelet-arg=max-pods=256 \
  --kube-controller-manager-arg=node-cidr-mask-size=23
```

- `--disable traefik` — cài riêng qua Helm/ArgoCD để kiểm soát cấu hình đầy đủ
- `--disable local-storage` — dùng OpenEBS LVM-LocalPV thay thế
- `--disable servicelb` — không cần LoadBalancer vì traffic đi qua Cloudflare Tunnel → Traefik
- `--disable metrics-server` — cài riêng qua Helm/ArgoCD để quản lý version và cấu hình thống nhất

> **Lưu ý:** CoreDNS **không disable** — giữ built-in để ArgoCD có thể resolve DNS ngay khi bootstrap. Sau đó, `declarative/platform/coredns/` tiếp quản và cấu hình thêm những gì cần thiết thông qua ArgoCD.

- `--kubelet-arg=max-pods=256` — tăng giới hạn pod tối đa lên 256 (mặc định 110), phù hợp single-node chạy nhiều workload
- `--kube-controller-manager-arg=node-cidr-mask-size=23` — cấp subnet /23 (512 địa chỉ) cho node thay vì /24 (254 địa chỉ), đủ IP cho 256 pods

Sau khi cài xong, kubeconfig ở `/etc/rancher/k3s/k3s.yaml`.

---

## Namespaces

| Namespace              | Mục đích                                                                                                                 |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `argocd`               | ArgoCD — GitOps controller                                                                                               |
| `cert-manager`         | cert-manager — TLS certificate management                                                                                |
| `infra`                | PostgreSQL (CNPG), Redis, NATS JetStream, SeaweedFS, Kratos, Keto, Hydra, token-hook                                    |
| `cnpg-system`          | CloudNativePG operator — quản lý PostgreSQL Cluster CRDs                                                                 |
| `monitoring`           | kube-prometheus-stack (Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics), Mimir, Loki, Tempo, Alloy  |
| `ingress`              | Traefik Ingress Controller, cloudflared                                                                                  |
| `kube-system`          | CoreDNS (built-in K3s, customized qua ArgoCD), metrics-server, Sealed Secrets controller, OpenEBS LVM-LocalPV CSI driver |
| `coder`                | Coder — developer workspace platform                                                                                     |
| `mailpit`              | Mailpit — fake SMTP server dùng cho dev/test email                                                                       |
| `ecoma-dev-{username}` | Workspace riêng của từng developer (tạo qua Coder — chưa triển khai)                                                     |
| `ecoma-preview-{pr}`   | Môi trường preview cho Pull Request (tự động tạo/xóa — chưa triển khai)                                                  |
| `ecoma-staging`        | Môi trường staging (chưa triển khai)                                                                                     |
| `ecoma-prod`           | Môi trường production (chưa triển khai)                                                                                  |

> Developer environment được tạo/xóa qua Coder UI. Preview environment được tạo/xóa tự động qua CI.

---

## Resource Allocation (ước tính)

> Chiến lược xác định, điều chỉnh, và quy tắc bắt buộc: xem [Resource Management](./resource-management.md).

**Infra services:**

| Component               | CPU Request | CPU Limit | Memory Request | Memory Limit | Storage |
| ----------------------- | ----------- | --------- | -------------- | ------------ | ------- |
| PostgreSQL              | 500m        | —         | 1 GB           | 2 GB         | nvme    |
| Redis                   | 100m        | —         | 256 MB         | 512 MB       | nvme    |
| NATS JetStream          | 200m        | 800m      | 512 MB         | 1 GB         | nvme    |
| SeaweedFS master        | 100m        | 400m      | 256 MB         | 512 MB       | nvme    |
| SeaweedFS volume (hot)  | 200m        | 800m      | 512 MB         | 1 GB         | nvme    |
| SeaweedFS volume (cold) | 100m        | 400m      | 256 MB         | 512 MB       | hdd     |

**Observability (Grafana Observability stack):**

Pipeline tổng quan:

```
Applications / Infrastructure
    │
    ├── metrics ──► Prometheus (scrape, short-term 24h) ──► remote_write ──► Mimir ──► SeaweedFS (S3)
    ├── logs ──► Alloy (collect) ──► Loki ──► SeaweedFS (S3)
    ├── traces ──► Alloy (receive OTLP) ──► Tempo ──► SeaweedFS (S3)
    └── RUM ──► Alloy (Faro receiver) ──► Loki + Tempo
                                                              │
                                                     Grafana (query all) ◄──┘
```

Chi tiết từng thành phần:

| Component              | Vai trò                               | Chi tiết                                                                                                                                                                                                                   |
| ---------------------- | ------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Prometheus**         | Metrics scraping & short-term storage | Scrape targets: node-exporter, kube-state-metrics, app /metrics endpoints. Retention: 24h local TSDB. `remote_write` tất cả metrics sang Mimir.                                                                            |
| **Mimir**              | Long-term metrics storage             | Nhận metrics từ Prometheus qua remote_write. Lưu blocks vào SeaweedFS qua S3 API. Grafana query Mimir thay vì Prometheus cho historical data.                                                                              |
| **Alertmanager**       | Alert routing & notification          | Nhận alerts từ Prometheus rules. Route: email (Brevo/Mailpit tùy env), có thể mở rộng Slack/webhook sau.                                                                                                                   |
| **node-exporter**      | Node-level metrics                    | CPU, RAM, disk I/O, network — chạy DaemonSet.                                                                                                                                                                              |
| **kube-state-metrics** | Kubernetes object metrics             | Pod status, deployment replicas, resource requests/limits.                                                                                                                                                                 |
| **Loki**               | Log aggregation                       | Nhận logs từ Alloy. Index trên NVMe, chunks lưu vào SeaweedFS (S3). Label-based query, không full-text index.                                                                                                              |
| **Grafana Alloy**      | Unified telemetry collector           | Thay thế Promtail + OTel Collector + Faro Collector. DaemonSet, đọc container logs (`/var/log/pods`), nhận traces/metrics qua OTLP, nhận browser telemetry (Faro). Ship logs → Loki, traces → Tempo, metrics → Prometheus. |
| **Tempo**              | Distributed tracing                   | Nhận traces từ Alloy (OTLP). Lưu trace data vào SeaweedFS (S3). Trace-to-log linking với Loki.                                                                                                                             |
| **Grafana**            | Visualization & dashboards            | Datasources: Mimir (metrics), Loki (logs), Tempo (traces). Dashboards provisioned as code từ Git.                                                                                                                          |

Resource allocation:

| Component          | CPU Request | CPU Limit | Memory Request | Memory Limit | Storage                    |
| ------------------ | ----------- | --------- | -------------- | ------------ | -------------------------- |
| Prometheus         | 300m        | 1000m     | 1 GB           | 2 GB         | nvme (24h local TSDB)      |
| Mimir              | 200m        | 600m      | 512 MB         | 1 GB         | SeaweedFS (S3 API)         |
| Alertmanager       | 50m         | 200m      | 128 MB         | 256 MB       | —                          |
| node-exporter      | 50m         | 200m      | 64 MB          | 128 MB       | —                          |
| kube-state-metrics | 50m         | 200m      | 128 MB         | 256 MB       | —                          |
| Loki               | 200m        | 600m      | 512 MB         | 1 GB         | SeaweedFS (S3 API)         |
| Alloy              | 100m        | 400m      | 256 MB         | 512 MB       | —                          |
| Tempo              | 200m        | 600m      | 512 MB         | 1 GB         | SeaweedFS (S3 API)         |
| Grafana            | 100m        | 400m      | 256 MB         | 512 MB       | nvme (dashboards, plugins) |

**Platform:**

| Component      | CPU Request | CPU Limit | Memory Request | Memory Limit |
| -------------- | ----------- | --------- | -------------- | ------------ |
| ArgoCD         | 200m        | 800m      | 512 MB         | 1 GB         |
| CloudNativePG  | 100m        | 400m      | 256 MB         | 512 MB       |
| cert-manager   | 50m         | 200m      | 64 MB          | 128 MB       |
| Traefik        | 100m        | 400m      | 128 MB         | 256 MB       |
| CoreDNS        | 100m        | 400m      | 128 MB         | 256 MB       |
| metrics-server | 50m         | 200m      | 64 MB          | 128 MB       |
| Sealed Secrets | 50m         | 200m      | 64 MB          | 128 MB       |
| cloudflared    | 50m         | 200m      | 64 MB          | 128 MB       |

**Coder Workspaces (per developer):**

|                  | CPU Request | CPU Limit | Memory Request | Memory Limit | Ghi chú                                                    |
| ---------------- | ----------- | --------- | -------------- | ------------ | ---------------------------------------------------------- |
| Workspace pod    | ~500m       | ~2000m    | ~1.2 GB        | ~2.4 GB      | VS Code server + tools + backend services + Kratos + Hydra |
| Active frontend  | ~300m       | ~1000m    | ~300 MB        | ~600 MB      | Nuxt/Vue dev server của app đang develop                   |
| **Tổng per dev** | ~800m       | ~3000m    | ~1.5 GB        | ~3 GB        | Auto-stop khi idle (được cấu hình trong Coder template)    |

**Applications (preview/staging/prod):**

|         | CPU Request | CPU Limit | Memory Request | Memory Limit | Ghi chú                                                    |
| ------- | ----------- | --------- | -------------- | ------------ | ---------------------------------------------------------- |
| preview | ~500m       | ~2000m    | ~1 GB          | ~2 GB        | Tất cả services chạy đầy đủ, Mailpit dùng chung từ `infra` |
| staging | ~500m       | ~2000m    | ~1 GB          | ~2 GB        | Brevo sandbox                                              |
| prod    | ~1000m      | ~4000m    | ~2 GB          | ~4 GB        | Brevo live                                                 |

Tổng ước tính (5 developers): ~5–6 CPU / ~14–16 GB RAM — còn headroom trên server 24 vCPU / 48 GB RAM. Coder auto-stop workspace khi idle giúp tiết kiệm resource.

---

> StorageClasses (`nvme` ~430 GB, `hdd` ~11 TB), LVM setup trong VM, và cách PVC provisioning hoạt động: xem [Server & Storage](./server.md#storageclasses-kubernetes).

---

## SeaweedFS Topology

| Component          | Type        | Replica | StorageClass | Mục đích                      |
| ------------------ | ----------- | ------- | ------------ | ----------------------------- |
| Master             | StatefulSet | 1       | nvme         | Metadata, topology management |
| Filer + S3 Gateway | Deployment  | 1       | nvme         | S3 API cho Mimir/Loki/Tempo   |
| Volume (hot)       | StatefulSet | 1       | nvme         | Hot data, high IOPS           |
| Volume (cold)      | StatefulSet | 1       | hdd          | Cold data, tiering tự động    |

S3 endpoint nội bộ: `http://seaweedfs-s3.infra.svc:8333`

**S3 Bucket Initialization**: Mỗi observability service tự khởi tạo bucket cần thiết thông qua một **ArgoCD PreSync Job** (`bucket-init-job.yaml`) chạy trước khi ArgoCD sync phần còn lại:

| Service | Buckets                                             |
| ------- | --------------------------------------------------- |
| Mimir   | `mimir-blocks`, `mimir-ruler`, `mimir-alertmanager` |
| Loki    | `loki-chunks`, `loki-ruler`, `loki-admin`           |
| Tempo   | `tempo-traces`                                      |

Job dùng image `amazon/aws-cli:2.34.28`, poll SeaweedFS S3 cho đến khi sẵn sàng, rồi tạo từng bucket nếu chưa tồn tại. Credentials cố định: `AWS_ACCESS_KEY_ID=ecoma`, `AWS_SECRET_ACCESS_KEY=ecoma`.

---

## K3s HA Mode — Lộ trình khi cần mở rộng

> ⚠️ **Hiện tại:** Cluster chạy single-node với SQLite datastore. Đây là quyết định có chủ ý ở giai đoạn early-stage. Xem [ADR-0001](../architecture/decisions/0001-single-node-with-ha-migration-path.md).

Khi cần chuyển sang HA, K3s hỗ trợ **embedded etcd** với tối thiểu 3 server nodes (số lẻ để đảm bảo quorum Raft):

```
Single-node (hiện tại)         →    K3s HA Embedded Etcd

Server ecoma-01                     ecoma-cp-01 (server + etcd)
  └── K3s (SQLite)                  ecoma-cp-02 (server + etcd)
                                    ecoma-cp-03 (server + etcd)
                                    ecoma-wk-01 (agent, worker only)
                                    ecoma-wk-0N (...)
```

**Lưu ý quan trọng khi multi-node:**

| Thành phần | Tác động khi multi-node |
|---|---|
| **OpenEBS LVM-LocalPV** | PV gắn cứng vào node, workload không thể reschedule sang node khác → phải migrate sang Longhorn/Rook-Ceph trước |
| **`storageClass: nvme/hdd`** | Là node-local, không portable. Đây là **blocker lớn nhất** khi scale |
| **StatefulSets** (PostgreSQL, Redis, NATS...) | Không thể tự động move sang node mới nếu dùng LVM-LocalPV |
| **Stateless Deployments** | Scale ngay khi có thêm nodes, chỉ cần tăng `replicas` và thêm `podAntiAffinity` |

**Flags K3s cho server nodes (embedded etcd):**

```bash
# Node đầu tiên — khởi tạo cluster HA
curl -sfL https://get.k3s.io | K3S_TOKEN=<token> sh -s - server \
  --cluster-init \
  --disable traefik --disable local-storage \
  --disable servicelb --disable metrics-server \
  --node-name ecoma-cp-01

# Node 2 và 3 — join cluster
curl -sfL https://get.k3s.io | K3S_TOKEN=<token> sh -s - server \
  --server https://ecoma-cp-01:6443 \
  --disable traefik --disable local-storage \
  --disable servicelb --disable metrics-server \
  --node-name ecoma-cp-02

# Worker-only nodes (không chạy control-plane)
curl -sfL https://get.k3s.io | K3S_TOKEN=<token> sh -s - agent \
  --server https://ecoma-cp-01:6443 \
  --node-name ecoma-wk-01
```

> Chi tiết đầy đủ từng bước migration: [Scale to HA Runbook](../runbooks/scale-to-ha.md).
