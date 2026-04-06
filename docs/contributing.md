# Contributing

Hướng dẫn đóng góp vào gitops repo.

## Branching Strategy

Giống source repo, dùng **Trunk-Based Development**.

### Quy tắc cơ bản

- **`main`** là nhánh duy nhất tồn tại lâu dài
- Feature branch sống tối đa **2 ngày**
- Mọi thay đổi vào `main` đều phải qua Pull Request

### Đặt tên branch

```
<type>/<short-description>

feat/add-sample-app-manifests
fix/postgresql-helm-values
chore/update-grafana-version
docs/update-runbook
ci/add-helm-validate
```

---

## Pull Request

- Tiêu đề PR theo format **Conventional Commits**: `feat(sample): add app manifests`
- **Squash merge** vào `main`
- CI phải pass (YAML validate, Helm lint) trước khi merge

---

## Commit Convention

Dùng [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>

feat(sample): add app base manifests
fix(postgresql): correct storage class in helm values
chore(argocd): update image updater version
docs(runbook): add database rollback steps
```

**Types:** `feat`, `fix`, `chore`, `docs`, `ci`, `refactor`

**Scope** (tuỳ chọn): tên service hoặc component — `postgresql`, `traefik`, `argocd`, `sample`, `coder`

---

## Lưu ý khi thay đổi

> Workflow chi tiết (thêm/sửa infra service, thêm Ecoma app, tạo SealedSecret): xem [Getting Started](./development/getting-started.md).

### Resource Requests & Limits

**Bắt buộc** với mọi workload trong các nhóm sau:

| Nhóm | Bắt buộc |
|---|---|
| `declarative/applications/` | Có — bắt buộc tuyệt đối |
| `declarative/infras/` | Có |
| `declarative/observability/` | Có |
| `declarative/tools/` | Có |
| `declarative/platform/` | Khuyến khích (vendor defaults thường đủ) |

Xem giá trị baseline trong [k8s-cluster.md — Resource Allocation](./infrastructure/k8s-cluster.md#resource-allocation-ước-tính) và chiến lược điều chỉnh trong [Resource Management](./infrastructure/resource-management.md).

### Infrastructure services

- Thay đổi trong folder tương ứng sẽ trigger ArgoCD sync tự động:
  - Core cluster infra: `declarative/platform/<service>/`
  - Monitoring/logging: `declarative/observability/<service>/`
  - Shared services: `declarative/infras/<service>/`
  - Developer tools: `declarative/tools/<service>/`
- Test Helm values locally: `helm template <chart> -f declarative/<group>/<service>/values.yaml`

### Application manifests

- Validate trước khi commit: `kubectl apply --dry-run=client -f declarative/applications/<app>/overlays/<env>/`
- Đảm bảo manifests hợp lệ trước khi push

### Secrets

- **KHÔNG BAO GIỜ** commit plain text secrets
- Luôn dùng `kubeseal` để tạo SealedSecret trước khi commit
- Xem [Getting Started](/development/getting-started) để biết cách tạo SealedSecret

---

## Branch Protection Rules (GitHub)

| Rule                       | Giá trị |
| -------------------------- | ------- |
| Require PR before merging  | ✅      |
| Required approvals         | 1       |
| Dismiss stale reviews      | ✅      |
| Require status checks (CI) | ✅      |
| Restrict force push        | ✅      |
| Auto delete head branch    | ✅      |
