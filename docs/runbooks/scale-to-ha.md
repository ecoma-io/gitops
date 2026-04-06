# Scale to HA — Lộ trình mở rộng sang High Availability

## Tổng quan

Tài liệu này mô tả lộ trình kỹ thuật để migrate hệ thống Ecoma từ **single-node K3s** sang **multi-node HA cluster** khi đến thời điểm cần thiết.

> **Xem điều kiện trigger tại:** [ADR-0001](../architecture/decisions/0001-single-node-with-ha-migration-path.md)

---

## Bức tranh tổng thể

```
Hiện tại (Single-Node)          →     Mục tiêu (Multi-Node HA)

┌─────────────────────┐               ┌─────────────────────────────────────┐
│  Server ecoma-01    │               │  Control Plane (3 nodes)            │
│  ├── K3s (SQLite)   │               │  ├── ecoma-cp-01 (K3s + etcd)       │
│  ├── All workloads  │               │  ├── ecoma-cp-02 (K3s + etcd)       │
│  ├── LVM NVMe/HDD   │               │  └── ecoma-cp-03 (K3s + etcd)       │
│  └── ALL storage    │               │                                     │
└─────────────────────┘               │  Worker Nodes (N nodes)             │
                                      │  ├── ecoma-wk-01 (apps)             │
                                      │  ├── ecoma-wk-02 (apps)             │
                                      │  └── ecoma-wk-0N (...)              │
                                      │                                     │
                                      │  Shared Storage                     │
                                      │  └── Longhorn hoặc Rook-Ceph        │
                                      └─────────────────────────────────────┘
```

---

## Thứ tự migration (quan trọng — phải theo đúng thứ tự)

### Giai đoạn 0 — Chuẩn bị (Không cần downtime)

1. **Kiểm tra backup hiện tại** trước khi bắt đầu bất kỳ thay đổi nào
2. **Mua/provision các server mới** (khuyến nghị: 3 server cho control-plane, tách biệt với worker nodes)
3. **Thiết lập network** giữa các servers (private network hoặc Tailscale mesh)
4. **Snapshot toàn bộ dữ liệu** trên server hiện tại

### Giai đoạn 1 — Thêm Storage layer (Blocker quan trọng nhất)

> ⚠️ **OpenEBS LVM-LocalPV là blocker kỹ thuật lớn nhất.** PV được gắn trực tiếp vào node vật lý, không thể schedule lại sang node khác. Phải giải quyết storage trước khi multi-node có ý nghĩa.

**Lựa chọn:**

| Option | Độ phức tạp | Hiệu năng | Chi phí |
|--------|------------|---------|--------|
| **Longhorn** | Thấp | Tốt | Thấp (open source) |
| **Rook-Ceph** | Cao | Rất tốt | Thấp (open source) |
| **Portworx** | Trung bình | Rất tốt | Cao (commercial) |

**Khuyến nghị cho Ecoma**: **Longhorn** — dễ cài qua Helm, UI trực quan, tích hợp tốt với K3s.

**Các bước thực hiện:**

```bash
# 1. Thêm storage nodes mới vào cluster TRƯỚC (không migrate data giữa nodes cũ)
# 2. Cài Longhorn qua Helm vào declarative/platform/longhorn/
# 3. Tạo StorageClass mới: longhorn-nvme, longhorn-hdd (thay thế nvme, hdd)

# 4. Migrate PVC từng service một (có downtime theo từng service):
#    PostgreSQL → scale down → backup → PVC migration → scale up
#    Redis → tương tự
#    NATS → tương tự
#    SeaweedFS → tương tự

# 5. Sau khi tất cả PVC đã migrate, OpenEBS LVM-LocalPV có thể bị thay thế
```

### Giai đoạn 2 — K3s HA Control Plane (Cần downtime ngắn)

Chuyển từ K3s single-node (SQLite) sang K3s HA (embedded etcd, 3 server nodes):

