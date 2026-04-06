# Resource Management — Requests & Limits

## Bối cảnh

Cluster single-node 24 vCPU / 48 GB RAM chạy toàn bộ infrastructure, observability, và application workloads. Không có auto-scaling theo chiều ngang (node) — resource contention trên một node duy nhất có thể cascade toàn bộ hệ thống. Cần có chiến lược rõ ràng để:

- Đảm bảo scheduler đặt pod đúng chỗ (requests)
- Bảo vệ node khỏi memory exhaustion (limits)
- Tránh lãng phí tài nguyên qua over-provisioning
- Có quy trình điều chỉnh dựa trên dữ liệu thực tế, không đoán

## Quyết định

### 1. CPU và Memory xử lý khác nhau

| | CPU | Memory |
|---|---|---|
| Tính chất | Compressible — throttle khi vượt limit | Incompressible — OOMKill khi vượt limit |
| Hệ quả vượt limit | Chậm lại (latency tăng) | Pod bị kill ngay lập tức |
| Request | Bắt buộc cho mọi container | Bắt buộc cho mọi container |
| Limit | Stateless apps: 3–4× request. Stateful DB: **không set** hoặc rất cao | Luôn set — không để unbounded |

> **Stateful services (PostgreSQL, Redis)**: không set CPU limit vì chúng tự quản lý concurrency và throttle gây query latency. Memory limit set cao (2–3× request) để có buffer, tránh OOM crash đột ngột.

### 2. Công thức xác định giá trị khởi điểm

Ưu tiên theo thứ tự:

1. **Vendor/chart recommendation** — xem `helm show values <chart> | grep -A5 resources`
2. **Bảng ước tính trong [k8s-cluster.md](./k8s-cluster.md)** — dùng làm baseline
3. **Quy tắc nhân** khi không có dữ liệu tốt hơn:

```
CPU request  = idle + 50% burst ước tính
CPU limit    = 3–4× CPU request  (stateless)
             = không set          (stateful DB)

Mem request  = working set bình thường (p50)
Mem limit    = 1.5–2× memory request
```

### 3. Quy trình theo dõi và điều chỉnh

**Tuần 1–2: Observe, không chỉnh**

Dùng kube-state-metrics + Prometheus để xem:

```promql
# CPU throttling ratio — mục tiêu < 25%
rate(container_cpu_cfs_throttled_seconds_total[5m])
/ rate(container_cpu_cfs_periods_total[5m])

# Memory saturation — mục tiêu < 80%
container_memory_working_set_bytes
/ container_spec_memory_limit_bytes
```

**Tuần 3+: Điều chỉnh theo tín hiệu**

| Tín hiệu | Hành động |
|---|---|
| CPU throttle > 25% liên tục | Tăng CPU limit 2× |
| Memory usage > 80% limit | Tăng memory limit 50% |
| Memory usage < 30% limit liên tục 2 tuần | Giảm limit về (actual × 1.3), không nhảy quá 50% một lần |
| OOMKilled | Tăng memory limit 2× ngay lập tức |

**Nguyên tắc "không giảm quá 50% trong một lần"** — tránh OOM do burst load không thường xuyên.

**Steady state: Dùng VPA Recommender**

Sau khi observability stack ổn định, deploy VPA ở mode `Off` (chỉ recommend):

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: my-service-vpa
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-service
  updatePolicy:
    updateMode: "Off"   # Recommend only, không tự thay đổi
```

Sau 24–48h:
```bash
kubectl describe vpa my-service-vpa
# → Lower Bound, Target, Upper Bound
```

Dùng `Target` làm request, `Upper Bound + 20%` làm limit. Commit vào gitops qua PR.

### 4. Bắt buộc và không bắt buộc

| Nhóm | Bắt buộc set | Ghi chú |
|---|---|---|
| `declarative/applications/` | **Có** | Ecoma apps — bắt buộc tuyệt đối, chạy chung namespace |
| `declarative/infras/` | **Có** | Shared services — bắt buộc |
| `declarative/observability/` | **Có** | Observability stack — bắt buộc |
| `declarative/tools/` | **Có** | Developer tools — bắt buộc |
| `declarative/platform/` | Khuyến khích | Vendor defaults thường hợp lý, chỉ ghi đè khi có vấn đề thực tế |

## Hệ quả khi áp dụng

**Tích cực:**
- Scheduler ra quyết định chính xác, tránh eviction
- Node không bị memory exhaustion dây chuyền
- Có dữ liệu để tối ưu dần — không over-provision từ đầu

**Tiêu cực:**
- Cần effort ban đầu để set values cho tất cả components
- Cần review định kỳ (đề xuất: hàng tháng) khi workload thay đổi
- VPA cần observability stack ổn định mới dùng được — không dùng được ngay từ đầu
