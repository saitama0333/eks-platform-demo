REGION=eu-central-1
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
TAG="$(date -u +%Y%m%d%H%M%S)"

aws ecr get-login-password --region "$REGION" |
  docker login --username AWS --password-stdin "$REGISTRY"

for APP in python-demo java-demo nginx-demo; do
  REPOSITORY="eks-platform-demo/dev/${APP}"
  IMAGE="${REGISTRY}/${REPOSITORY}:${TAG}"
  docker build -f "apps/${APP}/Dockerfile" -t "$IMAGE" "apps/${APP}"
  docker push "$IMAGE"
done