#!/usr/bin/env bash
set -euo pipefail

# Downloads the pinned third-party charts, then optionally pushes the chart
# archives to ECR as OCI artifacts. This mirrors charts, not their container
# images, and does not change the Argo CD Application sources.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART_DIR="${CHART_DIR:-${ROOT_DIR}/artifacts/helm-charts}"
AWS_REGION="${AWS_REGION:-eu-central-1}"
ECR_CHART_PREFIX="${ECR_CHART_PREFIX:-eks-platform-demo/addon-charts}"

usage() {
  cat <<'USAGE'
Usage:
  bash scripts/mirror-addon-charts.sh download
  AWS_PROFILE=<profile> bash scripts/mirror-addon-charts.sh push

Commands:
  download  Download the pinned charts to artifacts/helm-charts/.
  push      Create one ECR repository per chart and push the saved archives
            as OCI Helm charts. Requires AWS CLI, Docker/Helm registry support,
            and permission to create/push ECR repositories.

Optional environment variables:
  AWS_REGION       Defaults to eu-central-1 (Frankfurt).
  CHART_DIR        Defaults to <repo>/artifacts/helm-charts.
  ECR_CHART_PREFIX Defaults to eks-platform-demo/addon-charts.
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

  local entry name source version
  for entry in "${CHARTS[@]}"; do
    IFS='|' read -r name source version <<< "$entry"
    local archive="${CHART_DIR}/${name}-${version}.tgz"
    if [[ -f "$archive" ]]; then
      echo "Already downloaded: $archive"
      continue
    fi
    echo "Downloading ${name}:${version}"
    helm pull "$source" --version "$version" --destination "$CHART_DIR"
    # Karpenter's upstream OCI package uses the chart name/version filename too.
    if [[ ! -f "$archive" ]]; then
      echo "Expected chart archive not found: $archive" >&2
      exit 1
    fi
  done
  echo "Pinned Helm charts saved under: $CHART_DIR"
}

push_charts() {
  require_command aws
  require_command helm

  local identity registry entry name source version archive ecr_repository
  identity="$(aws sts get-caller-identity --query Account --output text)"
  registry="${identity}.dkr.ecr.${AWS_REGION}.amazonaws.com"

  aws ecr get-login-password --region "$AWS_REGION" |
    helm registry login --username AWS --password-stdin "$registry"

  for entry in "${CHARTS[@]}"; do
    IFS='|' read -r name source version <<< "$entry"
    archive="${CHART_DIR}/${name}-${version}.tgz"
    ecr_repository="${ECR_CHART_PREFIX}/${name}"
    if [[ ! -f "$archive" ]]; then
      echo "Missing chart archive: $archive" >&2
      echo "Run 'bash scripts/mirror-addon-charts.sh download' first." >&2
      exit 1
    fi

    if ! aws ecr describe-repositories \
      --region "$AWS_REGION" \
      --repository-names "$ecr_repository" >/dev/null 2>&1; then
      aws ecr create-repository \
        --region "$AWS_REGION" \
        --repository-name "$ecr_repository" \
        --image-scanning-configuration scanOnPush=true \
        --encryption-configuration encryptionType=AES256 >/dev/null
    fi

    echo "Pushing ${name}:${version} to ${registry}/${ecr_repository}"
    helm push "$archive" "oci://${registry}/${ECR_CHART_PREFIX}"
  done

  echo "Charts were pushed to ECR in ${AWS_REGION}."
  echo "Configure Argo CD with these OCI chart locations and registry authentication before switching Applications:"
  for entry in "${CHARTS[@]}"; do
    IFS='|' read -r name source version <<< "$entry"
    echo "  oci://${registry}/${ECR_CHART_PREFIX}/${name}:${version}"
  done
}

command="${1:-}"
case "$command" in
  download)
    download_charts
    ;;
  push)
    push_charts
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
