#!/usr/bin/env bash
set -euo pipefail

MNT=/mnt/dados
DEV=${DEV:-$(lsblk -dpno NAME,SIZE,TYPE | awk '$2=="1G" && $3=="disk" {print $1; exit}')}
[ -b "$DEV" ] || { echo "volume de 1 GB não encontrado; rode lsblk e passe DEV=/dev/..." >&2; exit 1; }

echo "== discos antes"
lsblk

if ! blkid "$DEV" >/dev/null 2>&1; then
  echo "== formatando $DEV em ext4"
  mkfs.ext4 -L poi-dados "$DEV"
fi

UUID=$(blkid -s UUID -o value "$DEV")
mkdir -p "$MNT"
grep -q "$UUID" /etc/fstab || echo "UUID=$UUID $MNT ext4 defaults,nofail 0 2" >> /etc/fstab
mountpoint -q "$MNT" || mount "$MNT"

id poi >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin poi
install -d -o poi -g poi "$MNT/logs" "$MNT/io"

for app in cpu mem io; do
  d=/etc/systemd/system/poi-$app.service.d
  mkdir -p "$d"
  {
    echo "[Unit]"
    echo "RequiresMountsFor=$MNT"
    echo "[Service]"
    echo "StandardOutput=append:$MNT/logs/poi-$app.log"
    echo "StandardError=append:$MNT/logs/poi-$app.log"
    [ "$app" = io ] && echo "Environment=IO_DIR=$MNT/io"
  } > "$d/volume.conf"
done

systemctl daemon-reload
for app in cpu mem io; do systemctl restart "poi-$app" 2>/dev/null || true; done

echo "== discos depois"
lsblk "$DEV"
df -h "$MNT"
grep "$MNT" /etc/fstab
ls -l "$MNT" "$MNT/logs"
