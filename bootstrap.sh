#!/usr/bin/env bash
# =============================================================================
# Ecoma GitOps — Cluster Bootstrap
#
# Run ONCE on a freshly provisioned K3s cluster to bootstrap Sealed Secrets
# and ArgoCD.  After this script completes, ArgoCD takes over and manages
# everything — including itself — forever.
#
# Prerequisites:
#   - kubectl  (connected to the cluster, `kubectl get nodes` shows Ready)
#   - openssl
#   - base64
#   - sealed-secrets.cert  (public key, committed in repo root)
#   - sealed-secrets.key   (private key, from Password Manager — NEVER commit)
#   - K3s installed with:  --kubelet-arg=max-pods=256
#                          --kube-controller-manager-arg=node-cidr-mask-size=23
#
# Configuration via environment variables (optional):
#   ARGOCD_WAIT_TIMEOUT   — seconds to wait for ArgoCD to become ready
#                           default: 300
#   SS_WAIT_TIMEOUT       — seconds to wait for Sealed Secrets to become ready
#                           default: 120
#
# Usage:
#   ./bootstrap.sh
# =============================================================================

set -euo pipefail

# ── Color helpers ──────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log()  { echo -e "  ${CYAN}▸${RESET} $*"; }
ok()   { echo -e "  ${GREEN}✓${RESET} $*"; }
warn() { echo -e "  ${YELLOW}⚠${RESET} $*"; }
die()  { echo -e "\n${RED}[ERROR]${RESET} $*\n" >&2; exit 1; }

# ── Paths & Constants ──────────────────────────────────────────────────────────
GITOPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITOPS_REPO_URL="https://github.com/ecoma-io/gitops.git"
GITOPS_REVISION="main"
SEALED_SECRETS_CERT="${GITOPS_ROOT}/sealed-secrets.cert"
SEALED_SECRETS_KEY="${GITOPS_ROOT}/sealed-secrets.key"

# ── Config (overridable via env) ───────────────────────────────────────────────
ARGOCD_WAIT_TIMEOUT="${ARGOCD_WAIT_TIMEOUT:-300}"
SS_WAIT_TIMEOUT="${SS_WAIT_TIMEOUT:-120}"

# Script-internal state
TLS_CRT_B64=""
TLS_KEY_B64=""

# ── Prerequisites ──────────────────────────────────────────────────────────────
check_prerequisites() {
  echo -e "\n${BOLD}Prerequisites${RESET}"

  local missing=()

  for cmd in kubectl openssl base64; do
    if command -v "$cmd" &>/dev/null; then
      ok "${cmd}"
    else
      missing+=("$cmd")
    fi
  done

  if kubectl cluster-info &>/dev/null 2>&1; then
    local node_status
    node_status=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | head -1)
    ok "kubectl connected — node status: ${node_status:-unknown}"

    local max_pods
    max_pods=$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.pods}' 2>/dev/null || echo "unknown")
    if [[ "${max_pods}" =~ ^[0-9]+$ ]]; then
      if [[ "${max_pods}" -lt 256 ]]; then
        warn "Node max-pods=${max_pods} (expected ≥ 256). Reinstall K3s with --kubelet-arg=max-pods=256 and --kube-controller-manager-arg=node-cidr-mask-size=23"
      else
        ok "Node max-pods=${max_pods}"
      fi
    else
      warn "Cannot determine node max-pods — ensure K3s is installed with --kubelet-arg=max-pods=256"
    fi
  else
    missing+=("kubectl-cluster-connection")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing prerequisites: ${missing[*]}"
  fi
}

# ── Verify Sealed Secrets key pair ─────────────────────────────────────────────
verify_key_pair() {
  echo -e "\n${BOLD}Key Pair Verification${RESET}"

  [[ -f "${SEALED_SECRETS_CERT}" ]] \
    || die "sealed-secrets.cert not found at repo root."
  ok "sealed-secrets.cert found"

  [[ -f "${SEALED_SECRETS_KEY}" ]] \
    || die "sealed-secrets.key not found at repo root.\n\n  Retrieve it from your Password Manager and place it here.\n  NEVER commit this file to git."
  ok "sealed-secrets.key found"

  log "Verifying key pair..."

  local cert_pubkey key_pubkey
  cert_pubkey=$(openssl x509 -noout -pubkey -in "${SEALED_SECRETS_CERT}") \
    || die "Cannot read certificate: ${SEALED_SECRETS_CERT}"
  key_pubkey=$(openssl pkey -pubout -in "${SEALED_SECRETS_KEY}") \
    || die "Cannot read private key: ${SEALED_SECRETS_KEY}"

  [[ "${cert_pubkey}" == "${key_pubkey}" ]] \
    || die "sealed-secrets.key does NOT match sealed-secrets.cert!"

  ok "Key pair verified — public key matches"

  TLS_CRT_B64="$(base64 -w0 < "${SEALED_SECRETS_CERT}")"
  TLS_KEY_B64="$(base64 -w0 < "${SEALED_SECRETS_KEY}")"
}

# ── Step 1: Inject Sealed Secrets key ──────────────────────────────────────────
run_step1() {
  echo -e "\n${BOLD}Step 1 — Inject Sealed Secrets Key${RESET}"

  log "Creating Sealed Secrets TLS secret in kube-system..."

  kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: sealed-secrets-key
  namespace: kube-system
  labels:
    sealedsecrets.bitnami.com/sealed-secrets-key: "active"
type: kubernetes.io/tls
data:
  tls.crt: ${TLS_CRT_B64}
  tls.key: ${TLS_KEY_B64}
EOF

  ok "Sealed Secrets key injected into kube-system"
}