```bash
# Trên node hiện tại (sẽ trở thành node đầu tiên của HA cluster):
# Cần downtime ~10-15 phút để migrate SQLite → etcd

# Tham khảo: https://docs.k3s.io/datastore/ha-embedded
```

**Cấu hình K3s HA (3 server nodes):**

```bash
# Node 1 (khởi tạo cluster mới với embedded etcd)
curl -sfL https://get.k3s.io | K3S_TOKEN=<shared-token> sh -s - server \
  --cluster-init \
  --disable traefik \
  --disable local-storage \
  --disable servicelb \
  --disable metrics-server \
  --node-name ecoma-cp-01

# Node 2 và 3 (join vào cluster)
curl -sfL https://get.k3s.io | K3S_TOKEN=<shared-token> sh -s - server \
  --server https://ecoma-cp-01:6443 \
  --disable traefik \
  --disable local-storage \
  --disable servicelb \
  --disable metrics-server \
  --node-name ecoma-cp-02  # hoặc ecoma-cp-03
```

### Giai đoạn 3 — Scale Infrastructure Services

#### PostgreSQL (CloudNativePG)

Thay đổi duy nhất trong `declarative/infras/postgresql/cluster.yaml`:

```yaml
# Từ:
spec:
  instances: 1

# Sang:
spec:
  instances: 3
  # CloudNativePG tự quản lý: 1 primary + 2 replica
  # Automatic failover khi primary down
```

Sau khi thay đổi và commit, ArgoCD sẽ tự động scale. CloudNativePG tự bầu primary/replica.

#### Redis

Chọn một trong hai mode:

**Option A: Redis Sentinel** (Failover tự động, không phân tán reads)

Cập nhật `declarative/infras/redis/redis.values.yaml`:

```yaml
# Từ: architecture: standalone
architecture: replication
sentinel:
  enabled: true
  masterSet: ecoma-master
  quorum: 2
replica:
  replicaCount: 2
```

Internal DNS thay đổi: ứng dụng kết nối via Sentinel `redis.infra.svc.cluster.local:26379` thay vì `redis-master.infra.svc.cluster.local:6379`.

**Option B: Redis Cluster** (Scale reads + writes, phức tạp hơn)

```yaml
architecture: cluster
cluster:
  enabled: true
  slaveCount: 1  # 1 replica per shard
```

#### NATS JetStream

Cập nhật `declarative/infras/nats/nats.values.yaml`:

```yaml
# Từ: replicas: 1
replicaCount: 3

# Thêm cluster config:
nats:
  jetstream:
    enabled: true
    memStorage:
      enabled: true
      size: 1Gi
    fileStorage:
      enabled: true
      size: 10Gi
      storageType: nvme  # hoặc longhorn-nvme sau migration

cluster:
  enabled: true
  replicas: 3
```

#### SeaweedFS

Cập nhật `declarative/infras/seaweedfs/seaweedfs.values.yaml`:

```yaml
master:
  replicas: 3  # Raft quorum

volume:
  dataCenters:
    - name: dc1
      racks:
        - name: rack1
          volumes:
            - server: ""
              diskType: nvme
              index: leveldb
              replication: "001"  # 1 hot copy (2 total)

filer:
  replicas: 2
```

### Giai đoạn 4 — Scale Observability Stack

#### Mimir (Monolithic → Distributed)

Monolithic mode đủ cho workload nhỏ-vừa. Khi cần scale, chuyển sang distributed:

```yaml
# Trong mimir.values.yaml
mimir:
  structuredConfig:
    # Tách thành các component riêng biệt:
    # distributor, ingester, querier, store-gateway, compactor, ruler
```

> Tham khảo: https://grafana.com/docs/mimir/latest/references/architecture/

#### Loki (Monolithic → Distributed)

Tương tự Mimir — cùng Helm chart hỗ trợ cả hai mode:

```yaml
loki:
  deploymentMode: Distributed  # thay vì SingleBinary
```

#### Grafana

Grafana hiện dùng RWO PVC (1 pod). Khi scale:

