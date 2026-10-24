#!/usr/bin/env bash
set -Eeuo pipefail

# Restore dev node capacity first, then revert/push the pause commit so Argo CD
# can safely bring the workloads and Karpenter pools back.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

AWS_PROFILE="${AWS_PROFILE:-sandbox3}"
export AWS_PROFILE
AWS_REGION="eu-central-1"
CLUSTER_NAME="eks-platform-demo-dev"
KUBE_CONTEXT="${KUBE_CONTEXT_DEV:-dev}"
BRANCH="develop"
STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/eks-platform-demo/dev-pause.env"
TFVARS="$ROOT/terraform/environments/dev/terraform.tfvars"
WAIT_SECONDS="${DEV_RESUME_WAIT_SECONDS:-1800}"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"; }
for tool in git aws kubectl powershell.exe cygpath; do need "$tool"; done
[[ -f "$STATE_FILE" ]] || fail "Pause state not found at $STATE_FILE. The pause script must complete first."
[[ -f "$TFVARS" ]] || fail "Missing $TFVARS. Copy terraform.tfvars.example and configure it first."
[[ "$(git branch --show-current)" == "$BRANCH" ]] || fail "Switch to branch $BRANCH before resuming."
git diff --quiet && git diff --cached --quiet || fail "Commit or stash local changes before resuming; Git revert must not overwrite them."
git fetch origin "$BRANCH"
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/$BRANCH")" ]]; then
  fail "Local $BRANCH differs from origin/$BRANCH. Sync the branch manually, then rerun; no scaling changes were made."
fi

PAUSE_COMMIT=""
NODEGROUP=""
ORIGINAL_MIN=""
ORIGINAL_MAX=""
ORIGINAL_DESIRED=""
while IFS='=' read -r key value; do
  case "$key" in
    PAUSE_COMMIT) PAUSE_COMMIT="$value" ;;
    NODEGROUP) NODEGROUP="$value" ;;
    ORIGINAL_MIN) ORIGINAL_MIN="$value" ;;
    ORIGINAL_MAX) ORIGINAL_MAX="$value" ;;
    ORIGINAL_DESIRED) ORIGINAL_DESIRED="$value" ;;
  esac
done < "$STATE_FILE"
[[ "$PAUSE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "Invalid pause commit in $STATE_FILE."
[[ "$NODEGROUP" =~ ^nodegroup-worker-core-[a-zA-Z0-9]+$ ]] || fail "Invalid node group name in $STATE_FILE."
for value in "$ORIGINAL_MIN" "$ORIGINAL_MAX" "$ORIGINAL_DESIRED"; do [[ "$value" =~ ^[0-9]+$ ]] || fail "Invalid saved node group sizing in $STATE_FILE."; done
git merge-base --is-ancestor "$PAUSE_COMMIT" "origin/$BRANCH" || fail "Saved pause commit is not on origin/$BRANCH. Restore the Git state manually before resuming."

aws sts get-caller-identity --profile "$AWS_PROFILE" >/dev/null || fail "AWS credentials/profile $AWS_PROFILE are not working."
GROUP_STATUS="$(aws eks describe-nodegroup --profile "$AWS_PROFILE" --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP" --region "$AWS_REGION" --query 'nodegroup.status' --output text)"
[[ "$GROUP_STATUS" == "ACTIVE" ]] || fail "Node group status is $GROUP_STATUS; wait for its current update before resuming."

run_powershell() {
  local script_path script_win status
  script_path="$(mktemp --suffix=.ps1)"
  cat > "$script_path"
  script_win="$(cygpath -w "$script_path")"
  powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$script_win" "$@"
  status=$?
  rm -f "$script_path"
  return "$status"
}

set_min_size() {
  run_powershell "$(cygpath -w "$TFVARS")" "$1" <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$path, $value = $args
$raw = [System.IO.File]::ReadAllBytes($path)
$text = [System.Text.Encoding]::UTF8.GetString($raw)
$newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
$normalized = $text.Replace("`r`n", "`n")
$pattern = '(?m)^node_min_size\s*=\s*\d+\s*$'
$count = [regex]::Matches($normalized, $pattern).Count
if ($count -ne 1) { throw "Expected one node_min_size setting; found $count" }
$updated = [regex]::Replace($normalized, $pattern, "node_min_size = $value")
[System.IO.File]::WriteAllBytes($path, [System.Text.UTF8Encoding]::new($false).GetBytes($updated.Replace("`n", $newline)))
POWERSHELL
}

read_min_size() {
  run_powershell "$(cygpath -w "$TFVARS")" <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$path = $args[0]
$text = [System.IO.File]::ReadAllText($path)
$matches = [regex]::Matches($text, '(?m)^node_min_size\s*=\s*(\d+)\s*$')
if ($matches.Count -ne 1) { throw 'Expected one numeric node_min_size in terraform.tfvars' }
Write-Output $matches[0].Groups[1].Value
POWERSHELL
}

[[ "$(read_min_size)" == "0" ]] || fail "terraform.tfvars node_min_size is not 0; this does not look like the paused state."
read -r -p "This will restore $NODEGROUP to $ORIGINAL_DESIRED nodes, then revert/push the pause commit. Type RESUME to continue: " CONFIRM
[[ "$CONFIRM" == "RESUME" ]] || fail "Cancelled."

echo "Restoring Terraform's local node_min_size and bringing core capacity up..."
set_min_size "$ORIGINAL_MIN"
UPDATE_ID="$(aws eks update-nodegroup-config --profile "$AWS_PROFILE" --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP" --region "$AWS_REGION" --scaling-config "minSize=$ORIGINAL_MIN,maxSize=$ORIGINAL_MAX,desiredSize=$ORIGINAL_DESIRED" --query 'update.id' --output text)"
deadline=$((SECONDS + WAIT_SECONDS))
while (( SECONDS < deadline )); do
  update_status="$(aws eks describe-update --profile "$AWS_PROFILE" --name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP" --update-id "$UPDATE_ID" --region "$AWS_REGION" --query 'update.status' --output text)"
  case "$update_status" in
    Successful) break ;;
    Failed|Cancelled) fail "Node group update $UPDATE_ID ended as $update_status. Inspect aws eks describe-update." ;;
  esac
  printf 'Node group update status: %s\n' "$update_status"
  sleep 15
