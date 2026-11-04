#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"

LB=${LB:-150.165.85.77}
KEY=${KEY:-poi_grupo_17.pem}
SSH=(ssh -i "$KEY" -p 2217 -o StrictHostKeyChecking=accept-new "ubuntu@$LB")

titulo() { printf '\n\033[1;36m==== %s\033[0m\n' "$*"; }
local_() { printf '\033[1m$ %s\033[0m\n' "$*"; eval "$@"; }
vm() { printf '\033[1mubuntu@vm-poi-grupo-17:~$ %s\033[0m\n' "$*"; "${SSH[@]}" "$@"; }

titulo "1. SSH pelo balanceador poi-atividades ($LB:2217)"
local_ "${SSH[*]} hostname"

titulo "2. Volume de 1 GB anexado e montado"
vm lsblk
vm df -h /mnt/dados
vm grep dados /etc/fstab

titulo "3. Aplicações rodando no systemd"
vm systemctl --no-pager --lines=0 status poi-cpu poi-mem poi-io

titulo "4. Configuração das apps para usar o volume"
vm cat /etc/systemd/system/poi-io.service.d/volume.conf
vm ls -l /mnt/dados /mnt/dados/logs

titulo "5. Requisições pelo balanceador"
local_ "curl -s 'http://$LB:1701/cpu?iter=50000'"; echo
local_ "curl -s 'http://$LB:1702/mem?mb=8&hold=10'"; echo
local_ "curl -s 'http://$LB:1703/io?kb=64'"; echo

titulo "6. Logs gravados no volume"
sleep 1
vm tail -n 2 /mnt/dados/logs/poi-cpu.log /mnt/dados/logs/poi-mem.log /mnt/dados/logs/poi-io.log
