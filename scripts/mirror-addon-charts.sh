#!/usr/bin/env bash
set -euo pipefail

# Optional helper for downloading pinned chart packages locally. Argo CD uses
# the public chart repositories configured in the Applications.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART_DIR="${CHART_DIR:-${ROOT_DIR}/artifacts/helm-charts}"

usage() {
  cat <<'USAGE'
Usage:
  bash scripts/mirror-addon-charts.sh download

Commands:
  download  Download pinned chart archives under artifacts/helm-charts/.

Optional environment variables:
  CHART_DIR        Defaults to <repo>/artifacts/helm-charts.
USAGE
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command not found: $1" >&2
    exit 1
  }
}

CHARTS=(
  "aws-load-balancer-controller|eks/aws-load-balancer-controller|1.14.0"
  "external-secrets|external-secrets/external-secrets|0.15.1"
  "karpenter|oci://public.ecr.aws/karpenter/karpenter|1.6.2"
  "metrics-server|metrics/metrics-server|3.12.2"
  "opentelemetry-collector|otel/opentelemetry-collector|0.113.0"
  "kube-prometheus-stack|prometheus/kube-prometheus-stack|91.5.1"
  "tempo|grafana/tempo|1.23.0"
  "velero|velero/velero|8.6.0"
)

add_chart_repositories() {
  helm repo add eks https://aws.github.io/eks-charts --force-update
  helm repo add external-secrets https://charts.external-secrets.io --force-update
  helm repo add metrics https://kubernetes-sigs.github.io/metrics-server/ --force-update
  helm repo add otel https://open-telemetry.github.io/opentelemetry-helm-charts --force-update
  helm repo add prometheus https://prometheus-community.github.io/helm-charts --force-update
  helm repo add grafana https://grafana.github.io/helm-charts --force-update
  helm repo add velero https://vmware-tanzu.github.io/helm-charts --force-update
  helm repo update
}

download_charts() {
  require_command helm
  mkdir -p "$CHART_DIR"
  add_chart_repositories

  local entry name source version archive
  for entry in "${CHARTS[@]}"; do
    IFS='|' read -r name source version <<< "$entry"
    archive="${CHART_DIR}/${name}-${version}.tgz"
    if [[ -f "$archive" ]]; then
      echo "Already downloaded: $archive"
      continue
    fi
    echo "Downloading ${name}:${version}"
    helm pull "$source" --version "$version" --destination "$CHART_DIR"
    if [[ ! -f "$archive" ]]; then
      echo "Expected chart archive not found: $archive" >&2
      exit 1
    fi
  done
  echo "Pinned Helm charts saved under: $CHART_DIR"
}

case "${1:-}" in
  download) download_charts ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac