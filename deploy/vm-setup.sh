#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
[ $# -eq 0 ] && set -- cpu

id poi >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin poi
install -d /opt/poi/bin

for app in "$@"; do
  install -m 0755 "bin/$app" "/opt/poi/bin/$app"
  install -m 0644 "poi-$app.service" /etc/systemd/system/
done

systemctl daemon-reload
for app in "$@"; do
  systemctl enable "poi-$app"
  systemctl restart "poi-$app"
done

sleep 1
for app in "$@"; do
  systemctl --no-pager --lines=3 status "poi-$app" || true
done
