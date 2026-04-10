# Hardware

## Máy chủ vật lý

Toàn bộ hệ thống Ecoma chạy trên một **máy chủ vật lý on-premise** cài **Proxmox VE**. K3s cluster chạy bên trong một **VM** được tạo trên Proxmox — không phải trực tiếp trên bare metal.

> ⚠️ **SPOF (Single Point of Failure):** Toàn bộ hệ thống — bao gồm production — phụ thuộc vào một máy chủ vật lý duy nhất. Server down = hệ thống down. Đây là quyết định có chủ ý ở giai đoạn early-stage. Xem [ADR-0001](../architecture/decisions/0001-single-node-with-ha-migration-path.md) để hiểu bối cảnh và [Scale to HA Runbook](../runbooks/scale-to-ha.md) để biết lộ trình khi cần mở rộng.

### Phần cứng vật lý (Proxmox host)

| Thành phần     | Chi tiết                                                            |
| -------------- | ------------------------------------------------------------------- |
| **CPU**        | Intel Xeon E5-2680v4                                                |
| **RAM vật lý** | 32 GB                                                               |
| **OS**         | Debian 12 + Proxmox VE                                              |
| **SSD 1**      | KINGSTON SA400S37120G — 111.8 GB (`sda`) — root Proxmox             |
| **SSD 2**      | faspeed K5-128G — 119.2 GB (`sdb`) — dự phòng / VM root thin LVM   |
| **NVMe 1**     | SAMSUNG MZVLB512HBJQ — 476.9 GB (`nvme0n1`) — thin LVM NVMe pool   |
| **NVMe 2**     | SAMSUNG MZVLB512HBJQ — 476.9 GB (`nvme1n1`) — thin LVM NVMe pool   |
| **HDD 1**      | TOSHIBA HDWT360 — 5.5 TB (`sdc`) — thin LVM HDD pool               |
| **HDD 2**      | TOSHIBA HDWT360 — 5.5 TB (`sdd`) — thin LVM HDD pool               |
| **zswap**      | zstd compression, 50% RAM (~16 GB) — cho phép overcommit RAM cho VM |

### Proxmox host config

| Thành phần        | Chi tiết                                                                                                    |
| ----------------- | ----------------------------------------------------------------------------------------------------------- |
| **Tailscale**     | Cài trên Proxmox host — quảng bá subnet `192.168.168.0/24` vào Tailscale mesh                              |
| **Truy cập**      | SSH vào Proxmox host và vào VM ecoma đều qua Tailscale (không expose port ra internet)                      |
| **ZSwap**         | zstd, 50% RAM pool — cho phép VM được cấp 48 GB RAM trên host 32 GB vật lý                                  |
| **Thin LVM Pool** | Proxmox tạo 3 thin pool: `nvme` (2×476.9 GB NVMe), `hdd` (2×5.5 TB), `ssd` (119.2 GB SSD cho VM root)     |

### VM ecoma (chạy K3s)

VM ecoma là nơi toàn bộ K3s cluster và workloads vận hành.

| Thành phần    | Chi tiết                                        |
| ------------- | ----------------------------------------------- |
| **vCPU**      | 24 vCPU (overcommit từ CPU vật lý)              |
| **RAM**       | 48 GB (overcommit — host vật lý 32 GB + ZSwap)  |
| **OS Disk**   | ~120 GB (thin LVM từ pool SSD — root `/`)        |
| **Data NVMe** | ~430 GB (thin LVM từ pool NVMe)                  |
| **HDD**       | ~11 TB (thin LVM từ pool HDD — 2×5.5 TB)        |
| **OS**        | Debian 12                                        |

> **Thin LVM overcommit**: Proxmox sử dụng thin provisioning — disk cấp cho VM không chiếm ngay phần vật lý tương ứng. Cần monitor **thin pool usage tại Proxmox host**, không chỉ `df` trong VM, để tránh pool exhaustion bất ngờ.

---

## Kiến trúc

```
┌────────────────────────────────────────────────────────────────────┐
│  Máy chủ vật lý (on-premise)                                       │
│  Intel Xeon E5-2680v4 / 32 GB RAM                                  │
│  Proxmox VE + ZSwap (zstd, 50% RAM)                                │
│                                                                    │
│  ├── Tailscale (quảng bá 192.168.168.0/24 vào mesh VPN)            │
│  │                                                                  │
│  └── VM: ecoma (24 vCPU / 48 GB RAM / Debian 12)                   │
│      │                                                              │
│      ├── K3s cluster                                                │
│      │   └── Tất cả workload (apps, infra services, monitoring)     │
│      │                                                              │
│      ├── Data NVMe (~430 GB) → LVM VG vg-nvme → OpenEBS PVCs       │
│      └── HDD (~11 TB) → LVM VG vg-hdd → OpenEBS PVCs               │
└────────────────────────────────────────────────────────────────────┘
```

---

## Storage — LVM

Trong VM ecoma, hai disk data được setup thành LVM Volume Groups độc lập. **OpenEBS LVM-LocalPV** tự động tạo Logical Volume cho mỗi PVC theo StorageClass tương ứng.

| Disk (trong VM) | Kích thước | LVM VG    | StorageClass K8s | Workload                                             |
| --------------- | ---------- | --------- | ---------------- | ---------------------------------------------------- |
| OS Disk (`/`)   | ~120 GB    | —         | —                | Debian OS, K3s binaries, runtime                     |
| Data NVMe       | ~430 GB    | `vg-nvme` | `nvme` (default) | PostgreSQL, Redis, NATS, SeaweedFS metadata/hot tier |
| HDD             | ~11 TB     | `vg-hdd`  | `hdd`            | SeaweedFS cold tier, backups                         |

