# Runbook: Rollback

## Khi nào rollback?

- Sau deploy mới xuất hiện lỗi trên production
- Health check thất bại sau deploy
- Có spike bất thường trên Grafana sau deploy

Mục tiêu: **khôi phục service trong dưới 5 phút**.

---

## Rollback nhanh qua ArgoCD (ưu tiên)

ArgoCD lưu lịch sử deployment. Rollback về revision trước mà không cần động vào Git.

```bash
# Xem lịch sử deploy
argocd app history ecoma-prod

# Rollback về revision cụ thể
argocd app rollback ecoma-prod <revision-id>

# Hoặc về revision trước nhất
argocd app rollback ecoma-prod
```

Qua ArgoCD UI: chọn app → **History and Rollback** → chọn revision → **Rollback**.

> **Lưu ý:** Sau rollback, ArgoCD sẽ ở trạng thái OutOfSync (vì Git vẫn có version mới). Cần fix code trong Git rồi merge lại mới sync tiếp.

---

## Rollback thủ công qua kubectl

Nếu ArgoCD không phản hồi:

```bash
# Xem lịch sử rollout
kubectl rollout history deployment/<app> -n ecoma-prod

# Rollback về revision trước
kubectl rollout undo deployment/<app> -n ecoma-prod

# Rollback về revision cụ thể
kubectl rollout undo deployment/<app> -n ecoma-prod --to-revision=<n>

# Theo dõi
kubectl rollout status deployment/<app> -n ecoma-prod
```

---

## Rollback database migration

> ⚠️ Database rollback phức tạp hơn và cần thực hiện cẩn thận.

Nếu version mới có migration không tương thích:

```bash
# 1. Scale down app trước
kubectl scale deployment/<app> --replicas=0 -n ecoma-prod

# 2. Chạy down migration (nếu có)
kubectl run migration-rollback --rm -it \
  --image=ghcr.io/ecoma/<app>:<old-tag> \
  --restart=Never \
  -- migrate down 1

# 3. Deploy lại version cũ
kubectl set image deployment/<app> <app>=ghcr.io/ecoma/<app>:<old-tag> -n ecoma-prod

# 4. Scale up lại
kubectl scale deployment/<app> --replicas=2 -n ecoma-prod
```

---

## Verify sau rollback

```bash
# Kiểm tra pods đang chạy
kubectl get pods -n ecoma-prod

# Kiểm tra image đang dùng
kubectl get deployment/<app> -n ecoma-prod -o jsonpath='{.spec.template.spec.containers[0].image}'

# Logs
kubectl logs -n ecoma-prod -l app=<app> --tail=30

# Health check
curl https://<app>.ecoma.io/health
```

---

## Sau khi rollback xong

1. Thông báo team về sự cố
2. Mở issue ghi lại nguyên nhân và timeline
