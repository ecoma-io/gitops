# Ecoma — GitOps

Cấu hình hạ tầng và triển khai cho hệ thống Ecoma. Repo này là **single source of truth** cho toàn bộ Kubernetes resources, được ArgoCD theo dõi và tự động sync. Chúng tôi xây dựng một nền tảng tự động hóa giúp quản lý vòng đời ứng dụng một cách nhất quán.

## Cấu trúc

Cấu trúc lấy cảm hứng từ [ArgoCD Autopilot](https://github.com/argoproj-labs/argocd-autopilot) — tách biệt rõ ràng bootstrap, project definitions, và application manifests.

```
gitops/
├── bootstrap.sh                       ← Bootstrap script (run once on fresh cluster)
├── sealed-secrets.cert                ← Public key for encrypting secrets
├── declarative/                       ← Kubernetes declarative configs
│   ├── argocd/                        ← ArgoCD self-management (Kustomize) + ApplicationSet
│   │   ├── kustomization.yaml         ← Root App (ArgoCD install + patches)
│   │   ├── infras-appset.yaml         ← Infrastructure ApplicationSet (git directory generator)
│   │   ├── ingress.yaml               ← ArgoCD Ingress (argocd.ecoma.io)
│   │   └── dex-secret.yaml            ← GitHub OAuth SealedSecret cho Dex
│   ├── infrastructure/                ← Shared infrastructure services
│   │   └── <service>/                 ← Traefik, KubeDB, monitoring, ...
│   │       ├── kustomization.yaml     ← Kustomize config (helmCharts hoặc resources)
│   │       └── *.values.yaml          ← Helm values (nếu dùng Helm)
│   └── applications/                  ← Ecoma application manifests (Kustomize)
│       └── <service>/
│           ├── base/
│           └── overlays/{staging,prod,preview-*}/
└── docs/                              ← Tài liệu
```

## Tài liệu

### Architecture

| Tài liệu                                                 | Mô tả                                                 |
| -------------------------------------------------------- | ----------------------------------------------------- |
| [Infrastructure Overview](docs/architecture/overview.md) | Kiến trúc hạ tầng, ArgoCD App of Apps, repo structure |
| [Decisions (ADRs)](docs/architecture/decisions/)         | Architecture Decision Records                         |

### Development

| Tài liệu                                               | Mô tả                                   |
| ------------------------------------------------------ | --------------------------------------- |
| [Getting Started](docs/development/getting-started.md) | Hướng dẫn làm việc với gitops repo      |
| [CD Pipeline](docs/development/cd-pipeline.md)         | ArgoCD, Image Updater, sync policy      |
| [Roadmap](docs/development/roadmap.md)                 | Phase 1 sprints cho infrastructure & CD |
| [Contributing](docs/contributing.md)                   | Branching strategy, PR convention       |

### Infrastructure

| Tài liệu                                            | Mô tả                                               |
| --------------------------------------------------- | --------------------------------------------------- |
| [Hardware](docs/infrastructure/hardware.md)         | Server specs, storage (LVM), network                |
| [K8s Cluster](docs/infrastructure/k8s-cluster.md)   | K3s setup, namespaces, resource allocation          |
| [Environments](docs/infrastructure/environments.md) | Dev, preview, staging, prod — cấu hình và isolation |

### Runbooks

| Tài liệu                                       | Mô tả                            |
| ---------------------------------------------- | -------------------------------- |
| [Bootstrap](docs/runbooks/bootstrap.md)        | Cluster bootstrap lần đầu        |
| [Deploy](docs/runbooks/deploy.md)              | Promote giữa các môi trường      |
| [Incident Response](docs/runbooks/incident.md) | Quy trình xử lý sự cố            |
| [Rollback](docs/runbooks/rollback.md)          | Rollback qua ArgoCD hoặc kubectl |

## Liên quan

- **Source repo:** [github.com/ecoma/source](https://github.com/ecoma/source) — Source code ứng dụng, CI pipeline
- **System overview:** [source/docs/architecture/overview.md](https://github.com/ecoma/source/blob/main/docs/architecture/overview.md)

## Giấy phép (License)
Dự án được phát hành dưới giấy phép **Business Source License 1.1 (BSL 1.1)**:
- Cho phép sử dụng cho mục đích học tập, nghiên cứu và môi trường thử nghiệm (Non-production).
- Yêu cầu liên hệ tác giả nếu có ý định sử dụng cho mục đích thương mại hoặc môi trường sản xuất (Production).
- Chi tiết xem tại file [LICENSE](./LICENSE).

> **⚠️ QUAN TRỌNG: Lộ trình Dự án & Bản quyền**
>
> Dự án này hiện đang trong giai đoạn **Public Beta / Research**. Mục tiêu hiện tại của chúng tôi là chia sẻ phương pháp triển khai hạ tầng dựa trên mô hình GitOps để cộng đồng tham khảo và học hỏi.
>
> **Lưu ý về định hướng tương lai:**
> - Khi dự án đạt đến phiên bản ổn định (v1.0) và hoàn thiện các chức năng cốt lõi (Core), chúng tôi có kế hoạch chuyển sang mô hình **Closed-Source / Commercial**.
> - Tại thời điểm đó, repository này có thể sẽ bị đóng hoặc ngừng cung cấp mã nguồn công khai.
> - Vui lòng cân nhắc kỹ khi phụ thuộc (dependency) trực tiếp vào dự án này cho các mục đích sản xuất lâu dài.