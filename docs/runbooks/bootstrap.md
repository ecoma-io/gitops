# Runbook: Cluster Bootstrap

Tài liệu này hướng dẫn cách thực hiện bootstrap lần đầu tiên (hoặc khi cần cài đặt lại toàn bộ cluster) cho hệ thống GitOps. Quá trình bootstrap sử dụng script `bootstrap.sh` tại root của repo để:

1. Verify và inject Sealed Secrets key pair vào cluster.
2. Cài đặt Sealed Secrets controller (direct URL, vào `kube-system`).
3. Cài đặt Traefik CRDs (direct URL, để ArgoCD có thể quản lý IngressRoute resources).
4. Cài đặt ArgoCD (direct URL, vào namespace `argocd`).
5. Cài đặt Prometheus Operator CRDs (direct URL, để kube-prometheus-stack có thể deploy).
6. Apply `platform-appset` scan `declarative/platform/*/config.json`. ArgoCD sync `declarative/platform/argocd/` trước (syncWave -10), adopt lại AppSet, sau đó tạo các AppSet còn lại cho `observability`, `infras`, `tools`, và `applications`.

---

## 1. Yêu cầu chuẩn bị (Prerequisites)

- Node cluster đã cài đặt xong K3s (Outcome từ Sprint 1).
- `kubectl` cluster admin config sẵn sàng (chạy được `kubectl get nodes` ra trạng thái Ready).
- Đã cài đặt `openssl` và `base64` ở máy chạy script (dùng để verify key pair).
- File `sealed-secrets.cert` (Public Key) đã commit trong repo root.
- File `sealed-secrets.key` (Private Key) đặt tại repo root — lấy từ Password Manager. **KHÔNG BAO GIỜ commit file này.**

---

## 2. Chuẩn bị Key Pair của Sealed Secrets

Repo chứa sẵn public key `sealed-secrets.cert`. Developers dùng file này để mã hóa secrets.

Cluster cần private key `sealed-secrets.key` tương ứng để giải mã tại runtime:

- Mở trình quản lý mật khẩu của nhóm (1Password, Vault, v.v.).
- Tải về file `sealed-secrets.key` và đặt tại root của repo.

Nếu **chưa từng có** cặp key này (lần dựng cluster đầu tiên):

```bash
openssl req -x509 -newkey rsa:4096 -days 36500 -nodes \
  -keyout sealed-secrets.key -out sealed-secrets.cert \
  -subj "/CN=sealed-secret/O=sealed-secret"
```

_Lưu ý: Commit `sealed-secrets.cert` vào repo và lưu `sealed-secrets.key` vào Password Manager. File `.gitignore` phải chứa `sealed-secrets.key`._

---

## 3. Thực thi quá trình Bootstrap

Quá trình này giải quyết bài toán "con gà quả trứng" bằng 6 bước tuần tự sử dụng `kubectl apply` trực tiếp (không cần kustomize hay helm). Sau khi thành công, ArgoCD tiếp quản toàn bộ — không bao giờ cần chạy lại script.

1. Mở Terminal / PowerShell.
2. Di chuyển vào thư mục repo:
   ```bash
   cd ecoma/gitops
   ```
3. Chạy script bootstrap:
   ```bash
   ./bootstrap.sh
   ```
4. Script tự động verify key pair và thực hiện 6 bước:
   - **Step 1:** Inject Sealed Secrets TLS secret vào namespace `kube-system`.
   - **Step 2:** Cài đặt Sealed Secrets controller vào `kube-system` (direct URL, v0.27.3).
   - **Step 3:** Cài đặt Traefik CRDs (direct URL) — cần thiết để ArgoCD không gặp lỗi khi sync IngressRoute resources.
   - **Step 4:** Tạo namespace `argocd` + cài đặt ArgoCD (direct URL, stable manifest).
   - **Step 5:** Cài đặt Prometheus Operator CRDs (direct URL) — cần thiết để kube-prometheus-stack có thể deploy qua ArgoCD.
   - **Step 6:** Apply `platform-appset` (ApplicationSet) scan `declarative/platform/*/config.json`. ArgoCD sync `platform/argocd/` trước (syncWave -10), tự adopt AppSet, rồi tạo `observability-appset`, `infras-appset`, `tools-appset`, `applications-appset` để quản lý toàn bộ cluster.

---

## 4. Kiểm tra sức khỏe hệ thống sau khi bàn giao cho ArgoCD

1. Chờ khoảng 2 phút, đảm bảo ArgoCD Control Plane đang chạy:
   ```bash
   kubectl get pods -n argocd
   ```
2. Kiểm tra Sealed Secrets controller:
   ```bash
   kubectl get pods -n kube-system -l app.kubernetes.io/name=sealed-secrets
   ```
3. Kiểm tra Root App đã tạo các sub-applications chưa:
   ```bash
   kubectl get application -n argocd
   ```
4. Truy cập ArgoCD UI:
   ```bash
   kubectl port-forward svc/argocd-server -n argocd 8080:443
   # Visit https://localhost:8080
   ```
5. Lấy mật khẩu admin:
   ```bash
   kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d && echo
   ```

Nếu tất cả các pods liên quan đều báo `Running`, quá trình bootstrap đã thành công!
