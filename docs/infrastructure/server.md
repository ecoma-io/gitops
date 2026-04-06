# Hardware

## Server

Toàn bộ hệ thống Ecoma chạy trên một server (on-premise hoặc VPS). K3s cluster chạy trực tiếp trên server — không có hypervisor hay VM layer.

> ⚠️ **SPOF (Single Point of Failure):** Toàn bộ hệ thống — bao gồm production — phụ thuộc vào một server duy nhất. Server down = hệ thống down. Đây là quyết định có chủ ý ở giai đoạn early-stage. Xem [ADR-0001](../architecture/decisions/0001-single-node-with-ha-migration-path.md) để hiểu bối cảnh và [Scale to HA Runbook](../runbooks/scale-to-ha.md) để biết lộ trình khi cần mở rộng.

| Thành phần    | Chi tiết                    |
| ------------- | --------------------------- |
| **vCPU**      | 24 vCPU                     |
| **RAM**       | 48 GB                       |
| **OS Disk**   | ~120 GB NVMe SSD (root `/`) |
| **Data NVMe** | 900 GB NVMe SSD             |
| **HDD**       | 5 TB HDD                    |
| **OS**        | Debian 12     |

---

## Kiến trúc

```
┌─────────────────────────────────────────────────────────────┐
│  Server (Debian 12)                           │
│  ├── Tailscale (management access — private mesh)           │
│  │                                                          │
│  ├── K3s cluster                                            │
│  │   └── Tất cả workload (apps, infra services, monitoring) │
│  │                                                          │
│  ├── Data NVMe (900 GB) → LVM VG vg-nvme → OpenEBS PVCs    │
│  └── HDD (5 TB) → LVM VG vg-hdd → OpenEBS PVCs             │
└─────────────────────────────────────────────────────────────┘
```

---

## Storage — LVM

Hai disk data được setup thành LVM Volume Groups độc lập. **OpenEBS LVM-LocalPV** tự động tạo Logical Volume cho mỗi PVC theo StorageClass tương ứng.

| Disk          | Kích thước | LVM VG    | StorageClass K8s | Workload                                              |
| ------------- | ---------- | --------- | ---------------- | ----------------------------------------------------- |
| OS Disk (`/`) | ~120 GB    | —         | —                | Ubuntu OS, K3s binaries, runtime                      |
| Data NVMe     | 900 GB     | `vg-nvme` | `nvme` (default) | PostgreSQL, Redis, NATS, SeaweedFS metadata/hot tier  |
| HDD           | 5 TB       | `vg-hdd`  | `hdd`            | SeaweedFS cold tier, backups                          |

### Setup LVM

```bash
# Data NVMe (thay /dev/sdX bằng device thực tế, ví dụ /dev/nvme1n1)
pvcreate /dev/sdX
vgcreate vg-nvme /dev/sdX

# HDD (thay /dev/sdY bằng device thực tế)
pvcreate /dev/sdY
vgcreate vg-hdd /dev/sdY
```

> **OpenEBS LVM-LocalPV** sẽ tự tạo Logical Volume cho mỗi PVC — không cần tạo LV thủ công.

### Mở rộng khi đầy

| Điều kiện     | Hành động                                                      |
| ------------- | -------------------------------------------------------------- |
| `vg-nvme` đầy | Thêm NVMe SSD: `pvcreate /dev/sdZ ; vgextend vg-nvme /dev/sdZ` |
| `vg-hdd` đầy  | Thêm HDD: `pvcreate /dev/sdW ; vgextend vg-hdd /dev/sdW`       |

### StorageClasses (Kubernetes)

LVM Volume Groups được expose vào Kubernetes qua **OpenEBS LVM-LocalPV** dưới dạng StorageClasses:

| StorageClass     | LVM VG    | Kích thước | Dùng cho                                              |
| ---------------- | --------- | ---------- | ----------------------------------------------------- |
| `nvme` (default) | `vg-nvme` | 900 GB     | PostgreSQL, Redis, NATS, SeaweedFS metadata/hot tier  |
| `hdd`            | `vg-hdd`  | 5 TB       | SeaweedFS cold tier, backups                          |

```yaml
# Ví dụ StorageClass cho nvme
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nvme
provisioner: local.csi.openebs.io
parameters:
  storage: lvm
  vgpattern: 'vg-nvme'
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

Ưu điểm so với local-path-provisioner:

- **Volume expansion** — resize PVC mà không cần recreate
- **Thin provisioning** — chỉ allocate disk thực sự khi ghi dữ liệu
- **Snapshot support** — LVM snapshots cho backup nhanh
- **Proper capacity tracking** — Kubernetes biết chính xác dung lượng còn lại

PVC dùng dynamic provisioning — không cần tạo PV thủ công.

> ⚠️ **HA Limitation:** OpenEBS LVM-LocalPV gắn PV trực tiếp vào node vật lý (`volumeBindingMode: WaitForFirstConsumer`). PV **không thể** được schedule sang node khác. Đây là blocker kỹ thuật quan trọng nhất khi scale sang multi-node cluster — phải migrate sang distributed storage (Longhorn hoặc Rook-Ceph) trước. Xem [Scale to HA — Giai đoạn 1](../runbooks/scale-to-ha.md#giai-đoạn-1--thêm-storage-layer-blocker-quan-trọng-nhất).

---

## Management

**Tailscale** cài trên server, cung cấp private mesh VPN để quản trị. SSH và `kubectl` truy cập qua Tailscale — không expose management ra internet.

| Thông số | Giá trị                                    |
| -------- | ------------------------------------------ |
| Cài trên | Server trực tiếp                           |
| Mục đích | SSH, kubectl khi cần truy cập trực tiếp    |
| Access   | Tailscale ACL (chỉ admin)                  |
| Cost     | Free tier (đủ cho single server + laptops) |

---

## Network

### Management Plane — Tailscale

- **Tailscale** cài trên server — private mesh VPN, không expose port nào ra internet.
- Admin truy cập SSH và `kubectl` qua Tailscale IP.

```
Admin Laptop
    │
    │ Tailscale (WireGuard, encrypted mesh)
    ▼
Server
    ├── SSH
    └── kubectl (K3s)
```

### Application Plane — Cloudflare Tunnel

- **Cloudflare Tunnel** dùng để expose apps ra internet qua `*.ecoma.io` — không cần public IP, không cần mở port.
- `cloudflared` chạy trong cluster (namespace `ingress`), thiết lập outbound-only tunnel tới Cloudflare edge.

```
User (internet)
    │
    │ HTTPS (*.ecoma.io)
    ▼
Cloudflare Edge (CDN, WAF, SSL termination)
    │
    │ Cloudflare Tunnel (encrypted, outbound-only)
    ▼
cloudflared pod (K3s, namespace ingress)
    │
    │ Cluster network
    ▼
Traefik Ingress → K8s Services
```

Chi tiết về URL routing và environments: xem [Environments](./environments.md).
