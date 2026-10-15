
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "__run-forward" ]]; then
  shift
  service="$1"
  shift
  "$@" &
  child_pid=$!
  trap 'kill "$child_pid" 2>/dev/null || true; wait "$child_pid" 2>/dev/null || true; exit 143' TERM INT HUP
  wait "$child_pid"
  exit $?
fi

# Usage:
#   bash scripts/port-forward.sh dev start
#   bash scripts/port-forward.sh dev status
#   bash scripts/port-forward.sh dev stop

# --------------------------------------------------
# 1. Environment-to-context mapping
# --------------------------------------------------
# Override these variables if your kubeconfig uses
# different context names.
declare -A CONTEXTS=(
  [dev]="${KUBE_CONTEXT_DEV:-dev}"
  [qa]="${KUBE_CONTEXT_QA:-qa}"
  [prod]="${KUBE_CONTEXT_PROD:-prod}"
)

# --------------------------------------------------
# 2. Port-forward definitions
# Format: namespace|service|ports|URL|description
# Add or remove entries here as needed.
# --------------------------------------------------
FORWARDS=(
  "argocd|argocd-server|8080:443|https://localhost:8080|Argo CD"
  "monitoring|kube-prometheus-stack-grafana|3000:80|http://localhost:3000|Grafana"
  "monitoring|kube-prometheus-stack-prometheus|9090:9090|http://localhost:9090|Prometheus"
  "monitoring|kube-prometheus-stack-alertmanager|9093:9093|http://localhost:9093|Alertmanager"
  "monitoring|tempo|13200:3100 24317:4317 24318:4318|http://localhost:13200|Tempo API and OTLP"
  "monitoring|opentelemetry-collector|14317:4317 14318:4318 18889:8889|http://localhost:18889/metrics|OpenTelemetry Collector"
  "velero|velero|18085:8085|http://localhost:18085/metrics|Velero metrics"
  "default|python-demo|8081:80|http://localhost:8081|Python demo"
  "default|java-demo|8082:80|http://localhost:8082|Java demo"
  "default|nginx-demo|8083:80|http://localhost:8083|NGINX demo"
)

# --------------------------------------------------
# 3. Arguments and local state
# --------------------------------------------------
usage() {
  cat <<'EOF'
Usage:
  bash scripts/port-forward.sh <dev|qa|prod> <start|status|stop>

Commands:
  start   Start available port-forwards in background
  status  Show tracked port-forwards
  stop    Stop tracked port-forwards

Examples:
  bash scripts/port-forward.sh dev start
  bash scripts/port-forward.sh qa status
  bash scripts/port-forward.sh dev stop

Optional context overrides:
  KUBE_CONTEXT_DEV
  KUBE_CONTEXT_QA
  KUBE_CONTEXT_PROD
EOF
}

ENVIRONMENT="${1:-}"
ACTION="${2:-start}"

if [[ "$ENVIRONMENT" == "-h" || "$ENVIRONMENT" == "--help" ||
      "$ENVIRONMENT" == "help" ]]; then
  usage
  exit 0
fi

if [[ ! -v "CONTEXTS[$ENVIRONMENT]" ]]; then
  echo "Error: environment must be dev, qa, or prod." >&2
  usage >&2
  exit 2
fi

case "$ACTION" in
  start|status|stop) ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    echo "Error: action must be start, status, or stop." >&2
    usage >&2
    exit 2
    ;;
esac

command -v kubectl >/dev/null 2>&1 || {
  echo "kubectl is required but was not found in PATH." >&2
  exit 1
}

for utility in grep mkdir nohup ps rm sleep; do
  command -v "$utility" >/dev/null 2>&1 || {
    echo "Required command not found: ${utility}" >&2
    exit 1
  }
done

CONTEXT="$ENVIRONMENT"
STATE_ROOT="${XDG_STATE_HOME:-${HOME:-.}/.local/state}"
STATE_DIR="${STATE_ROOT}/eks-platform-demo/port-forward/${ENVIRONMENT}"

mkdir -p "$STATE_DIR"

pid_file_for() {
  printf '%s/%s-%s.pid' "$STATE_DIR" "$1" "$2"
}

log_file_for() {
  printf '%s/%s-%s.log' "$STATE_DIR" "$1" "$2"
}

# Check that a PID still belongs to the expected port-forward.
is_tracked_process() {
  local pid="$1"
  local namespace="$2"
  local service="$3"
  local args

  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  args="$(ps -p "$pid" -f 2>/dev/null || true)"
  [[ "$args" == *__run-forward*"${service}"* ]]
}

terminate_forward() {
  local pid="$1"
  local service="$2"

  if ! is_tracked_process "$pid" "$service"; then
    return 0
  fi
  if ! kill "$pid" 2>/dev/null; then
    if is_tracked_process "$pid" "$service"; then
      echo "Could not stop port-forward process ${pid} for ${service}." >&2
      return 1
    fi
    return 0
  fi

  for _ in {1..5}; do
    is_tracked_process "$pid" "$service" || return 0
    sleep 1
  done

  if is_tracked_process "$pid" "$service"; then
    echo "Port-forward process ${pid} for ${service} did not stop." >&2
    return 1
  fi
  return 0
}

# --------------------------------------------------
# 4. Status
# --------------------------------------------------
show_status() {
  local namespace="$1" service="$2"
  local url="$3" label="$4"
  local pid_file pid

  pid_file="$(pid_file_for "$namespace" "$service")"


  if [[ -f "$pid_file" ]]; then
    pid="$(<"$pid_file")"

    if is_tracked_process "$pid" "$namespace" "$service"; then
      printf 'RUNNING  %-28s %s (PID %s)\n' \
        "$label" "$url" "$pid"
      return
    fi

    rm -f "$pid_file"
  fi

  printf 'STOPPED  %-28s %s\n' "$label" "$url"
}