1. Di chuyển sang PostgreSQL backend cho Grafana (thay vì file storage)
2. Xóa PVC constraint, bật `deploymentStrategy: RollingUpdate`
3. Scale lên `replicas: 2+`

### Giai đoạn 5 — Scale Stateless Application Services

Stateless apps (account, console, landing, token-hook) đã có pattern sẵn — chỉ cần cập nhật replica count trong prod overlay:

```yaml
# declarative/applications/<app>/overlays/prod/kustomization.yaml
patches:
  - target:
      kind: Deployment
      name: <app>
    patch: |-
      - op: replace
        path: /spec/replicas
        value: 2  # hoặc 3 tùy workload

  # Thêm anti-affinity để pods không chạy cùng node
  - target:
      kind: Deployment
    patch: |-
      - op: add
        path: /spec/template/spec/affinity
        value:
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

---

## Traefik — Load Balancer khi Multi-Node

Hiện tại Traefik trong ingress namespace nhận traffic từ Cloudflare Tunnel. Khi multi-node:

1. **Tăng Traefik replicas** lên 2+ (thêm PodAntiAffinity để spread across nodes)
2. **Cập nhật Cloudflare Tunnel** config để round-robin tới nhiều Traefik instances
3. Hoặc dùng **MetalLB / kube-vip** để tạo Virtual IP cho Traefik service

```yaml
# Trong traefik values:
deployment:
  replicas: 2
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          topologyKey: kubernetes.io/hostname
```

---

## Checklist Migration

```
Giai đoạn 0 — Chuẩn bị
  [ ] Backup đầy đủ (xem: rollback.md)
  [ ] Provision server mới
  [ ] Thiết lập network

Giai đoạn 1 — Storage Migration
  [ ] Cài Longhorn hoặc Rook-Ceph vào platform/
  [ ] Di chuyển PVC PostgreSQL
  [ ] Di chuyển PVC Redis
  [ ] Di chuyển PVC NATS
  [ ] Di chuyển PVC SeaweedFS (hot + cold)
  [ ] Di chuyển PVC Grafana
  [ ] Di chuyển PVC Prometheus
  [ ] Xác nhận tất cả workload hoạt động trên distributed storage
  [ ] Retire OpenEBS LVM-LocalPV

Giai đoạn 2 — K3s HA
  [ ] Thêm 2 server nodes mới
  [ ] Join nodes vào cluster (embedded etcd)
  [ ] Verify control-plane quorum (3 nodes)
  [ ] Kubernetes API vẫn accessible

Giai đoạn 3 — Infrastructure Scale
  [ ] PostgreSQL instances: 3
  [ ] Redis Sentinel hoặc Cluster mode
  [ ] NATS cluster: 3 replicas
  [ ] SeaweedFS: master replicas + volume replication

Giai đoạn 4 — Observability Scale
  [ ] Mimir: distributed mode (nếu cần)
  [ ] Loki: distributed mode (nếu cần)
  [ ] Grafana: PostgreSQL backend + replicas

Giai đoạn 5 — Application Scale
  [ ] Tất cả stateless apps: replicas >= 2 trong prod overlay
  [ ] Anti-affinity rules cho critical services
  [ ] Traefik replicas: 2+
  [ ] Load test sau khi scale
```

---

## Tham khảo

- [K3s Embedded etcd HA](https://docs.k3s.io/datastore/ha-embedded)
- [CloudNativePG Cluster Replicas](https://cloudnative-pg.io/documentation/current/cluster_conf/)
- [Longhorn](https://longhorn.io/docs/)
- [Rook-Ceph](https://rook.io/docs/rook/latest/Getting-Started/intro/)
- [NATS JetStream Clustering](https://docs.nats.io/running-a-nats-service/configuration/clustering)
- [Mimir Architecture](https://grafana.com/docs/mimir/latest/references/architecture/)
- [ADR-0001 — Quyết định single-node](../architecture/decisions/0001-single-node-with-ha-migration-path.md)