> Disk VM được thin-provision từ Proxmox LVM pool: NVMe pool (2×476.9 GB = ~953 GB), HDD pool (2×5.5 TB = ~11 TB). Dung lượng được tính toán để không overcommit so với pool vật lý, đảm bảo K3s nhận biết chính xác **disk pressure**.

### Setup LVM (trong VM)

```bash
# Data NVMe (device /dev/vdb hoặc /dev/sdb tuỳ Proxmox VirtIO config)
pvcreate /dev/vdb
vgcreate vg-nvme /dev/vdb

# HDD (device /dev/vdc hoặc /dev/sdc)
pvcreate /dev/vdc
vgcreate vg-hdd /dev/vdc
```

> **OpenEBS LVM-LocalPV** sẽ tự tạo Logical Volume cho mỗi PVC — không cần tạo LV thủ công.

### Mở rộng khi đầy

| Điều kiện     | Hành động                                                                                                     |
| ------------- | ------------------------------------------------------------------------------------------------------------- |
| `vg-nvme` đầy | Mở rộng disk NVMe trong Proxmox → resize VM disk → `pvresize /dev/vdb; vgextend vg-nvme /dev/vdb`             |
| `vg-hdd` đầy  | Mở rộng disk HDD trong Proxmox → resize VM disk → `pvresize /dev/vdc; vgextend vg-hdd /dev/vdc`               |

### StorageClasses (Kubernetes)

LVM Volume Groups được expose vào Kubernetes qua **OpenEBS LVM-LocalPV** dưới dạng StorageClasses:

| StorageClass     | LVM VG    | Kích thước | Dùng cho                                             |
| ---------------- | --------- | ---------- | ---------------------------------------------------- |
| `nvme` (default) | `vg-nvme` | ~430 GB    | PostgreSQL, Redis, NATS, SeaweedFS metadata/hot tier |
| `hdd`            | `vg-hdd`  | ~11 TB     | SeaweedFS cold tier, backups                         |

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

**Tailscale** cài trên **Proxmox host**, quảng bá subnet nội bộ `192.168.168.0/24` vào Tailscale mesh. Truy cập vào cả Proxmox host lẫn VM ecoma đều qua Tailscale — không expose management ra internet.

| Thông số  | Giá trị                                                        |
| --------- | -------------------------------------------------------------- |
| Cài trên  | Proxmox host (không phải trong VM)                             |
| Subnet    | `192.168.168.0/24` — quảng bá vào Tailscale                    |
| Mục đích  | SSH vào Proxmox, SSH vào VM ecoma, kubectl, Proxmox Web UI     |
| Access    | Tailscale ACL (chỉ admin)                                      |
| Cost      | Free tier (đủ cho single server + laptops)                     |

---

## Network

### Management Plane — Tailscale

- **Tailscale** cài trên **Proxmox host** — quảng bá subnet `192.168.168.0/24` vào mesh VPN, không expose port nào ra internet.
- Admin truy cập Proxmox Web UI, SSH Proxmox host, SSH VM ecoma, và `kubectl` đều qua Tailscale.

```
Admin Laptop
    │
    │ Tailscale (WireGuard, encrypted mesh)
    ▼
Proxmox Host (192.168.168.x qua Tailscale)
    ├── SSH (Proxmox host)
    ├── Proxmox Web UI (:8006)
    └── VM ecoma (192.168.168.x)
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

---

## Backup Server

Để đảm bảo an toàn dữ liệu trong giai đoạn 1, hệ thống có một **máy chủ backup vật lý riêng** chạy **Proxmox Backup Server (PBS)**.

| Thành phần     | Chi tiết                                             |
| -------------- | ---------------------------------------------------- |
| **CPU**        | Intel Celeron J1900                                  |
| **RAM**        | 8 GB                                                 |
| **OS Disk**    | SSD 16 GB (root PBS)                                 |
| **Data SSD**   | SSD 256 GB                                           |
| **HDD 1**      | HDD 6 TB                                             |
| **HDD 2**      | HDD 6 TB                                             |
| **Phần mềm**   | Proxmox Backup Server                                |
| **Kết nối**    | Qua mạng nội bộ + Tailscale (off-host access)        |

**Chiến lược backup:**
- Proxmox trên server chính tự động backup VM ecoma sang PBS theo lịch
- PBS deduplication + compression giảm đáng kể dung lượng lưu trữ
- Off-host backup đảm bảo an toàn ngay cả khi server chính lỗi phần cứng hoàn toàn

---

## Lộ trình scale dọc (Vertical Scaling)

Trước khi cần scale ngang (HA multi-node), hệ thống có thể được mở rộng theo chiều dọc khi cần:

| Nhu cầu             | Hành động                                                   | Kết quả                          |
| ------------------- | ----------------------------------------------------------- | -------------------------------- |
| Thiếu RAM           | Thêm 64 GB RAM vật lý (nâng từ 32 GB → 96 GB)              | VM có thể được nâng lên ~144 GB với ZSwap |
| Thiếu CPU           | Thay CPU 2680v4 → 2697v4 (14c→18c)                         | Tăng vCPU có thể cấp cho VM      |
| Thiếu NVMe          | Thêm NVMe vào pool Proxmox → resize VM disk → resize `vg-nvme` | Mở rộng không downtime            |
| Thiếu HDD           | Thêm HDD vào pool Proxmox → resize VM disk → resize `vg-hdd`  | Mở rộng không downtime            |

> Giai đoạn kinh doanh thực tế: upgrade lên máy chủ vật lý mạnh hơn nhưng vẫn giữ Proxmox để dễ migrate VM liền mạch.