stop_forward() {
  local namespace="$1"
  local service="$2"
  local label="$3"
  local pid_file pid

  pid_file="$(pid_file_for "$namespace" "$service")"
  if [[ ! -f "$pid_file" ]]; then
    return
  fi

  pid="$(<"$pid_file")"
  if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
    printf 'Removed invalid PID file for %s\n' "$label"
  elif is_tracked_process "$pid" "$service"; then
    if ! terminate_forward "$pid" "$service"; then
      return 1
    fi
    printf 'Stopped %-28s (PID %s)\n' "$label" "$pid"
  else
    printf 'Removed stale PID file for %s\n' "$label"
  fi
  rm -f "$pid_file"
}

if [[ "$ACTION" == "status" ]]; then
  for entry in "${FORWARDS[@]}"; do
    IFS='|' read -r namespace service ports url label <<< "$entry"
    show_status "$namespace" "$service" "$url" "$label"
  done
  exit 0
fi

# --------------------------------------------------
# 5. Stop
# --------------------------------------------------
stop_forward() {
  local namespace="$1" service="$2" label="$3"
  local pid_file pid

  pid_file="$(pid_file_for "$namespace" "$service")"

  [[ -f "$pid_file" ]] || return 0

  pid="$(<"$pid_file")"

  if is_tracked_process "$pid" "$namespace" "$service"; then
    if kill "$pid" 2>/dev/null; then
      printf 'Stopped  %-28s (PID %s)\n' "$label" "$pid"
    else
      printf 'Could not stop %-28s (PID %s)\n' "$label" "$pid" >&2
      return 1
    fi
  else
    printf 'Removed stale PID file: %s\n' "$label"
  fi

  rm -f "$pid_file"
}

if [[ "$ACTION" == "stop" ]]; then
  failed=0
  for entry in "${FORWARDS[@]}"; do
    IFS='|' read -r namespace service ports url label <<< "$entry"
    stop_forward "$namespace" "$service" "$label" || failed=1
  done
  exit "$failed"
fi

# --------------------------------------------------
# 6. Start: validate tools and cluster access
# --------------------------------------------------
if ! command -v kubectl >/dev/null 2>&1; then
  echo "Error: kubectl was not found in PATH." >&2
  exit 1
fi

if ! kubectl config get-contexts -o name 2>/dev/null |
     grep -Fxq "$CONTEXT"; then
  echo "Error: Kubernetes context '$CONTEXT' does not exist." >&2
  echo "Available contexts:" >&2
  kubectl config get-contexts -o name >&2 || true
  exit 1
fi

if ! kubectl --context "$CONTEXT" get namespaces >/dev/null 2>&1; then
  echo "Error: cannot access Kubernetes context '$CONTEXT'." >&2
  echo "Check AWS credentials, EKS access, and connectivity." >&2
  exit 1
fi

echo "Environment : $ENVIRONMENT"
echo "Context     : $CONTEXT"
echo

# --------------------------------------------------
# 7. Start available port-forwards
# --------------------------------------------------
failed=0

for entry in "${FORWARDS[@]}"; do
  IFS='|' read -r namespace service ports url label <<< "$entry"

  pid_file="$(pid_file_for "$namespace" "$service")"
  log_file="$(log_file_for "$namespace" "$service")"

  # Don't start a duplicate tracked process.
  if [[ -f "$pid_file" ]]; then
    pid="$(<"$pid_file")"

    if is_tracked_process "$pid" "$namespace" "$service"; then
      printf 'Already running %-28s %s\n' "$label" "$url"
      continue
    fi

    rm -f "$pid_file"
  fi

  # Skip optional services that are not installed.
  if ! kubectl --context "$CONTEXT" -n "$namespace" \
      get service "$service" >/dev/null 2>&1; then
    printf 'Skipped    %-28s service %s/%s not found\n' \
      "$label" "$namespace" "$service"
    continue
  fi

  read -r -a port_args <<< "$ports"
  nohup bash "$0" __run-forward "$service" \
    kubectl --context "$CONTEXT" -n "$namespace" \
    port-forward --address 127.0.0.1 "service/${service}" "${port_args[@]}" \
    >"$log_file" 2>&1 </dev/null &

  pid=$!
  printf '%s\n' "$pid" > "$pid_file"

  # Wait up to 10 seconds for forwarding to become ready.
  ready=0

  for ((i = 0; i < 10; i++)); do
    if grep -q 'Forwarding from 127.0.0.1:' "$log_file" 2>/dev/null; then
      ready=1
      break
    fi

    if ! is_tracked_process "$pid" "$namespace" "$service"; then
      break
    fi

    sleep 1
  done

  if [[ "$ready" -eq 1 ]] && is_tracked_process "$pid" "$namespace" "$service"; then
    printf 'Started    %-28s %s\n' "$label" "$url"
  else
    if is_tracked_process "$pid" "$service"; then
      terminate_forward "$pid" "$service" || failed=1
    fi
    printf 'Failed   %-28s see %s\n' "$label" "$log_file" >&2
    rm -f "$pid_file"
    failed=1
  fi
done

echo
echo "Status: bash scripts/port-forward.sh $ENVIRONMENT status"
echo "Stop:   bash scripts/port-forward.sh $ENVIRONMENT stop"
echo "Logs:   $STATE_DIR"

exit "$failed"
