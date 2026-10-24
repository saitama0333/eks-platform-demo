#!/usr/bin/env bash
set -Eeuo pipefail

# Pause dev workloads, cap Karpenter, then scale the EKS managed node group to
# zero. Run from Git Bash: bash scripts/pause-dev.sh

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
WAIT_SECONDS="${DEV_PAUSE_WAIT_SECONDS:-1800}"

GIT_PATHS=(
  "helm/apps/java-demo/values-dev.yaml"
  "helm/apps/nginx-demo/values-dev.yaml"
  "helm/apps/python-demo/values-dev.yaml"
  "platform/addons/dev/prometheus/values.yaml"
  "platform/addons/dev/tempo/values.yaml"
  "platform/addons/dev/opentelemetry-collector/values.yaml"
  "platform/karpenter/dev/nodepool-on-demand.yaml"
  "platform/karpenter/dev/nodepool-spot.yaml"
)

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"; }

for tool in git aws kubectl powershell.exe cygpath; do need "$tool"; done
[[ -f "$TFVARS" ]] || fail "Missing $TFVARS. Copy terraform.tfvars.example and configure it first."
[[ ! -e "$STATE_FILE" ]] || fail "Pause state already exists at $STATE_FILE. Use scripts/resume-dev.sh first."
[[ "$(git branch --show-current)" == "$BRANCH" ]] || fail "Switch to branch $BRANCH before pausing."

git fetch origin "$BRANCH"
[[ "$(git rev-parse HEAD)" == "$(git rev-parse "origin/$BRANCH")" ]] || fail "Local $BRANCH must match origin/$BRANCH before pausing. Pull or push your branch changes first."
git diff --cached --quiet || fail "The Git index has staged changes. Commit or unstage them before pausing."
if [[ -n "$(git status --porcelain -- "${GIT_PATHS[@]}")" ]]; then
  fail "Pause target files have local changes. Commit/push those changes first so the pause commit only contains the scale-down."
fi

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

read_tfvar() {
  run_powershell "$(cygpath -w "$TFVARS")" "$1" <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$path, $key = $args
$text = [System.IO.File]::ReadAllText($path)
$matches = [regex]::Matches($text, "(?m)^\s*$([regex]::Escape($key))\s*=\s*(\d+)\s*$")
if ($matches.Count -ne 1) { throw "Expected one numeric $key in terraform.tfvars" }
Write-Output $matches[0].Groups[1].Value
POWERSHELL
}

set_tfvar() {
  run_powershell "$(cygpath -w "$TFVARS")" "$1" "$2" <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$path, $key, $value = $args
$raw = [System.IO.File]::ReadAllBytes($path)
$text = [System.Text.Encoding]::UTF8.GetString($raw)
$newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
$normalized = $text.Replace("`r`n", "`n")
$pattern = "(?m)^$([regex]::Escape($key))\s*=\s*\d+\s*$"
$updated = [regex]::Replace($normalized, $pattern, "$key = $value", [System.Text.RegularExpressions.RegexOptions]::None)
$count = [regex]::Matches($normalized, $pattern).Count
if ($count -ne 1) { throw "Expected one $key setting in terraform.tfvars; found $count" }
$bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($updated.Replace("`n", $newline))
[System.IO.File]::WriteAllBytes($path, $bytes)
POWERSHELL
}

ORIGINAL_MIN="$(read_tfvar node_min_size)"
ORIGINAL_MAX="$(read_tfvar node_max_size)"
ORIGINAL_DESIRED="$(read_tfvar node_desired_size)"

aws sts get-caller-identity --profile "$AWS_PROFILE" >/dev/null || fail "AWS credentials/profile $AWS_PROFILE are not working."
kubectl --context "$KUBE_CONTEXT" get nodes >/dev/null || fail "Cannot reach Kubernetes context $KUBE_CONTEXT. Fix kubeconfig/network before pausing."

