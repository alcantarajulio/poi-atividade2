#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

CONF=experiments/scenarios.conf
source "$CONF"
VM_SSH_PORT=${VM_SSH_PORT:-2222}
VM_USER=${VM_USER:-osboxes}
VDI_SRC=/local/uasc/images/ubuntu_server_2204_poi.vdi
VDI=/tmp/ubuntu_server_2204_poi.vdi
TARGET_MS=${TARGET_MS:-25}
if [ "$(uname -s)-$(uname -m)" = Linux-x86_64 ]; then
  export PATH="$ROOT/tools/linux-amd64:$HOME/bin:$PATH"
fi

ssh_vm() {
  ssh -p "$VM_SSH_PORT" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
    "$VM_USER@localhost" "$@"
}

step() { printf '\n== %s\n' "$*"; }
ok() { printf '  ok      %s\n' "$*"; }
warn() { printf '  ATENÇÃO %s\n' "$*"; }
fail() { printf '  FALHOU  %s\n' "$*" >&2; exit 1; }

vm_exists() { VBoxManage showvminfo "$VM_NAME" >/dev/null 2>&1; }
vm_state() { VBoxManage showvminfo "$VM_NAME" --machinereadable | sed -n 's/^VMState="\(.*\)"/\1/p'; }

wait_ready() {
  local url=$1 secs=${2:-300}
  for _ in $(seq "$secs"); do
    curl -sf --max-time 2 "$url" >/dev/null && return 0
    sleep 1
  done
  return 1
}

physical_cores() {
  if command -v lscpu >/dev/null; then
    lscpu -p=core,socket | grep -v '^#' | sort -u | wc -l | tr -d ' '
  else
    sysctl -n hw.physicalcpu
  fi
}

set_conf_line() {
  local prefix=$1 line=$2 tmp
  tmp=$(mktemp)
  awk -v p="$prefix" -v l="$line" 'index($0, p) == 1 { print l; next } { print }' "$CONF" > "$tmp"
  cat "$tmp" > "$CONF"
  rm -f "$tmp"
}

cmd_preflight() {
  step "ferramentas"
  command -v VBoxManage >/dev/null && ok "VBoxManage $(VBoxManage --version)" || fail "VBoxManage não encontrado"
  command -v k6 >/dev/null && ok "$(k6 version | head -1)" || fail "k6 não encontrado (esperado em tools/linux-amd64/ ou ~/bin)"
  for t in curl ssh ssh-copy-id; do
    command -v "$t" >/dev/null && ok "$t" || fail "$t não encontrado"
  done

  step "binários das apps"
  for app in cpu mem io; do
    [ -x "bin/linux-amd64/$app" ] && ok "bin/linux-amd64/$app" || fail "falta bin/linux-amd64/$app"
  done

  step "host"
  local cores threads
  cores=$(physical_cores)
  threads=$(getconf _NPROCESSORS_ONLN)
  ok "$cores núcleos físicos, $threads threads"
  command -v lscpu >/dev/null && lscpu | grep 'Model name' | sed 's/^/          /' || true
  if [ "$cores" -lt 5 ]; then
    warn "com k6 e VM no mesmo host, o S4 deve ter no máximo $((cores - 1)) vCPUs ('calibrate' ajusta)"
  fi
  df -h /tmp | tail -1 | awk '{print "  ok      /tmp com " $4 " livres"}'

  step "disco e VM"
  if [ -f "$VDI" ]; then
    ok "$VDI já está em /tmp"
  elif [ -f "$VDI_SRC" ]; then
    ok "$VDI_SRC ($(du -h "$VDI_SRC" | cut -f1)); copie para /tmp antes de criar a VM"
  else
    fail "VDI não encontrado em $VDI_SRC nem em $VDI"
  fi
  if vm_exists; then
    ok "VM $VM_NAME registrada (estado: $(vm_state))"
  else
    warn "VM $VM_NAME ainda não existe: criem pela interface do VirtualBox com esse nome"
  fi
}

