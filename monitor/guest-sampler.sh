#!/usr/bin/env bash
set -u
out=$1
exec ssh -p "${VM_SSH_PORT:-2222}" -o BatchMode=yes -o ConnectTimeout=5 \
  "${VM_USER:-osboxes}@localhost" 'vmstat -n -t 1' > "$out"