mapfile -t NODEGROUPS < <(
  aws eks list-nodegroups --profile "$AWS_PROFILE" --cluster-name "$CLUSTER_NAME" \
    --region "$AWS_REGION" --query 'nodegroups[]' --output text | tr '\t' '\n' \
    | grep -E '^nodegroup-worker-core-' || true
)
[[ "${#NODEGROUPS[@]}" -eq 1 ]] || fail "Expected exactly one nodegroup-worker-core-*; found ${#NODEGROUPS[@]}: ${NODEGROUPS[*]:-none}"
NODEGROUP="${NODEGROUPS[0]}"
GROUP_STATUS="$(aws eks describe-nodegroup --profile "$AWS_PROFILE" --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP" --region "$AWS_REGION" --query 'nodegroup.status' --output text)"
[[ "$GROUP_STATUS" == "ACTIVE" ]] || fail "Node group status is $GROUP_STATUS, not ACTIVE. Resolve its update before pausing."
LIVE_MIN="$(aws eks describe-nodegroup --profile "$AWS_PROFILE" --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP" --region "$AWS_REGION" --query 'nodegroup.scalingConfig.minSize' --output text)"
LIVE_MAX="$(aws eks describe-nodegroup --profile "$AWS_PROFILE" --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP" --region "$AWS_REGION" --query 'nodegroup.scalingConfig.maxSize' --output text)"
LIVE_DESIRED="$(aws eks describe-nodegroup --profile "$AWS_PROFILE" --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP" --region "$AWS_REGION" --query 'nodegroup.scalingConfig.desiredSize' --output text)"
[[ "$LIVE_MIN/$LIVE_MAX/$LIVE_DESIRED" == "$ORIGINAL_MIN/$ORIGINAL_MAX/$ORIGINAL_DESIRED" ]] || fail "Live nodegroup sizing ($LIVE_MIN/$LIVE_MAX/$LIVE_DESIRED) differs from terraform.tfvars ($ORIGINAL_MIN/$ORIGINAL_MAX/$ORIGINAL_DESIRED). Reconcile before pausing."

read -r -p "This will commit/push dev replica=0 and Karpenter limits=0, then scale $NODEGROUP to zero. Type PAUSE to continue: " CONFIRM
[[ "$CONFIRM" == "PAUSE" ]] || fail "Cancelled."

