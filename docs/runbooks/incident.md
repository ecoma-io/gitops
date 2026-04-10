# Runbook: Incident Response

## Severity Levels

| Level  | Mô tả                                       | Phản hồi     |
| ------ | ------------------------------------------- | ------------ |
| **P1** | Production down hoàn toàn                   | Ngay lập tức |
| **P2** | Tính năng chính bị ảnh hưởng, có workaround | < 30 phút    |
| **P3** | Tính năng phụ bị ảnh hưởng                  | < 4 giờ      |
| **P4** | Lỗi nhỏ, không ảnh hưởng người dùng         | Lên lịch fix |

---

## Quy trình xử lý sự cố

### 1. Phát hiện

Alerting qua Grafana/Alertmanager — check:

- Alert email/notification
- Grafana dashboard: https://grafana.ecoma.io
- Logs: Grafana → Explore → Loki

### 2. Triage (< 5 phút)

```bash
# Kiểm tra tổng quan cluster
kubectl get pods -A | grep -v Running

# Kiểm tra events gần đây
kubectl get events -n ecoma-prod --sort-by='.lastTimestamp' | tail -20

# Kiểm tra resource pressure
kubectl top nodes
kubectl top pods -n ecoma-prod
```

### 3. Cô lập nguyên nhân

**App bị crash:**

```bash
kubectl logs -n ecoma-prod -l app=<app> --previous --tail=100
kubectl describe pod <pod-name> -n ecoma-prod
```

**Database không kết nối được:**

```bash
kubectl exec -it -n infra deployment/postgresql -- psql -U postgres -c "\l"
```

**NATS không phản hồi:**

```bash
kubectl exec -it -n infra deployment/nats -- nats server check
```

**Disk pressure:**

```bash
# Kiểm tra trong VM
df -h
kubectl describe node ecoma-01 | grep -A5 "Conditions"

# Kiểm tra Proxmox thin pool (SSH vào Proxmox host)
# pvs, vgs — xết DATA% của thin pool trên host
```

### 4. Xử lý

| Triệu chứng                         | Hành động                                |
| ----------------------------------- | ---------------------------------------- |
| Pod CrashLoopBackOff sau deploy mới | [Rollback](./rollback.md) ngay           |
| Pod OOMKilled                       | Tăng memory limit tạm thời, điều tra sau |
| Database connection refused         | Restart PostgreSQL pod, kiểm tra PVC     |
| Disk full trên HDD                  | Xóa log cũ, archive backup offsite       |
| Cloudflare Tunnel down              | Restart `cloudflared` pod                |

```bash
# Restart pod khẩn cấp
kubectl rollout restart deployment/<app> -n ecoma-prod

# Restart cloudflared
kubectl rollout restart deployment/cloudflared -n ingress
```

### 5. Thông báo

Khi P1/P2, notify team ngay:

- Nêu rõ: **đang xảy ra gì**, **ảnh hưởng ai**, **đang xử lý bước nào**
- Cập nhật mỗi 15 phút cho đến khi giải quyết xong

### 6. Post-mortem

Sau khi resolve P1/P2, viết post-mortem trong vòng 24 giờ:

```markdown
## Post-mortem: <tiêu đề>

**Thời gian:** từ ... đến ...
**Severity:** P1/P2
**Ảnh hưởng:** ...
**Nguyên nhân gốc:** ...
**Timeline:** ...
**Action items:** ...
```
