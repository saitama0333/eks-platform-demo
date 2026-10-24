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

for tool in git aws kubectl python; do need "$tool"; done
[[ -f "$TFVARS" ]] || fail "Missing $TFVARS. Copy terraform.tfvars.example and configure it first."
[[ ! -e "$STATE_FILE" ]] || fail "Pause state already exists at $STATE_FILE. Use scripts/resume-dev.sh first."
[[ "$(git branch --show-current)" == "$BRANCH" ]] || fail "Switch to branch $BRANCH before pausing."

git fetch origin "$BRANCH"
[[ "$(git rev-parse HEAD)" == "$(git rev-parse "origin/$BRANCH")" ]] || fail "Local $BRANCH must match origin/$BRANCH before pausing. Pull or push your branch changes first."
git diff --cached --quiet || fail "The Git index has staged changes. Commit or unstage them before pausing."
if [[ -n "$(git status --porcelain -- "${GIT_PATHS[@]}")" ]]; then
  fail "Pause target files have local changes. Commit/push those changes first so the pause commit only contains the scale-down."
fi

read_tfvar() {
  python - "$TFVARS" "$1" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8")
key = re.escape(sys.argv[2])
found = re.findall(rf"(?m)^\s*{key}\s*=\s*(\d+)\s*$", text)
if len(found) != 1:
    raise SystemExit(f"Expected one numeric {sys.argv[2]} in terraform.tfvars")
print(found[0])
PY
}

set_tfvar() {
  python - "$TFVARS" "$1" "$2" <<'PY'
import re, sys
from pathlib import Path
path = Path(sys.argv[1])
raw = path.read_bytes()
newline = b"\r\n" if b"\r\n" in raw else b"\n"
text = raw.decode("utf-8").replace("\r\n", "\n")
key, value = sys.argv[2], sys.argv[3]
pattern = rf"(?m)^{re.escape(key)}\s*=\s*\d+\s*$"
updated, count = re.subn(pattern, f"{key} = {value}", text)
if count != 1:
    raise SystemExit(f"Expected one {key} setting in terraform.tfvars; found {count}")
path.write_bytes(updated.replace("\n", newline.decode()).encode("utf-8"))
PY
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

REPO_ROOT="$ROOT" python - <<'PY'
import re
from pathlib import Path

root = Path(__import__("os").environ["REPO_ROOT"])
edits = {
    "helm/apps/java-demo/values-dev.yaml": [(r"^replicaCount:\s*\d+\s*$", "replicaCount: 0")],
    "helm/apps/nginx-demo/values-dev.yaml": [(r"^replicaCount:\s*\d+\s*$", "replicaCount: 0")],
    "helm/apps/python-demo/values-dev.yaml": [(r"^replicaCount:\s*\d+\s*$", "replicaCount: 0")],
    "platform/addons/dev/tempo/values.yaml": [(r"^replicas:\s*\d+\s*$", "replicas: 0")],
    "platform/addons/dev/opentelemetry-collector/values.yaml": [(r"^replicaCount:\s*\d+\s*$", "replicaCount: 0")],
    "platform/karpenter/dev/nodepool-on-demand.yaml": [(r"^    cpu:\s*[\"']?\d+[\"']?\s*$", '    cpu: "0"')],
    "platform/karpenter/dev/nodepool-spot.yaml": [(r"^    cpu:\s*[\"']?\d+[\"']?\s*$", '    cpu: "0"')],
}

def replace_yaml_value(text, section_path, key, key_indent, replacement, filename):
    lines = text.splitlines(keepends=True)
    start = 0
    end = len(lines)
    for depth, section in enumerate(section_path):
        indent = "  " * depth
        header = indent + section + ":"
        found = next((i for i in range(start, end) if lines[i].rstrip("\r\n") == header), None)
        if found is None:
            raise SystemExit(f"Missing YAML section {'.'.join(section_path[:depth + 1])} in {filename}")
        start = found + 1
        end = len(lines)
        for i in range(start, len(lines)):
            line = lines[i].rstrip("\r\n")
            if line and not line.lstrip().startswith("#") and not line.startswith(" ") and not line.startswith("\t"):
                end = i
                break
            if line.startswith(indent) and len(line) > len(indent) and not line.startswith(indent + " ") and not line.startswith(indent + "\t"):
                end = i
                break
    prefix = " " * key_indent + key + ":"
    matches = [i for i in range(start, end) if lines[i].rstrip("\r\n").startswith(prefix)]
    if len(matches) != 1:
        raise SystemExit(f"Expected one {'.'.join(section_path)}.{key} in {filename}; found {len(matches)}")
    i = matches[0]
    ending = "\r\n" if lines[i].endswith("\r\n") else "\n" if lines[i].endswith("\n") else ""
    lines[i] = replacement + ending
    return "".join(lines)

prepared = {}
for name, replacements in edits.items():
    path = root / name
    raw = path.read_bytes()
    newline = b"\r\n" if b"\r\n" in raw else b"\n"
    text = raw.decode("utf-8").replace("\r\n", "\n")
    for pattern, replacement in replacements:
        updated, count = re.subn(pattern, replacement, text, count=1, flags=re.M)
        if count != 1:
            raise SystemExit(f"Expected one match in {name} for {pattern!r}; found {count}")
        text = updated
    prepared[path] = text.replace("\n", newline.decode())

prometheus_path = root / "platform/addons/dev/prometheus/values.yaml"
raw = prometheus_path.read_bytes()
newline = b"\r\n" if b"\r\n" in raw else b"\n"
text = raw.decode("utf-8").replace("\r\n", "\n")
text = replace_yaml_value(text, ["grafana"], "replicas", 2, "  replicas: 0", prometheus_path.name)
text = replace_yaml_value(text, ["prometheus", "prometheusSpec"], "replicas", 4, "    replicas: 0", prometheus_path.name)
text = replace_yaml_value(text, ["alertmanager", "alertmanagerSpec"], "replicas", 4, "    replicas: 0", prometheus_path.name)
prepared[prometheus_path] = text.replace("\n", newline.decode())

for path, text in prepared.items():
    path.write_text(text, encoding="utf-8", newline="")
PY

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