# ── Step 2: Install Sealed Secrets controller ──────────────────────────────────
run_step2() {
  echo -e "\n${BOLD}Step 2 — Install Sealed Secrets Controller${RESET}"

  log "Applying Sealed Secrets controller manifest..."
  kubectl apply -n kube-system \
    -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.27.3/controller.yaml

  ok "Sealed Secrets manifest applied"

  log "Waiting for controller to be ready (timeout: ${SS_WAIT_TIMEOUT}s)..."
  kubectl rollout status deployment/sealed-secrets-controller \
    --namespace kube-system \
    --timeout="${SS_WAIT_TIMEOUT}s"
  ok "Sealed Secrets controller is ready"
}

# ── Step 3: Install Traefik CRDs ──────────────────────────────────────────────
run_step3() {
  echo -e "\n${BOLD}Step 3 — Install Traefik CRDs${RESET}"

  local traefik_version="v3.6.12"
  local crd_url="https://raw.githubusercontent.com/traefik/traefik/${traefik_version}/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml"

  log "Applying Traefik CRDs (${traefik_version})..."
  kubectl apply --server-side --force-conflicts -f "${crd_url}"

  ok "Traefik CRDs installed (${traefik_version})"
}

# ── Step 4: Install ArgoCD ────────────────────────────────────────────────────
run_step4() {
  echo -e "\n${BOLD}Step 4 — Install ArgoCD${RESET}"

  log "Creating argocd namespace..."
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

  log "Applying ArgoCD manifest..."
  kubectl apply --server-side --force-conflicts -n argocd \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

  ok "ArgoCD manifest applied"

  log "Waiting for ArgoCD server to be ready (timeout: ${ARGOCD_WAIT_TIMEOUT}s)..."
  kubectl rollout status deployment/argocd-server \
    --namespace argocd \
    --timeout="${ARGOCD_WAIT_TIMEOUT}s"
  ok "ArgoCD server is ready"
}

# ── Step 5: Install Prometheus Operator CRDs ──────────────────────────────────
run_step5() {
  echo -e "\n${BOLD}Step 5 — Install Prometheus Operator CRDsn and create namespace${RESET}"
  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
  local base_url="https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/master/example/prometheus-operator-crd"
  local crds=(
    "monitoring.coreos.com_alertmanagerconfigs.yaml"
    "monitoring.coreos.com_alertmanagers.yaml"
    "monitoring.coreos.com_podmonitors.yaml"
    "monitoring.coreos.com_probes.yaml"
    "monitoring.coreos.com_prometheuses.yaml"
    "monitoring.coreos.com_prometheusrules.yaml"
    "monitoring.coreos.com_servicemonitors.yaml"
  )

  for crd in "${crds[@]}"; do
    log "Applying ${crd}..."
    kubectl apply --server-side --force-conflicts -f "${base_url}/${crd}"
  done

  ok "Prometheus Operator CRDs installed"
}

# ── Step 6: Apply Platform ApplicationSet ─────────────────────────────────────
run_step6() {
  echo -e "\n${BOLD}Step 6 — Platform ApplicationSet${RESET}"

  log "Applying platform ApplicationSet (scans declarative/platform/*/config.json)..."

  kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: platform
  namespace: argocd
spec:
  description: Core cluster infrastructure (ArgoCD, Traefik, cert-manager, sealed-secrets, etc.)
  sourceRepos:
    - https://github.com/ecoma-io/gitops.git
  destinations:
    - namespace: '*'
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
---
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: platform-appset
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]

  generators:
  - git:
      repoURL: ${GITOPS_REPO_URL}
      revision: ${GITOPS_REVISION}
      files:
      - path: declarative/platform/*/config.json
  template:
    metadata:
      name: '{{.path.basename}}'
      annotations:
        argocd.argoproj.io/sync-wave: '{{.syncWave}}'
    spec:
      project: platform
      source:
        repoURL: ${GITOPS_REPO_URL}
        targetRevision: ${GITOPS_REVISION}
        path: '{{.path.path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{.namespace}}'
      syncPolicy:
        automated:
          selfHeal: true
          prune: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
          - PruneLast=true
EOF

  ok "Platform ApplicationSet applied"
  ok "ArgoCD will sync declarative/platform/argocd first (syncWave -10), then adopt all AppSets"
}


# ── Post-bootstrap instructions ────────────────────────────────────────────────
print_complete_message() {
  echo ""
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${RESET}"
  echo -e "${GREEN}${BOLD}║          Bootstrap Complete!                 ║${RESET}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${RESET}"
  echo ""
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}║      Ecoma GitOps — Cluster Bootstrap        ║${RESET}"
  echo -e "${BOLD}╚══════════════════════════════════════════════╝${RESET}"
  echo ""
  echo "  Repo     : ${GITOPS_REPO_URL}"
  echo "  Revision : ${GITOPS_REVISION}"

  check_prerequisites
  verify_key_pair
  run_step1
  run_step2
  run_step3
  run_step4
  run_step5
  run_step6
  print_complete_message
}

main "$@"