done
[[ "${update_status:-}" == "Successful" ]] || fail "Timed out waiting for node group update $UPDATE_ID."

echo "Waiting for core nodes to become Ready..."
deadline=$((SECONDS + WAIT_SECONDS))
while (( SECONDS < deadline )); do
  ready="$(kubectl --context "$KUBE_CONTEXT" get nodes -l "eks.amazonaws.com/nodegroup=$NODEGROUP" --no-headers 2>/dev/null | awk '$2 == "Ready" {n++} END {print n+0}')"
  if (( ready >= ORIGINAL_DESIRED )); then break; fi
  printf 'Ready core nodes: %s/%s\n' "$ready" "$ORIGINAL_DESIRED"
  sleep 15
done
(( ${ready:-0} >= ORIGINAL_DESIRED )) || fail "Timed out waiting for core nodes. Pause commit is still active; no Git revert was made."

echo "Waiting for Argo CD controllers to become Ready..."
deadline=$((SECONDS + WAIT_SECONDS))
while (( SECONDS < deadline )); do
  server="$(kubectl --context "$KUBE_CONTEXT" -n argocd get deployment argocd-server -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
  controller="$(kubectl --context "$KUBE_CONTEXT" -n argocd get statefulset argocd-application-controller -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  if (( ${server:-0} > 0 && ${controller:-0} > 0 )); then break; fi
  sleep 15
done
(( ${server:-0} > 0 && ${controller:-0} > 0 )) || fail "Argo CD is not Ready. Core nodes are up and pause settings remain in Git."

if ! git log --format=%B "origin/$BRANCH" | grep -Fq "This reverts commit $PAUSE_COMMIT"; then
  git revert --no-edit "$PAUSE_COMMIT"
fi
git push origin "$BRANCH"

echo "Waiting for Argo CD to sync the restored values..."
deadline=$((SECONDS + WAIT_SECONDS))
while (( SECONDS < deadline )); do
  synced=true
  for app in java-demo nginx-demo python-demo kube-prometheus-stack tempo opentelemetry-collector karpenter-config; do
    status="$(kubectl --context "$KUBE_CONTEXT" -n argocd get application "$app" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    [[ "$status" == "Synced" ]] || synced=false
  done
  if $synced; then break; fi
  printf 'Waiting for app sync...\n'
  sleep 15
done
$synced || fail "Timed out waiting for Argo CD sync. Node group and Git values are restored; inspect the listed Applications."

rm -f "$STATE_FILE"
echo "Dev is resumed. Check workloads with: kubectl --context dev get nodes,pods -A"