run_powershell "$(cygpath -w "$ROOT")" <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$root = $args[0]
$edits = @(
  @{ Name = 'helm/apps/java-demo/values-dev.yaml'; Pattern = '^replicaCount:\s*\d+\s*$'; Replacement = 'replicaCount: 0' }
  @{ Name = 'helm/apps/nginx-demo/values-dev.yaml'; Pattern = '^replicaCount:\s*\d+\s*$'; Replacement = 'replicaCount: 0' }
  @{ Name = 'helm/apps/python-demo/values-dev.yaml'; Pattern = '^replicaCount:\s*\d+\s*$'; Replacement = 'replicaCount: 0' }
  @{ Name = 'platform/addons/dev/tempo/values.yaml'; Pattern = '^replicas:\s*\d+\s*$'; Replacement = 'replicas: 0' }
  @{ Name = 'platform/addons/dev/opentelemetry-collector/values.yaml'; Pattern = '^replicaCount:\s*\d+\s*$'; Replacement = 'replicaCount: 0' }
  @{ Name = 'platform/karpenter/dev/nodepool-on-demand.yaml'; Pattern = '^    cpu:\s*["'']?\d+["'']?\s*$'; Replacement = '    cpu: "0"' }
  @{ Name = 'platform/karpenter/dev/nodepool-spot.yaml'; Pattern = '^    cpu:\s*["'']?\d+["'']?\s*$'; Replacement = '    cpu: "0"' }
)
function Replace-One([string]$text, [string]$pattern, [string]$replacement, [string]$name) {
  $count = [regex]::Matches($text, $pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline).Count
  if ($count -ne 1) { throw "Expected one match in $name for $pattern; found $count" }
  return [regex]::Replace($text, $pattern, $replacement, [System.Text.RegularExpressions.RegexOptions]::Multiline)
}
function Set-NestedYamlValue([string]$text, [string[]]$sections, [string]$key, [int]$indent, [string]$replacement, [string]$filename) {
  $lines = $text.Replace("`r`n", "`n").Split([string[]]@("`n"), [System.StringSplitOptions]::None)
  $start = 0; $end = $lines.Length
  for ($depth = 0; $depth -lt $sections.Length; $depth++) {
    $sectionIndent = '  ' * $depth
    $header = $sectionIndent + $sections[$depth] + ':'
    $found = -1
    for ($i = $start; $i -lt $end; $i++) { if ($lines[$i] -ceq $header) { $found = $i; break } }
    if ($found -lt 0) { throw "Missing YAML section $($sections[$depth]) in $filename" }
    $start = $found + 1; $end = $lines.Length
    for ($i = $start; $i -lt $lines.Length; $i++) {
      $line = $lines[$i]
      if ($line -and -not $line.TrimStart().StartsWith('#') -and -not $line.StartsWith(' ') -and -not $line.StartsWith("`t")) { $end = $i; break }
      if ($line.StartsWith($sectionIndent) -and $line.Length -gt $sectionIndent.Length -and -not $line.StartsWith($sectionIndent + ' ') -and -not $line.StartsWith($sectionIndent + "`t")) { $end = $i; break }
    }
  }
  $prefix = (' ' * $indent) + $key + ':'
  $matches = @()
  for ($i = $start; $i -lt $end; $i++) { if ($lines[$i].StartsWith($prefix)) { $matches += $i } }
  if ($matches.Count -ne 1) { throw "Expected one $key under $($sections -join '.') in $filename; found $($matches.Count)" }
  $lines[$matches[0]] = $replacement
  return ($lines -join "`n")
}
foreach ($edit in $edits) {
  $name = $edit.Name
  $path = Join-Path $root $name
  $text = [System.IO.File]::ReadAllText($path)
  $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
  $normalized = $text.Replace("`r`n", "`n")
  $normalized = Replace-One $normalized $edit.Pattern $edit.Replacement $name
  [System.IO.File]::WriteAllText($path, $normalized.Replace("`n", $newline), [System.Text.UTF8Encoding]::new($false))
}
$prometheusPath = Join-Path $root 'platform/addons/dev/prometheus/values.yaml'
$text = [System.IO.File]::ReadAllText($prometheusPath)
$newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
$normalized = $text.Replace("`r`n", "`n")
$normalized = Set-NestedYamlValue $normalized @('grafana') 'replicas' 2 '  replicas: 0' 'values.yaml'
$normalized = Set-NestedYamlValue $normalized @('prometheus','prometheusSpec') 'replicas' 4 '    replicas: 0' 'values.yaml'
$normalized = Set-NestedYamlValue $normalized @('alertmanager','alertmanagerSpec') 'replicas' 4 '    replicas: 0' 'values.yaml'
[System.IO.File]::WriteAllText($prometheusPath, $normalized.Replace("`n", $newline), [System.Text.UTF8Encoding]::new($false))
POWERSHELL

set_tfvar node_min_size 0
git add -- "${GIT_PATHS[@]}"
git diff --cached --quiet && fail "No tracked pause changes were created; check that the workload values are not already paused."
git commit -m "ops(dev): pause workloads and Karpenter capacity"
PAUSE_COMMIT="$(git rev-parse HEAD)"
mkdir -p "$(dirname "$STATE_FILE")"
cat > "$STATE_FILE" <<EOF
PAUSE_COMMIT=$PAUSE_COMMIT
NODEGROUP=$NODEGROUP
ORIGINAL_MIN=$ORIGINAL_MIN
ORIGINAL_MAX=$ORIGINAL_MAX
ORIGINAL_DESIRED=$ORIGINAL_DESIRED
EOF
git push origin "$BRANCH"

