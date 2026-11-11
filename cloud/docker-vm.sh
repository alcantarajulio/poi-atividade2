#!/usr/bin/env bash
# Atividade 4: Docker e Compose na vm-poi-grupo-17, acessada pelo balanceador.
#   cloud/docker-vm.sh deploy      instala o Docker, copia o compose e sobe as apps
#   cloud/docker-vm.sh evidencias  roteiro de prints (containers, imagens, URLs)
set -uo pipefail
cd "$(dirname "$0")/.."

LB=${LB:-150.165.85.77}
KEY=${KEY:-cloud/poi_grupo_17.pem}
SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=accept-new)
SSH=(ssh "${SSH_OPTS[@]}" -p 2217 "ubuntu@$LB")

titulo() { printf '\n\033[1;36m==== %s\033[0m\n' "$*"; }
local_() { printf '\033[1m$ %s\033[0m\n' "$*"; eval "$@"; }
vm() { printf '\033[1mubuntu@vm-poi-grupo-17:~/poi-docker$ %s\033[0m\n' "$*"; "${SSH[@]}" "cd ~/poi-docker 2>/dev/null; $*"; }

deploy() {
  set -e
  grep -q DOCKERHUB_USER docker-compose.yml && { echo "troque DOCKERHUB_USER no docker-compose.yml" >&2; exit 1; }
  "${SSH[@]}" 'mkdir -p ~/poi-docker'
  scp "${SSH_OPTS[@]}" -P 2217 docker-compose.yml "ubuntu@$LB:poi-docker/"
  "${SSH[@]}" bash -s <<'EOF'
set -euo pipefail
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  sudo apt-get update -q
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q docker.io docker-compose-v2
fi
sudo systemctl enable --now docker
# a app io roda como UID 10001 e grava no volume de 1 GB
sudo install -d -o 10001 -g 10001 /mnt/dados/docker/io
cd ~/poi-docker
sudo docker compose pull
sudo docker compose up -d
sleep 5
sudo docker compose ps
EOF
}

evidencias() {
  titulo "1. Docker e Compose instalados na VM"
  vm 'sudo docker version --format "Docker {{.Server.Version}} ({{.Server.Os}}/{{.Server.Arch}})"; sudo docker compose version'

  titulo "2. docker-compose.yml usado no deploy"
  vm cat docker-compose.yml

  titulo "3. Imagens baixadas do Docker Hub"
  vm 'sudo docker compose images'

  titulo "4. Containers em execução"
  vm 'sudo docker compose ps'

  titulo "5. Requisições pelo balanceador poi-atividades"
  local_ "curl -s 'http://$LB:1711/cpu?iter=50000'"; echo
  local_ "curl -s 'http://$LB:1712/mem?mb=8&hold=10'"; echo
  local_ "curl -s 'http://$LB:1713/io?kb=64'"; echo
  local_ "curl -s 'http://$LB:1711/info'"; echo

  titulo "6. Logs de acesso dos containers"
  sleep 1
  vm 'sudo docker compose logs --tail 2 cpu mem io'
}

[ $# -eq 0 ] && { echo "uso: $0 deploy|evidencias" >&2; exit 2; }
for etapa in "$@"; do
  case "$etapa" in
    deploy|evidencias) "$etapa" ;;
    *) echo "etapa desconhecida: $etapa" >&2; exit 2 ;;
  esac
done
