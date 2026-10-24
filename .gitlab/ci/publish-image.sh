#!/usr/bin/env bash
set -euo pipefail

case "${APP_NAME:-}" in
  python-demo|java-demo|nginx-demo) ;;
  *) echo "Set APP_NAME to python-demo, java-demo, or nginx-demo" >&2; exit 2 ;;
esac
case "${TARGET_ENV:-}" in
  dev|qa) ;;
  *) echo "Set TARGET_ENV to dev or qa" >&2; exit 2 ;;
esac
if [[ -z "${GITLAB_API_TOKEN:-}" ]]; then
  echo "GITLAB_API_TOKEN is required to create the image promotion merge request" >&2
  exit 2
fi

AWS_REGION="${AWS_REGION:-eu-central-1}"
if [[ "$TARGET_ENV" == "dev" ]]; then
  ROLE_VARIABLE=AWS_ROLE_ARN_DEV
  ROLE_ARN="${AWS_ROLE_ARN_DEV:-}"
else
  ROLE_VARIABLE=AWS_ROLE_ARN_QA
  ROLE_ARN="${AWS_ROLE_ARN_QA:-}"
fi
if [[ -z "$ROLE_ARN" ]]; then
  echo "Set the protected GitLab variable $ROLE_VARIABLE" >&2
  exit 2
fi

credentials_file="$(mktemp)"
trap 'rm -f "$credentials_file"' EXIT
aws sts assume-role-with-web-identity \
  --role-arn "$ROLE_ARN" \
  --role-session-name "gitlab-${CI_PROJECT_ID}-${CI_PIPELINE_ID}" \
  --web-identity-token "$GITLAB_OIDC_TOKEN" \
  --duration-seconds 3600 > "$credentials_file"
export AWS_ACCESS_KEY_ID="$(jq -r '.Credentials.AccessKeyId' "$credentials_file")"
export AWS_SECRET_ACCESS_KEY="$(jq -r '.Credentials.SecretAccessKey' "$credentials_file")"
export AWS_SESSION_TOKEN="$(jq -r '.Credentials.SessionToken' "$credentials_file")"
rm -f "$credentials_file"

account_id="$(aws sts get-caller-identity --query Account --output text)"
registry="${account_id}.dkr.ecr.${AWS_REGION}.amazonaws.com"
repository="eks-platform-demo/${TARGET_ENV}/${APP_NAME}"
tag="$CI_COMMIT_SHA"
image_uri="${registry}/${repository}:${tag}"

aws ecr get-login-password --region "$AWS_REGION" |
  docker login --username AWS --password-stdin "$registry"
if ! aws ecr describe-images --region "$AWS_REGION" --repository-name "$repository" --image-ids "imageTag=$tag" >/dev/null 2>&1; then
  docker build --file "apps/$APP_NAME/Dockerfile" --tag "$image_uri" "apps/$APP_NAME"
  docker push "$image_uri"
else
  echo "Immutable image tag already exists; reusing $image_uri"
fi

values_file="helm/apps/$APP_NAME/values-${TARGET_ENV}.yaml"
branch="promote/${TARGET_ENV}/${APP_NAME}-${CI_COMMIT_SHORT_SHA}"
git config user.name "GitLab CI"
git config user.email "gitlab-ci@${CI_SERVER_HOST}"
git remote set-url origin "https://oauth2:${GITLAB_API_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git"
git fetch origin develop
git checkout -B "$branch" origin/develop

export image_uri values_file
python3 - <<'PY'
import os
import re
from pathlib import Path

path = Path(os.environ["values_file"])
repository, tag = os.environ["image_uri"].rsplit(":", 1)
content = path.read_text()
content, repository_count = re.subn(r"(?m)^  repository: .+$", f"  repository: {repository}", content, count=1)
content, tag_count = re.subn(r"(?m)^  tag: .+$", f'  tag: "{tag}"', content, count=1)
if repository_count != 1 or tag_count != 1:
    raise SystemExit(f"Expected exactly one image.repository and image.tag in {path}")
path.write_text(content)
PY

git add "$values_file"
if git diff --cached --quiet; then
  echo "The requested image is already recorded in $values_file"
  exit 0
fi
git commit -m "chore(gitops): deploy ${APP_NAME} ${CI_COMMIT_SHORT_SHA} to ${TARGET_ENV}"
git push --set-upstream origin "$branch"

existing_mr="$(curl --fail --silent --show-error \
  --header "PRIVATE-TOKEN: ${GITLAB_API_TOKEN}" \
  --get --data-urlencode "state=opened" --data-urlencode "source_branch=${branch}" \
  "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests" | jq -r '.[0].web_url // empty')"
if [[ -n "$existing_mr" ]]; then
  echo "Promotion merge request already exists: $existing_mr"
  exit 0
fi

curl --fail --silent --show-error --request POST \
  --header "PRIVATE-TOKEN: ${GITLAB_API_TOKEN}" \
  --data-urlencode "source_branch=${branch}" \
  --data-urlencode "target_branch=develop" \
  --data-urlencode "title=Promote ${APP_NAME} to ${TARGET_ENV} (${CI_COMMIT_SHORT_SHA})" \
  --data-urlencode "description=Promote tested image ${image_uri} to ${TARGET_ENV}. Merge to let Argo CD deploy it." \
  "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests" | jq -r '"Created promotion MR: " + .web_url'