cmd_ssh() {
  step "acesso ssh por chave"
  echo "  esperando o sshd da VM na porta $VM_SSH_PORT..."
  for _ in $(seq 120); do
    ssh-keyscan -p "$VM_SSH_PORT" localhost >/dev/null 2>&1 && break
    sleep 2
  done
  ssh-keyscan -p "$VM_SSH_PORT" localhost >/dev/null 2>&1 || fail "nada respondendo na porta $VM_SSH_PORT (openssh-server instalado? regra ssh criada?)"
  if ssh_vm true 2>/dev/null; then
    ok "a chave já funciona"
  else
    [ -f ~/.ssh/id_ed25519.pub ] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
    echo "  ssh-copy-id: digite a senha osboxes.org"
    ssh-copy-id -p "$VM_SSH_PORT" -o StrictHostKeyChecking=accept-new "$VM_USER@localhost"
  fi
  ssh_vm 'echo "$(hostname): $(nproc) vCPU, $(free -m | awk "/^Mem:/ {print \$2}") MB"' \
    | sed 's/^/  ok      /' || fail "o ssh ainda pede senha"
}

cmd_deploy() {
  step "deploy das três apps"
  deploy/deploy.sh cpu mem io
  for p in 8081 8082 8083; do
    wait_ready "http://localhost:$p/readyz" 30 && ok "porta $p pronta" || fail "porta $p não respondeu"
  done
}

cmd_check() {
  step "acesso a partir do host"
  if curl -sf --max-time 3 localhost:8080 | grep -qi nginx; then ok "nginx (host 8080 -> VM 80)"; else warn "nginx não respondeu em localhost:8080"; fi
  local urls=("8081/cpu?iter=200000" "8082/mem?mb=64&hold=100" "8083/io?kb=256")
  for u in "${urls[@]}"; do
    curl -sf --max-time 10 "localhost:${u%%/*}/info" | sed 's/^/          /'
    out=$(curl -sf --max-time 10 "localhost:$u") && ok "$u -> $out" || fail "$u"
  done
}

cmd_calibrate() {
  step "calibrar o tempo de serviço do /cpu (meta: ${TARGET_MS} ms)"
  local base=200000 samples median iter
  for _ in 1 2 3; do curl -sf "localhost:$APP_PORT/cpu?iter=$base" >/dev/null; done
  samples=$(for _ in $(seq 10); do
    curl -sf "localhost:$APP_PORT/cpu?iter=$base" | sed -n 's/.*"elapsed_ms":\([0-9.]*\).*/\1/p'
  done | sort -n)
  median=$(echo "$samples" | awk '{a[NR]=$1} END {print (a[int((NR+1)/2)] + a[int(NR/2)+1]) / 2}')
  iter=$(awk -v b="$base" -v t="$TARGET_MS" -v m="$median" 'BEGIN { i = int(b * t / m / 10000 + 0.5) * 10000; if (i < 10000) i = 10000; print i }')
  ok "iter=$base leva ${median} ms (mediana de 10) -> iter=$iter deve levar ~${TARGET_MS} ms"
  set_conf_line "TARGET_PATH=" "TARGET_PATH='/cpu?iter=$iter'"
  ok "$(grep '^TARGET_PATH=' "$CONF")"

  local cores s4=4
  cores=$(physical_cores)
  if [ "$cores" -le 4 ]; then
    s4=$((cores - 1))
  fi
  [ "$s4" -lt 2 ] && s4=2
  set_conf_line "SCENARIOS=" "SCENARIOS=(\"S1 1 1024\" \"S2 2 1024\" \"S3 2 2048\" \"S4 $s4 2048\")"
  ok "$(grep '^SCENARIOS=' "$CONF")  (host com $cores núcleos físicos)"
  curl -sf "localhost:$APP_PORT/cpu?iter=$iter" | sed 's/^/          conferência: /'
}

cmd_restart_test() {
  step "ciclo desliga/liga (o run.sh faz isso a cada cenário)"
  if [ "$(vm_state)" = running ]; then
    VBoxManage controlvm "$VM_NAME" acpipowerbutton
    for _ in $(seq 120); do
      [ "$(vm_state)" = poweroff ] && break
      sleep 1
    done
    [ "$(vm_state)" = poweroff ] && ok "desligou por ACPI" || fail "não desligou em 120 s"
  fi
  VBoxManage startvm "$VM_NAME" --type headless >/dev/null
  wait_ready "http://localhost:$APP_PORT/readyz" 300 && ok "app voltou sozinha após o boot" || fail "app não voltou"
  curl -s "localhost:$APP_PORT/info" | sed 's/^/          /'
}

