# ADR-0001: Single-Node K3s với lộ trình migration sang HA

## Trạng thái

Accepted

---

## Bối cảnh

Ecoma đang ở giai đoạn đầu (early-stage). Hệ thống cần chạy đầy đủ các thành phần infrastructure (PostgreSQL, Redis, NATS, SeaweedFS, Kratos, Hydra, Keto, toàn bộ observability stack) cùng với ứng dụng trên cùng một môi trường.

Các ràng buộc hiện tại:

- **Chi phí**: Budget cho infrastructure còn hạn chế. Chạy multi-node cluster đòi hỏi ít nhất 3 server (control-plane quorum) + chi phí networking giữa các nodes.
- **Team nhỏ**: Tổng chi phí vận hành (operational overhead) của HA cluster cao hơn đáng kể so với single-node.
- **SLA chưa cam kết**: Hệ thống chưa có SLA uptime chính thức với end-user. Downtime ngắn trong maintenance được chấp nhận.
- **Workload hiện tại**: Traffic thực tế chưa đủ để justify chi phí HA.

Tuy nhiên, kiến trúc phải được thiết kế để **migration sang HA không yêu cầu viết lại từ đầu** khi đến thời điểm cần.

---

## Quyết định

Triển khai toàn bộ hệ thống trên **một server vật lý duy nhất** chạy **K3s single-node** (SQLite datastore), sử dụng **OpenEBS LVM-LocalPV** cho persistent storage. ArgoCD quản lý toàn bộ qua GitOps pattern.

**Các quyết định đi kèm:**

| Thành phần | Quyết định hiện tại | Lý do |
|---|---|---|
| K3s datastore | SQLite (single-node default) | Đủ cho 1 node, không cần etcd cluster |
| Storage | OpenEBS LVM-LocalPV (`nvme`, `hdd`) | Hiệu năng tối đa trên local disk, chi phí thấp |
| PostgreSQL | `instances: 1` (CloudNativePG) | Single-node, scale lên 3 khi cần |
| Redis | Single-instance | Đủ cho dev/staging/prod giai đoạn đầu |
| NATS | `replicas: 1` | JetStream single-server |
| Stateless apps | `replicas: 1` base | Scale trong prod overlay khi cần |
| Observability | Monolithic mode (Mimir, Loki, Tempo) | Đơn giản hơn, đủ hiệu năng cho traffic hiện tại |

---

## Trigger để Migration sang HA

Migration phải được thực hiện khi **ít nhất một** trong các điều kiện sau xảy ra:

| # | Trigger | Ngưỡng |
|---|---|---|
| 1 | **Uptime SLA** được cam kết chính thức với khách hàng | SLA ≥ 99.9% (tương đương downtime tối đa ~8.7h/năm) |
| 2 | **Traffic production** đạt ngưỡng resource bottleneck | CPU sustained > 70% hoặc RAM > 80% trong peak hour liên tục > 1 tuần |
| 3 | **Revenue impact rõ ràng** khi hệ thống down | Mỗi giờ downtime gây thiệt hại > $X (tự định nghĩa) |
| 4 | **Maintenance downtime không chấp nhận được** | Team không thể chấp nhận cửa sổ downtime cho OS upgrade, disk replacement |
| 5 | **Data loss risk** trở thành vấn đề nghiêm trọng | Có dữ liệu production quan trọng mà single-point-of-failure là không thể chấp nhận |

---

## Hệ quả

### Tích cực (hiện tại)

- Chi phí cơ sở hạ tầng thấp hơn đáng kể (1 server vs 3+ servers).
- Đơn giản hơn trong vận hành, debug, và troubleshooting.
- Hiệu năng local disk tối đa — không có network latency giữa storage và compute.
- Toàn bộ cấu hình được GitOps quản lý, sẵn sàng migration bất kỳ lúc nào.

### Tiêu cực — SPOF (Single Point of Failure)

- **Một server down = toàn bộ hệ thống down** — bao gồm production.
- **Maintenance = Planned Downtime** — OS updates, kernel patches, disk replacement đều yêu cầu shutdown K3s.
- **Không có rolling update** cho infrastructure components.
- **Disk failure = data loss risk** nếu không có off-site backup.

### Thiết kế để sẵn sàng scale (HA Readiness)

Dù chạy single-node, kiến trúc đã được thiết kế có chủ ý để dễ migration:

- **GitOps-first**: Toàn bộ config trong Git → có thể deploy lại trên cluster mới trong vài giờ.
- **CloudNativePG**: `instances: 1` → `instances: 3` chỉ cần thay 1 dòng trong `cluster.yaml`.
- **Stateless app replicas**: `replicas: 1` trong base overlay, dễ scale lên qua patch trong prod overlay.
- **Observability monolithic → distributed**: Mimir, Loki, Tempo đều hỗ trợ distributed mode qua cùng Helm chart.
- **OpenEBS LVM-LocalPV là blocker lớn nhất**: Khi multi-node, phải migrate sang distributed storage (Longhorn hoặc Rook-Ceph) trước khi có thể schedule workload trên nhiều nodes. Đây là bước tốn công nhất.

Xem chi tiết lộ trình: [Scale to HA Runbook](../../runbooks/scale-to-ha.md).

---

## Các phương án đã xem xét

### Phương án A: Multi-node K3s ngay từ đầu (3 server nodes)

- **Ưu**: HA ngay từ đầu, không cần migration sau.
- **Nhược**: Chi phí gấp 3x, overhead vận hành cao hơn, phức tạp hơn khi debug.
- **Lý do không chọn**: Không justify được chi phí ở giai đoạn early-stage.

### Phương án B: Cloud-managed Kubernetes (EKS, GKE, AKS)

- **Ưu**: Managed control-plane, built-in HA, auto-scaling.
- **Nhược**: Chi phí cao hơn nhiều, vendor lock-in, data egress cost.
- **Lý do không chọn**: Chi phí không phù hợp với giai đoạn hiện tại.

### Phương án C (đã chọn): Single-node K3s với HA readiness design

- Chi phí thấp nhất, đủ cho giai đoạn đầu.
- Kiến trúc có chủ đích để migration sang HA trong tương lai không quá tốn công.
