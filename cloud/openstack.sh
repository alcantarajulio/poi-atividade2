#!/usr/bin/env bash
set -euo pipefail

RC=${RC:-$HOME/Downloads/Provisionamento-openrc.sh}
VENV=${VENV:-$HOME/lsd/venv}
VM=vm-poi-grupo-17
KEY=poi_grupo_17
SG=sg-grupo-17
VOL=vol-grupo-17
LB=poi-atividades
LB_ID=${LB_ID:-57c2b14a-b746-4f34-8719-d0627e409609}
SNAP=${SNAP:-snap-poi-grupo-17}
SSH_PORT=2217
app_port() { case $1 in cpu) echo 8081;; mem) echo 8082;; io) echo 8083;; esac; }
lb_port() { case $1 in cpu) echo 1701;; mem) echo 1702;; io) echo 1703;; esac; }
# Atividade 4: containers do docker-compose.yml
docker_port() { case $1 in cpu) echo 9081;; mem) echo 9082;; io) echo 9083;; esac; }
docker_lb_port() { case $1 in cpu) echo 1711;; mem) echo 1712;; io) echo 1713;; esac; }

source "$VENV/bin/activate"
export PYTHONWARNINGS=ignore
source "$RC"

run() { printf '\n\033[1m$ openstack %s\033[0m\n' "$*"; openstack "$@"; }

wait_lb() {
  local s
  for _ in $(seq 60); do
    s=$(openstack loadbalancer show "$LB_ID" -f value -c provisioning_status)
    [ "$s" = ACTIVE ] && return 0
    sleep 3
  done
  echo "balanceador preso em $s" >&2; exit 1
}

lbrun() {
  for _ in $(seq 20); do
    wait_lb
    if out=$(openstack "$@" 2>&1); then
      printf '\n\033[1m$ openstack %s\033[0m\n%s\n' "$*" "$out"; return 0
    fi
    echo "$out" | grep -q immutable || { printf '%s\n' "$out" >&2; return 1; }
    sleep 5
  done
  return 1
}

listener() {
  local name=$1 proto=$2 port=$3 member_port=$4
  openstack loadbalancer listener show "$name" >/dev/null 2>&1 ||
    lbrun loadbalancer listener create --name "$name" --protocol "$proto" --protocol-port "$port" "$LB_ID"
  openstack loadbalancer pool show "$name-pool" >/dev/null 2>&1 ||
    lbrun loadbalancer pool create --name "$name-pool" --listener "$name" --protocol "$proto" --lb-algorithm ROUND_ROBIN
  [ -n "$(openstack loadbalancer member list "$name-pool" -f value -c id)" ] ||
    lbrun loadbalancer member create --name "$VM" --subnet-id "$SUBNET" --address "$VM_IP" --protocol-port "$member_port" "$name-pool"
}

listar() {
  run flavor list
  run image list
  run server list --name grupo-17
  run keypair list
  run security group rule list "$SG"
  run volume list
  run image list --property image_type=snapshot
  run loadbalancer list
}

rede() {
  openstack security group rule list "$SG" -f value -c "Port Range" | grep -q '8081:8083' ||
    run security group rule create --remote-ip 0.0.0.0/0 --protocol tcp --dst-port 8081:8083 "$SG"
  run security group rule list "$SG"
}

vm_rede() {
  VM_IP=$(openstack server show "$VM" -f json -c addresses | python3 -c 'import json,sys; a=json.load(sys.stdin)["addresses"]; print(next(iter(a.values()))[0])')
  NET=$(openstack server show "$VM" -f json -c addresses | python3 -c 'import json,sys; print(next(iter(json.load(sys.stdin)["addresses"])))')
  SUBNET=$(openstack subnet list --network "$NET" -f value -c ID | head -1)
  echo "VM $VM_IP na rede $NET (subnet $SUBNET)"
}

lb() {
  vm_rede
  listener ssh-grupo-17 TCP "$SSH_PORT" 22
  for app in cpu mem io; do
    listener "app-$app-grupo-17" HTTP "$(lb_port $app)" "$(app_port $app)"
  done
  run loadbalancer listener list --loadbalancer "$LB_ID" -c name -c protocol -c protocol_port | grep -E 'grupo-17|protocol'
  run loadbalancer show "$LB_ID" -c name -c vip_address -c provisioning_status
}

containers() {
  openstack security group rule list "$SG" -f value -c "Port Range" | grep -q '9081:9083' ||
    run security group rule create --remote-ip 0.0.0.0/0 --protocol tcp --dst-port 9081:9083 "$SG"
  vm_rede
  for app in cpu mem io; do
    listener "docker-$app-grupo-17" HTTP "$(docker_lb_port $app)" "$(docker_port $app)"
  done
  run loadbalancer listener list --loadbalancer "$LB_ID" -c name -c protocol -c protocol_port | grep -E 'grupo-17|protocol'
  for app in cpu mem io; do
    run loadbalancer member list "docker-$app-grupo-17-pool" -c name -c address -c protocol_port -c operating_status
  done
}

volume() {
  openstack volume show "$VOL" >/dev/null 2>&1 || run volume create --size 1 --description "dados e logs do grupo 17" "$VOL"
  for _ in $(seq 20); do
    [ "$(openstack volume show "$VOL" -f value -c status)" != creating ] && break; sleep 2
  done
  [ "$(openstack volume show "$VOL" -f value -c status)" = available ] && run server add volume "$VM" "$VOL"
  sleep 3
  run volume show "$VOL" -c name -c size -c status -c attachments
}

snapshot() {
  run server image create --wait --name "$SNAP" "$VM"
  run image show "$SNAP" -c name -c status -c size
}

[ $# -eq 0 ] && { echo "uso: $0 listar|rede|lb|containers|volume|snapshot ..." >&2; exit 2; }
for etapa in "$@"; do
  case "$etapa" in
    listar|rede|lb|containers|volume|snapshot) "$etapa" ;;
    *) echo "etapa desconhecida: $etapa" >&2; exit 2 ;;
  esac
done
