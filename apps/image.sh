set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

REGION=eu-central-1
ENVIRONMENT="${1:-dev}"
if [[ ! "$ENVIRONMENT" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "Usage: bash apps/image.sh [environment]" >&2
  echo "Environment names must start with a lowercase letter or number and contain only lowercase letters, numbers, or hyphens." >&2
  exit 2
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
TAG="$(date -u +%Y%m%d%H%M%S)-$$"
echo "Using AWS account: ${ACCOUNT_ID}"
echo "Using environment: ${ENVIRONMENT}"
echo "Using image tag: ${TAG}"

APPS=(python-demo java-demo nginx-demo)
for APP in "${APPS[@]}"; do
  VALUES_FILE="${REPO_ROOT}/helm/apps/${APP}/values-${ENVIRONMENT}.yaml"
  if [[ ! -f "$VALUES_FILE" ]]; then
    echo "Values file not found: ${VALUES_FILE}" >&2
    exit 1
  fi

  repository_count="$(grep -Ec '^  repository:' "$VALUES_FILE" || true)"
  tag_count="$(grep -Ec '^  tag:' "$VALUES_FILE" || true)"
  if [[ "$repository_count" != "1" || "$tag_count" != "1" ]]; then
    echo "Expected exactly one image repository and tag in ${VALUES_FILE}" >&2
    exit 1
  fi
done

aws ecr get-login-password --region "$REGION" |
  docker login --username AWS --password-stdin "$REGISTRY"

for APP in "${APPS[@]}"; do
  REPOSITORY="eks-platform-demo/${ENVIRONMENT}/${APP}"
  IMAGE="${REGISTRY}/${REPOSITORY}:${TAG}"
  echo "Building and pushing ${IMAGE}"
  docker build -f "${REPO_ROOT}/apps/${APP}/Dockerfile" -t "$IMAGE" "${REPO_ROOT}/apps/${APP}"
  docker push "$IMAGE"
done

for APP in "${APPS[@]}"; do
  REPOSITORY="eks-platform-demo/${ENVIRONMENT}/${APP}"
  VALUES_FILE="${REPO_ROOT}/helm/apps/${APP}/values-${ENVIRONMENT}.yaml"
  sed -i -E "s|^  repository:.*$|  repository: ${REGISTRY}/${REPOSITORY}|" "$VALUES_FILE"
  sed -i -E "s|^  tag:.*$|  tag: \"${TAG}\"|" "$VALUES_FILE"
  echo "Updated ${VALUES_FILE#${REPO_ROOT}/}: ${REGISTRY}/${REPOSITORY}:${TAG}"
done