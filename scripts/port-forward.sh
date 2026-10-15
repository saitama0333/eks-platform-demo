#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' \
    'Usage:' \
    '  bash scripts/port-forward.sh [dev|qa] [start|status|stop]' \
    '' \
    'Starts local kubectl port-forwards in the background by default.' \
    'Use "status" to see tracked forwards and "stop" to stop them.'
}

ENVIRONMENT="${1:-dev}"
ACTION="${2:-start}"

case "$ENVIRONMENT" in
  dev|qa) ;;
  -h|--help|help) usage; exit 0 ;;
  *)
    echo "Environment must be dev or qa: ${ENVIRONMENT}" >&2
    usage >&2
    exit 2
    ;;
esac

case "$ACTION" in
  start|status|stop) ;;
  -h|--help|help) usage; exit 0 ;;
  *)
    echo "Action must be start, status, or stop: ${ACTION}" >&2
    usage >&2
    exit 2
    ;;
esac

command -v kubectl >/dev/null 2>&1 || {
  echo "kubectl is required but was not found in PATH." >&2
  exit 1
}

CONTEXT="$ENVIRONMENT"
STATE_ROOT="${XDG_STATE_HOME:-${HOME:-.}/.local/state}"
STATE_DIR="${STATE_ROOT}/eks-platform-demo/port-forward/${ENVIRONMENT}"
mkdir -p "$STATE_DIR"

FORWARDS=(
  "argocd|argocd-server|8080:443|https://localhost:8080|Argo CD"
  "monitoring|kube-prometheus-stack-grafana|3000:80|http://localhost:3000|Grafana"
  "monitoring|kube-prometheus-stack-prometheus|9090:9090|http://localhost:9090|Prometheus"
  "monitoring|kube-prometheus-stack-alertmanager|9093:9093|http://localhost:9093|Alertmanager"
  "monitoring|tempo|13200:3100 24317:4317 24318:4318|Tempo API http://localhost:13200; OTLP gRPC localhost:24317; OTLP HTTP localhost:24318|Tempo API and OTLP"
  "monitoring|opentelemetry-collector|14317:4317 14318:4318 18889:8889|OTLP gRPC localhost:14317; OTLP HTTP localhost:14318; metrics http://localhost:18889/metrics|OpenTelemetry Collector"
  "velero|velero|18085:8085|http://localhost:18085/metrics|Velero metrics (not a UI)"
  "default|python-demo|8081:80|http://localhost:8081|Python demo"
  "default|java-demo|8082:80|http://localhost:8082|Java demo"
  "default|nginx-demo|8083:80|http://localhost:8083|NGINX demo"
)

pid_file_for() {
  printf '%s/%s-%s.pid' "$STATE_DIR" "$1" "$2"
}

log_file_for() {
  printf '%s/%s-%s.log' "$STATE_DIR" "$1" "$2"
}

is_tracked_process() {
  local pid="$1"
  local service="$2"
  local args

  kill -0 "$pid" 2>/dev/null || return 1
  args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
  [[ "$args" == *"port-forward service/${service}"* ]]
}

show_status() {
  local namespace="$1"
  local service="$2"
  local url="$3"
  local label="$4"
  local pid_file pid

  pid_file="$(pid_file_for "$namespace" "$service")"
  if [[ -f "$pid_file" ]]; then
    pid="$(<"$pid_file")"
    if is_tracked_process "$pid" "$service"; then
      printf 'RUNNING  %-28s %s (PID %s)\n' "$label" "$url" "$pid"
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
  if is_tracked_process "$pid" "$service"; then
    kill "$pid"
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

if [[ "$ACTION" == "stop" ]]; then
  for entry in "${FORWARDS[@]}"; do
    IFS='|' read -r namespace service ports url label <<< "$entry"
    stop_forward "$namespace" "$service" "$label"
  done
  exit 0
fi

if ! kubectl --context "$CONTEXT" get --raw=/version >/dev/null; then
  echo "Cannot reach Kubernetes context '${CONTEXT}'. Connect kubectl to the ${ENVIRONMENT} cluster first." >&2
  exit 1
fi

failed=0
for entry in "${FORWARDS[@]}"; do
  IFS='|' read -r namespace service ports url label <<< "$entry"
  pid_file="$(pid_file_for "$namespace" "$service")"
  log_file="$(log_file_for "$namespace" "$service")"

  if [[ -f "$pid_file" ]]; then
    pid="$(<"$pid_file")"
    if is_tracked_process "$pid" "$service"; then
      printf 'Already running %-22s %s\n' "$label" "$url"
      continue
    fi
    rm -f "$pid_file"
  fi

  if ! kubectl --context "$CONTEXT" -n "$namespace" \
    get service "$service" >/dev/null 2>&1; then
    printf 'Skipped %-28s service %s/%s is not installed\n' "$label" "$namespace" "$service"
    continue
  fi

  read -r -a port_args <<< "$ports"
  nohup kubectl --context "$CONTEXT" -n "$namespace" \
    port-forward --address 127.0.0.1 "service/${service}" "${port_args[@]}" \
    >"$log_file" 2>&1 </dev/null &
  pid=$!
  printf '%s\n' "$pid" > "$pid_file"

  ready=0
  for _ in {1..10}; do
    if grep -q 'Forwarding from 127.0.0.1:' "$log_file"; then
      ready=1
      break
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 1
  done

  if [[ "$ready" -eq 1 ]] && is_tracked_process "$pid" "$service"; then
    printf 'Started  %-28s %s\n' "$label" "$url"
  else
    printf 'Failed   %-28s see %s\n' "$label" "$log_file" >&2
    rm -f "$pid_file"
    failed=1
  fi
done

echo
echo "Port-forwards run in the background on this computer."
echo "Check: bash scripts/port-forward.sh ${ENVIRONMENT} status"
echo "Stop:  bash scripts/port-forward.sh ${ENVIRONMENT} stop"
echo "State and logs: ${STATE_DIR}"

exit "$failed"
