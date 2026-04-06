# Ory Kratos — Identity & User Management

## Tổng quan

**Ory Kratos** là Identity Management System, xử lý đăng ký, đăng nhập, 2FA, recovery, và verification cho toàn bộ hệ thống.

| Thông tin     | Chi tiết                                                  |
| ------------- | --------------------------------------------------------- |
| Namespace     | `infra`                                                   |
| Public API    | `kratos-public.infra.svc.cluster.local:80`                |
| Admin API     | `kratos-admin.infra.svc.cluster.local:80`                 |
| Database      | PostgreSQL — database `kratos`                            |
| SMTP          | `mailpit-smtp.infra.svc.cluster.local:25`                 |
| Helm chart    | `ory/kratos` — được deploy qua kustomize + helmCharts     |

---

## Identity Schema

Mỗi identity có hai traits:

| Trait      | Type   | Required | Unique | Dùng để đăng nhập |
| ---------- | ------ | -------- | ------ | ----------------- |
| `email`    | string | Có       | Có     | Có                |
| `username` | string | Có       | Có     | Có                |

- **Cả hai đều là credential identifier** → user có thể đăng nhập bằng email hoặc username
- Kratos tự enforce uniqueness qua bảng `identity_credential_identifiers`
- `username` chỉ chấp nhận ký tự `[a-zA-Z0-9_-]`, độ dài 3–50

---

## 2FA — Xác thực Hai Yếu Tố

Các phương thức 2FA được bật:

| Phương thức      | Mô tả                                                                   |
| ---------------- | ----------------------------------------------------------------------- |
| **TOTP**         | Time-based OTP — Google Authenticator, Authy, etc. Issuer: `Ecoma`     |
| **WebAuthn**     | FIDO2/Passkey dùng làm 2FA (không phải passwordless). RP: `ecoma.io`   |
| **Email OTP**    | Mã một lần gửi qua email, hiệu lực 15 phút                              |
| **Lookup Secret**| Backup recovery codes khi mất thiết bị 2FA                             |

> Kratos áp dụng AAL (Authentication Assurance Level) tự động: sau khi user enroll TOTP hoặc WebAuthn, các luồng yêu cầu AAL2 sẽ bắt buộc 2FA.

---

## Admin User Seeding

### Cơ chế

Một ArgoCD `PostSync` hook Job (`kratos-seed`) chạy sau mỗi lần sync/upgrade để đảm bảo tài khoản admin tồn tại.

**Logic idempotent:**
1. Gọi `GET /admin/identities?credentials_identifier=admin@ecoma.io`
2. Nếu không tìm thấy → tạo mới bằng `POST /admin/identities`
3. Nếu đã có → log "skipping", exit 0 (Job thành công, không tạo lại)

### Thông tin đăng nhập ban đầu

| Field    | Giá trị         |
| -------- | --------------- |
| Email    | admin@ecoma.io  |
| Username | admin           |
| Password | `Admin123@`     |

> ⚠️ **Đổi mật khẩu ngay sau lần đăng nhập đầu tiên.** Password lưu plaintext trong `seed-job.yaml` vì đây là giá trị tạm thời dự định thay đổi.

### Cách đổi mật khẩu admin

Qua Kratos Admin API:

```bash
# Lấy identity ID
IDENTITY_ID=$(curl -s http://kratos-admin.infra.svc.cluster.local:80/admin/identities?credentials_identifier=admin@ecoma.io \
  | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

# Cập nhật password
curl -X PUT "http://kratos-admin.infra.svc.cluster.local:80/admin/identities/$IDENTITY_ID" \
  -H "Content-Type: application/json" \
  -d '{
    "schema_id": "default",
    "traits": { "email": "admin@ecoma.io", "username": "admin" },
    "credentials": { "password": { "config": { "password": "NewPassword123@" } } }
  }'
```

---

## Database Init

Kratos tự tạo database `kratos` nếu chưa có thông qua initContainer `db-init` khi deployment khởi động. Auto-migration chạy trong initContainer `kratos-automigration` trước khi container chính start — đảm bảo schema luôn up to date sau upgrade.

---

## Cấu hình Helm Chart

File cấu hình: [declarative/infras/kratos/kratos.values.yaml](../../declarative/infras/kratos/kratos.values.yaml)

Kustomization: [declarative/infras/kratos/kustomization.yaml](../../declarative/infras/kratos/kustomization.yaml)

Sealed Secret (database URL): [declarative/infras/kratos/sealed-secret.yaml](../../declarative/infras/kratos/sealed-secret.yaml)

Seed Job: [declarative/infras/kratos/seed-job.yaml](../../declarative/infras/kratos/seed-job.yaml)
