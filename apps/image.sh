set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

REGION=eu-central-1
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
TAG="$(date -u +%Y%m%d%H%M%S)"
echo "Using image tag: ${TAG}"

aws ecr get-login-password --region "$REGION" |
  docker login --username AWS --password-stdin "$REGISTRY"

for APP in python-demo java-demo nginx-demo; do
  REPOSITORY="eks-platform-demo/dev/${APP}"
  IMAGE="${REGISTRY}/${REPOSITORY}:${TAG}"
  echo "Building and pushing ${IMAGE}"
  docker build -f "${REPO_ROOT}/apps/${APP}/Dockerfile" -t "$IMAGE" "${REPO_ROOT}/apps/${APP}"
  docker push "$IMAGE"
done