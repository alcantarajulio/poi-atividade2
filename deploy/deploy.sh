#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

VM_SSH_PORT=${VM_SSH_PORT:-2222}
VM_USER=${VM_USER:-osboxes}
[ $# -eq 0 ] && set -- cpu

for app in "$@"; do
  if [ ! -x "bin/linux-amd64/$app" ]; then
    echo "falta bin/linux-amd64/$app: rode 'make build-linux' (ou use o pacote do lab)" >&2
    exit 1
  fi
done

target="$VM_USER@localhost"
ssh_opts=(-o StrictHostKeyChecking=accept-new)

ssh -p "$VM_SSH_PORT" "${ssh_opts[@]}" "$target" 'mkdir -p ~/poi-deploy/bin'
bins=()
units=()
for app in "$@"; do
  bins+=("bin/linux-amd64/$app")
  units+=("deploy/poi-$app.service")
done
scp -P "$VM_SSH_PORT" "${ssh_opts[@]}" "${bins[@]}" "$target:poi-deploy/bin/"
scp -P "$VM_SSH_PORT" "${ssh_opts[@]}" "${units[@]}" deploy/vm-setup.sh "$target:poi-deploy/"
ssh -t -p "$VM_SSH_PORT" "${ssh_opts[@]}" "$target" "sudo bash ~/poi-deploy/vm-setup.sh $*"