echo "Waiting for Argo CD to sync workloads and Karpenter limits..."
deadline=$((SECONDS + WAIT_SECONDS))
while (( SECONDS < deadline )); do
  synced=true
  for app in java-demo nginx-demo python-demo kube-prometheus-stack tempo opentelemetry-collector karpenter-config; do
    status="$(kubectl --context "$KUBE_CONTEXT" -n argocd get application "$app" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    [[ "$status" == "Synced" ]] || synced=false
  done
  limits_ok=true
  for pool in on-demand spot; do
    limit="$(kubectl --context "$KUBE_CONTEXT" get nodepool "$pool" -o jsonpath='{.spec.limits.cpu}' 2>/dev/null || true)"
    [[ "$limit" == "0" ]] || limits_ok=false
  done
  workloads_zero=true
  check_zero() {
    local kind="$1" ns="$2" name="$3" desired current ready
    desired="$(kubectl --context "$KUBE_CONTEXT" -n "$ns" get "$kind" "$name" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
    current="$(kubectl --context "$KUBE_CONTEXT" -n "$ns" get "$kind" "$name" -o jsonpath='{.status.replicas}' 2>/dev/null || true)"
    ready="$(kubectl --context "$KUBE_CONTEXT" -n "$ns" get "$kind" "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    [[ "${desired:-0}" == "0" && "${current:-0}" == "0" && "${ready:-0}" == "0" ]]
  }
  check_zero deployment default java-demo || workloads_zero=false
  check_zero deployment default nginx-demo || workloads_zero=false
  check_zero statefulset default python-demo || workloads_zero=false
  check_zero deployment monitoring kube-prometheus-stack-grafana || workloads_zero=false
  check_zero statefulset monitoring prometheus-kube-prometheus-stack-prometheus || workloads_zero=false
  check_zero statefulset monitoring alertmanager-kube-prometheus-stack-alertmanager || workloads_zero=false
  check_zero statefulset monitoring tempo || workloads_zero=false
  check_zero deployment monitoring opentelemetry-collector || workloads_zero=false
  if $synced && $limits_ok && $workloads_zero; then break; fi
  printf 'Still waiting (Argo synced=%s, NodePool limits zero=%s, workloads zero=%s)...\n' "$synced" "$limits_ok" "$workloads_zero"
  sleep 15
done
(( SECONDS < deadline )) || fail "Timed out waiting for Argo CD and zero replicas. Nodes were not scaled down; state saved at $STATE_FILE."

echo "Deleting Karpenter NodeClaims so their pods can drain onto the managed node group..."
kubectl --context "$KUBE_CONTEXT" get pdb -A
if [[ -n "$(kubectl --context "$KUBE_CONTEXT" get nodeclaims -o name)" ]]; then
  kubectl --context "$KUBE_CONTEXT" delete nodeclaims --all --wait=false
fi
deadline=$((SECONDS + WAIT_SECONDS))
while (( SECONDS < deadline )); do
  claims="$(kubectl --context "$KUBE_CONTEXT" get nodeclaims -o name)"
  karp_nodes="$(kubectl --context "$KUBE_CONTEXT" get nodes -l karpenter.sh/nodepool -o name)"
  if [[ -z "$claims" && -z "$karp_nodes" ]]; then break; fi
  printf 'Waiting for Karpenter claims/nodes to drain (claims=%s)...\n' "${claims//$'\n'/,}"
  sleep 15
done
(( SECONDS < deadline )) || fail "Karpenter nodes did not drain. The managed node group was left running. Review PDBs and Karpenter events."

echo "Scaling the EKS managed node group to zero..."
UPDATE_ID="$(aws eks update-nodegroup-config --profile "$AWS_PROFILE" --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP" --region "$AWS_REGION" --scaling-config "minSize=0,maxSize=$ORIGINAL_MAX,desiredSize=0" --query 'update.id' --output text)"
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

deadline=$((SECONDS + WAIT_SECONDS))
while (( SECONDS < deadline )); do
  nodes="$(kubectl --context "$KUBE_CONTEXT" get nodes -l "eks.amazonaws.com/nodegroup=$NODEGROUP" -o name 2>/dev/null || true)"
  [[ -z "$nodes" ]] && break
  printf 'Waiting for managed node group nodes to terminate...\n'
  sleep 15
done
[[ -z "${nodes:-}" ]] || fail "EKS update succeeded, but managed nodes remain. Check node group and Kubernetes status."

echo "Dev is paused. Pause commit: $PAUSE_COMMIT"
echo "Resume with: bash scripts/resume-dev.sh"
