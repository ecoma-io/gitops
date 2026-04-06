# Environments

## Tổng quan

Hệ thống có 4 loại môi trường chạy trên K3s cluster, phân tách bằng Kubernetes namespace.

| Môi trường | Namespace              | Trigger Deploy                       | Cần Approval    |
| ---------- | ---------------------- | ------------------------------------ | --------------- |
| `dev`      | `ecoma-dev-{username}` | Developer tạo workspace qua Coder UI | Không           |
| `preview`  | `ecoma-preview-{pr}`   | Auto — mở Pull Request               | Không           |
| `staging`  | `ecoma-staging`        | Manual promote từ `preview`          | Không           |
| `prod`     | `ecoma-prod`           | Manual promote từ `staging`          | Có (1 reviewer) |

---

## Dev

- Mục đích: cung cấp workspace riêng biệt cho mỗi developer, code trực tiếp trên server qua Coder
- Developer tạo workspace qua Coder UI → Coder chạy Terraform template → namespace + workspace pod sẵn sàng trong ~1 phút
- App code chạy trên server (trong workspace pod), kết nối trực tiếp đến infra services qua cluster network — không cần VPN hay tunnel
- Tất cả backend services chạy trong workspace pod, dùng Nx serve với hot reload
- Migration/database lỗi của dev A không ảnh hưởng dev B vì mỗi dev có database riêng (logical isolation)

| Thành phần | Chi tiết                                                             |
| ---------- | -------------------------------------------------------------------- |
| Namespace  | `ecoma-dev-{username}`                                               |
| Workspace  | Coder workspace pod (VS Code server + Node.js + pnpm)                |
| Database   | Shared PostgreSQL instance, per-dev databases (ecoma, kratos, hydra) |
| Redis      | Shared Redis instance, per-dev DB number                             |
| NATS       | Shared instance, per-dev subject prefix (`dev.{username}.`)          |
| Kratos     | Chạy trong workspace pod, kết nối per-dev database                   |
| Hydra      | Chạy trong workspace pod, kết nối per-dev database                   |
| Mailpit    | Shared (chỉ test email)                                              |
| App code   | Chạy trong workspace pod trên server                                 |

### NATS Subject Isolation

Mỗi dev environment dùng subject prefix riêng để tránh events xung đột:

```
dev.alice.order.created     ← events của alice
dev.bob.order.created       ← events của bob
```

Tất cả services đọc env var `NATS_SUBJECT_PREFIX` để tự thêm prefix khi publish/subscribe.

### mirrord — Traffic Intercept cho Service Đang Sửa

Với monorepo nhiều services, developer thường chỉ sửa 1-2 service tại một thời điểm. **mirrord** cho phép chạy service đó trong workspace nhưng intercept traffic thật từ cluster, thay vì phải khởi động toàn bộ stack.

```
                  ┌─────────────────────────────────┐
                  │  Cluster (shared infrastructure) │
                  │                                  │
  Request ───────►│  Service A (running in cluster)  │
                  │  Service B (running in cluster)  │
                  │       │                          │
                  │       │ traffic mirror/steal      │
                  └───────┼──────────────────────────┘
                          │
                          ▼
              ┌───────────────────────┐
              │  Workspace pod        │
              │  Service B (dev code) │  ← đang được sửa
              │  Nx serve + hot reload│
              └───────────────────────┘
```

**Cách dùng:**

```bash
# Chạy service đang sửa với mirrord, intercept traffic từ cluster
mirrord exec --target deployment/ecoma-service-b -- nx serve service-b
```

mirrord đã được cấu hình sẵn trong Coder workspace template (`~/.mirrord/mirrord.json`). Dev không cần cấu hình thêm.

**Khi nào dùng mirrord:**
- Test integration với các service khác mà không cần spin up toàn bộ stack
- Debug request thật từ staging đang đổ vào service cần sửa
- Không dùng khi chỉ cần unit test hoặc test isolated logic

---

## Preview

- Mục đích: full-system test trước khi merge — toàn bộ services chạy đúng version của feature branch
- Tự động tạo khi mở Pull Request, tự động xóa khi PR đóng
- Namespace: `ecoma-preview-{pr-number}` (ví dụ: `ecoma-preview-42`)
- Dữ liệu: seed data tối thiểu, isolated hoàn toàn
- URL: `https://pr{pr-number}.ecoma.io` (ví dụ: `https://pr42.ecoma.io`)
- Đây là nơi developer manual test toàn bộ event-driven flow trước khi merge

---

## Staging

- Mục đích: kiểm thử tích hợp, UAT (User Acceptance Testing)
- Deploy thủ công sau khi `preview` đã được review và approve
- Dữ liệu: gần giống production (anonymized), **không reset tự động**
- Dùng để demo nội bộ và sign-off trước khi lên prod

