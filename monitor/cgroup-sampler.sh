#!/usr/bin/env bash
set -u
c=$1
out=$2

echo "ts,cpu_usage_usec,mem_current_bytes,mem_anon_bytes" > "$out"
while true; do
  if line=$(docker exec "$c" sh -c '
      echo "$(awk "/^usage_usec/ {print \$2}" /sys/fs/cgroup/cpu.stat),$(cat /sys/fs/cgroup/memory.current),$(awk "/^anon / {print \$2}" /sys/fs/cgroup/memory.stat)"' 2>/dev/null); then
    echo "$(date +%s),$line" >> "$out"
  fi
  sleep 1
done
