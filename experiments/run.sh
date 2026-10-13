#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

conf=${1:-experiments/scenarios.conf}
env_duration=${DURATION:-}
env_warmup=${WARMUP:-}
source "$conf"
DURATION=${env_duration:-$DURATION}
RESULTS=${RESULTS_DIR:-$RESULTS}
WARMUP=${env_warmup:-$WARMUP}
DRY_RUN=${DRY_RUN:-0}
VM_SSH_PORT=${VM_SSH_PORT:-2222}
VM_USER=${VM_USER:-osboxes}
export VM_SSH_PORT VM_USER

BASE_URL="http://localhost:$APP_PORT"
CONTAINER="poi-$APP"
SAMPLER_PIDS=()

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '  $'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

bg() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '  $'; printf ' %q' "$@"; printf ' &\n'
  else
    "$@" &
    SAMPLER_PIDS+=("$!")
    disown "$!"
  fi
}

vbox() {
  run VBoxManage "$@"
}

vm_state() {
  vbox showvminfo "$VM_NAME" --machinereadable | sed -n 's/^VMState="\(.*\)"/\1/p'
}

vm_ssh() {
  run ssh -p "$VM_SSH_PORT" -o BatchMode=yes -o ConnectTimeout=5 "$VM_USER@localhost" "$@"
}

stop_target() {
  if [ "$BACKEND" = docker ]; then
    run docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    return
  fi
  if [ "$DRY_RUN" = 1 ]; then
    vbox controlvm "$VM_NAME" acpipowerbutton
    echo "  (espera até o VMState virar poweroff; após 120 s, força com controlvm poweroff)"
    return
  fi
  [ "$(vm_state)" = running ] || return 0
  log "desligando $VM_NAME (ACPI)"
  vbox controlvm "$VM_NAME" acpipowerbutton
  for _ in $(seq 120); do
    [ "$(vm_state)" = poweroff ] && return 0
    sleep 1
  done
  log "a VM não desligou em 120 s; forçando poweroff"
  vbox controlvm "$VM_NAME" poweroff
  sleep 3
}

start_target() {
  local cpus=$1 mem=$2
  if [ "$BACKEND" = docker ]; then
    run docker run -d --name "$CONTAINER" --restart on-failure --cpus "$cpus" --memory "${mem}m" \
      -p "$APP_PORT:8080" "poi-$APP" >/dev/null
    return
  fi
  vbox modifyvm "$VM_NAME" --cpus "$cpus" --memory "$mem" --ioapic on
  vbox startvm "$VM_NAME" --type headless
}

wait_ready() {
  if [ "$DRY_RUN" = 1 ]; then
    echo "  (espera $BASE_URL/readyz responder 200, até 300 s)"
    return
  fi
  for _ in $(seq 300); do
    if curl -sf --max-time 2 "$BASE_URL/readyz" >/dev/null; then
      return 0
    fi
    sleep 1
  done
  log "a aplicação não ficou pronta em 300 s"
  return 1
}

record_scenario() {
  local dir=$1 name=$2 cpus=$3 mem=$4
  run mkdir -p "$dir"
  if [ "$DRY_RUN" = 1 ]; then
    echo "  (grava scenario.env, info.json e a configuração vista de dentro do alvo)"
    return
  fi
  cat > "$dir/scenario.env" <<META
scenario=$name
cpus=$cpus
mem_mb=$mem
backend=$BACKEND
app=$APP
target_path=$TARGET_PATH
think_time=${THINK_TIME:-0}
duration=$DURATION
warmup=$WARMUP
started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
META
  curl -s "$BASE_URL/info" > "$dir/info.json" || true
  if [ "$BACKEND" = vbox ]; then
    vm_ssh 'nproc; free -m; uptime' > "$dir/guest.txt" 2>&1 || true
    vbox showvminfo "$VM_NAME" --machinereadable | grep -E '^(cpus|memory)=' > "$dir/vm.txt" || true
  else
    docker inspect "$CONTAINER" --format '{{.HostConfig.NanoCpus}} {{.HostConfig.Memory}}' > "$dir/container.txt" || true
  fi
}

start_samplers() {
  local dir=$1
  SAMPLER_PIDS=()
  bg monitor/scrape-metrics.sh "$BASE_URL" "$dir/metrics.csv" 2
  if [ "$BACKEND" = docker ]; then
    bg monitor/cgroup-sampler.sh "$CONTAINER" "$dir/cgroup.csv"
  else
    bg monitor/guest-sampler.sh "$dir/vmstat.txt"
    bg monitor/host-vbox.sh "$VM_NAME" "$dir/host"
  fi
}

stop_samplers() {
  if [ "$DRY_RUN" = 1 ]; then
    echo "  (encerra os coletores em segundo plano)"
    return
  fi
  for pid in "${SAMPLER_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  for _ in $(seq 50); do
    local alive=0
    for pid in "${SAMPLER_PIDS[@]}"; do
      kill -0 "$pid" 2>/dev/null && alive=1
    done
    [ "$alive" = 0 ] && break
    sleep 0.1
  done
}

run_level() {
  local dir=$1 vus=$2
  run mkdir -p "$dir"
  log "  nível vus=$vus"
  start_samplers "$dir"
  run k6 run -q \
    -e BASE_URL="$BASE_URL" -e TARGET_PATH="$TARGET_PATH" \
    -e VUS="$vus" -e THINK_TIME="${THINK_TIME:-0}" \
    -e DURATION="$DURATION" -e WARMUP="$WARMUP" \
    -e SUMMARY="$dir/k6.json" load/load.js || log "  k6 terminou com erro (vus=$vus)"
  stop_samplers
  [ "$DRY_RUN" = 1 ] || sleep "$COOLDOWN"
}

main() {
  log "configuração: $conf | backend: $BACKEND | alvo: $BASE_URL$TARGET_PATH"
  run mkdir -p "$RESULTS"
  if [ "$DRY_RUN" != 1 ]; then
    { uname -a; command -v nproc >/dev/null && nproc || sysctl -n hw.ncpu;
      command -v lscpu >/dev/null && lscpu | grep -E 'Model name|^CPU\(s\)|Thread|Core' || true; } \
      > "$RESULTS/host.txt" 2>&1
  fi

  local levels=("${LEVELS[@]}")
  [ -n "${LEVELS_ONLY:-}" ] && levels=($LEVELS_ONLY)

  for spec in "${SCENARIOS[@]}"; do
    read -r name cpus mem <<< "$spec"
    if [ -n "${ONLY:-}" ] && [[ " $ONLY " != *" $name "* ]]; then
      continue
    fi
    log "cenário $name: $cpus vCPU, $mem MB"
    local sdir="$RESULTS/$name"
    stop_target
    start_target "$cpus" "$mem"
    wait_ready
    record_scenario "$sdir" "$name" "$cpus" "$mem"
    for vus in "${levels[@]}"; do
      run_level "$sdir/vus-$(printf %03d "$vus")" "$vus"
    done
  done

  [ "$BACKEND" = docker ] && stop_target
  log "fim. resultados em $RESULTS"
}

main