---

## Production

- Mục đích: phục vụ người dùng thực
- Deploy thủ công, yêu cầu approval từ ít nhất 1 người
- Dữ liệu: production data thực, snapshot 1h/lần
- Backup: VPS snapshot tự động mỗi 1 giờ do nhà cung cấp
- Rollback: ArgoCD hỗ trợ rollback về revision trước trong vòng 30 giây

---

## Khác biệt cấu hình giữa các môi trường

| Config          | dev                                | preview                  | staging                  | prod                     |
| --------------- | ---------------------------------- | ------------------------ | ------------------------ | ------------------------ |
| Replica count   | 1                                  | 1                        | 1                        | 2+                       |
| Resource limits | Thấp                               | Thấp                     | Trung bình               | Cao                      |
| Log level       | `debug`                            | `debug`                  | `info`                   | `warn`                   |
| Database        | Shared instance, per-dev DB        | Dedicated schema         | Dedicated DB             | Dedicated DB             |
| Redis           | Shared instance, per-dev DB number | Dedicated                | Dedicated                | Dedicated                |
| NATS            | Shared, subject prefix             | Dedicated                | Dedicated                | Dedicated                |
| Email           | Mailpit                            | Mailpit                  | Brevo sandbox            | Brevo live               |
| TLS             | Cloudflare (qua Coder)             | Cloudflare (TLS at edge) | Cloudflare (TLS at edge) | Cloudflare (TLS at edge) |

---

## URL Routing

Tất cả traffic đi qua Cloudflare Tunnel. Domain: `ecoma.io`. Chỉ dùng single-level subdomain (để Cloudflare Universal SSL wildcard `*.ecoma.io` cover được).

### Public apps

| Hostname                   | Service | Environment |
| -------------------------- | ------- | ----------- |
| `ecoma.io`                     | Landing  | prod        |
| `account.ecoma.io`             | Accounts | prod        |
| `console.ecoma.io`             | Console  | prod        |
| `staging.ecoma.io`             | Landing  | staging     |
| `staging-account.ecoma.io`     | Accounts | staging     |
| `staging-console.ecoma.io`     | Console  | staging     |
| `pr{N}.ecoma.io`               | Landing  | preview     |
| `pr{N}-account.ecoma.io`       | Accounts | preview     |
| `pr{N}-console.ecoma.io`       | Console  | preview     |

### Platform tools

| Hostname              | Service  | Authentication          |
| --------------------- | -------- | ----------------------- |
| `coder.ecoma.io`      | Coder    | GitHub OAuth (built-in) |
| `argocd.ecoma.io`     | ArgoCD   | Built-in auth           |
| `grafana.ecoma.io`    | Grafana  | Built-in auth           |
| `mailpit.ecoma.io`    | Mailpit  | Cloudflare Zero Trust   |

> Các platform tools đã có authentication riêng, không cần Cloudflare Zero Trust — ngoại trừ Mailpit cần bảo vệ thêm vì không có auth built-in.

### Cloudflare Zero Trust Access

Staging và preview URLs chứa pre-release code — không nên expose public. Dùng **Cloudflare Zero Trust Access** để giới hạn truy cập:

| Pattern             | Bảo vệ URLs                                                            | Policy                         |
| ------------------- | ---------------------------------------------------------------------- | ------------------------------ |
| `staging*.ecoma.io` | `staging.ecoma.io`, `staging-account.ecoma.io`, `staging-console.ecoma.io` | Chỉ GitHub org `ecoma` members |
| `pr*.ecoma.io`      | `pr{N}.ecoma.io`, `pr{N}-account.ecoma.io`, `pr{N}-console.ecoma.io`       | Chỉ GitHub org `ecoma` members |

Cấu hình qua Cloudflare dashboard (thủ công bởi admin).

### Cloudflare DNS

Chỉ cần 2 DNS records (cấu hình qua Cloudflare dashboard):

| Type  | Name         | Target    |
| ----- | ------------ | --------- |
| CNAME | `ecoma.io`   | tunnel ID |
| CNAME | `*.ecoma.io` | tunnel ID |

---

## Secret Management

Secret được quản lý bằng **Kubernetes Secrets** + **Sealed Secrets** (sealed bằng public key, lưu trong Git an toàn).

```
# App secrets — co-located với app manifests
declarative/applications/<app>/overlays/{env}/secrets/   # SealedSecret của từng app (encrypted, safe to commit)

# Infra secrets — co-located với service manifests
declarative/infras/<service>/sealed-secret.yaml          # SealedSecret cho infra services (PostgreSQL, NATS, ...)
declarative/platform/<service>/sealed-secret.yaml        # SealedSecret cho platform services (cloudflared, ...)
```

Private key của Sealed Secrets chỉ tồn tại trong cluster, không commit vào Git.
