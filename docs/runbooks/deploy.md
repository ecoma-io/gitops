# Runbook: Deploy

## Deploy bình thường (qua CI/CD)

Trong hầu hết trường hợp, **không cần làm gì thủ công** cho đến bước promote:

1. Mở PR trong source repo → preview environment tự deploy, test trên preview
2. Merge PR vào `main`
3. GitHub Actions chạy `release.yml` → build + push image lên ghcr.io
4. ArgoCD Image Updater detect image mới → cập nhật image tag
5. Promote lên `staging` (thủ công)
6. Confirm stakeholder trên `staging`
7. Promote lên `prod` (thủ công, cần approval)

---

## Promote lên Staging

```bash
# Kiểm tra trạng thái hiện tại
argocd app get ecoma-staging

# Sync (promote)
argocd app sync ecoma-staging

# Theo dõi tiến trình
argocd app wait ecoma-staging --health
```

Hoặc qua ArgoCD UI: chọn app `ecoma-staging` → **Sync** → **Synchronize**.

---

## Promote lên Production

> ⚠️ Luôn kiểm tra staging trước. Không promote thẳng lên prod từ dev.

```bash
# 1. Confirm staging healthy
argocd app get ecoma-staging

# 2. Tạo approval trên GitHub (nếu cần)
# Vào GitHub → Actions → approve workflow

# 3. Sync prod
argocd app sync ecoma-prod

# 4. Theo dõi
argocd app wait ecoma-prod --health

# 5. Verify
kubectl get pods -n ecoma-prod
kubectl rollout status deployment/<app> -n ecoma-prod
```

---

## Deploy thủ công (bypass CI)

Chỉ dùng trong trường hợp khẩn cấp khi CI bị hỏng.

```bash
# 1. Build image local
docker build -t ghcr.io/ecoma/<app>:<tag> apps/<app>/

# 2. Push
docker push ghcr.io/ecoma/<app>:<tag>

# 3. Cập nhật image tag trong manifest
kubectl set image deployment/<app> <app>=ghcr.io/ecoma/<app>:<tag> -n ecoma-prod

# 4. Tắt ArgoCD auto-sync tạm thời để tránh bị revert
argocd app patch ecoma-prod --patch '{"spec":{"syncPolicy":null}}' --type merge
```

> Sau khi xong, nhớ commit image tag đúng vào Git và re-enable ArgoCD sync.

---

## Kiểm tra sau deploy

```bash
# Pod status
kubectl get pods -n ecoma-prod

# Logs gần đây
kubectl logs -n ecoma-prod -l app=<app-name> --tail=50

# Health check endpoint
curl https://<app>.ecoma.io/health
```