cmd_smoke() {
  step "nível curto de teste (S1, 4 usuários, 20 s)"
  local dir=experiments/results/smoke
  rm -rf "$dir"
  RESULTS_DIR=$dir ONLY=S1 LEVELS_ONLY=4 DURATION=20s WARMUP=5s experiments/run.sh "$CONF"
  local l="$dir/S1/vus-004"
  for f in k6.json metrics.csv vmstat.txt host-proc.csv host-vbox.csv; do
    if [ -s "$l/$f" ] && [ "$(wc -l < "$l/$f")" -gt 1 ]; then
      ok "$f ($(wc -l < "$l/$f" | tr -d ' ') linhas)"
    elif [ "$f" = host-vbox.csv ]; then
      warn "$f vazio: sem métricas do VBoxManage (o host-proc.csv cobre a CPU/RSS da VM)"
    elif [ "$f" = host-proc.csv ]; then
      warn "$f vazio: processo da VM não encontrado (pgrep -f -- '--comment $VM_NAME')"
    else
      fail "$f ausente ou vazio em $l"
    fi
  done
}

cmd_run() {
  step "varredura completa"
  local n_s n_l secs
  n_s=${#SCENARIOS[@]}
  n_l=${#LEVELS[@]}
  secs=$(( n_s * (n_l * (${DURATION%s} + ${WARMUP%s} + COOLDOWN) + 90) ))
  ok "$n_s cenários × $n_l níveis, ~$((secs / 60)) min. Não use esta máquina enquanto roda."
  experiments/run.sh "$CONF" 2>&1 | tee "experiments/run-$(date +%Y%m%d-%H%M).log"
}

cmd_pack() {
  step "empacotar resultados"
  local out
  out="$HOME/poi-resultados-$(date +%Y%m%d-%H%M).tar.gz"
  tar -czf "$out" experiments/results experiments/*.log "$CONF" 2>/dev/null || tar -czf "$out" experiments/results "$CONF"
  ok "$out ($(du -h "$out" | cut -f1)) -> Drive, junto com o VDI"
  if [ -f "$VDI" ]; then
    ok "VDI: $VDI ($(du -h "$VDI" | cut -f1)). Desligue a VM antes de copiar."
  fi
}

cmd_demo() {
  run_demo() { printf '\n$ %s\n' "$*"; eval "$*" || true; }
  run_demo "VBoxManage list runningvms"
  run_demo "ssh -p $VM_SSH_PORT $VM_USER@localhost 'nproc; free -m | head -2; systemctl is-active poi-cpu poi-mem poi-io'"
  run_demo "curl -s localhost:8081/info; echo"
  run_demo "curl -s 'localhost:8081/cpu?iter=200000'; echo"
  run_demo "curl -s 'localhost:8082/mem?mb=64&hold=100'; echo"
  run_demo "curl -s 'localhost:8083/io?kb=256'; echo"
  run_demo "curl -s localhost:8081/metrics | grep -E '^(http_requests_total|process_resident_memory_bytes|process_cpu_seconds_total)'"
}

usage() {
  cat <<'EOF'
Passo a passo do dia no LCC. Rode da raiz do pacote, nesta ordem:

  lab/lab.sh preflight      confere ferramentas, binários, host e o VDI
    criar a VM, as portas e instalar nginx e openssh pela interface (roteiro)
  lab/lab.sh ssh            cria a chave (se preciso) e a copia para a VM
  lab/lab.sh deploy         instala as três apps como serviços systemd
  lab/lab.sh check          testa o nginx e as três apps a partir do host
  lab/lab.sh calibrate      mede o /cpu, grava o iter e ajusta o S4 ao host
  lab/lab.sh restart-test   desliga e religa a VM e espera a app voltar
  lab/lab.sh smoke          roda um nível curto com todos os coletores
  lab/lab.sh run            varredura completa (~45 min)
  lab/lab.sh pack           empacota os resultados para levar
  lab/lab.sh demo           roda os comandos da demonstração
EOF
}

case "${1:-}" in
  preflight) cmd_preflight ;;
  ssh) cmd_ssh ;;
  deploy) cmd_deploy ;;
  check) cmd_check ;;
  calibrate) cmd_calibrate ;;
  restart-test) cmd_restart_test ;;
  smoke) cmd_smoke ;;
  run) cmd_run ;;
  pack) cmd_pack ;;
  demo) cmd_demo ;;
  *) usage ;;
esac
