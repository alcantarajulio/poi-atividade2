#!/usr/bin/env bash
set -u
vm=$1
prefix=$2

VBoxManage metrics setup --period 1 --samples 1 "$vm" >/dev/null 2>&1 || true
pid=$(pgrep -f -- "--comment ${vm}( |$)" | head -1)
clk=$(getconf CLK_TCK)

echo "ts,metric,value,unit" > "$prefix-vbox.csv"
echo "ts,cpu_ticks,rss_kb,clk_tck" > "$prefix-proc.csv"
while true; do
  ts=$(date +%s.%N)
  VBoxManage metrics query "$vm" 2>/dev/null | \
    awk -v ts="$ts" 'NR > 2 && NF >= 3 { v=$3; u=$4; if (v ~ /%$/) { sub(/%$/, "", v); u="%" } print ts "," $2 "," v "," u }' \
    >> "$prefix-vbox.csv"
  if [ -n "$pid" ] && [ -r "/proc/$pid/stat" ]; then
    ticks=$(awk '{print $14 + $15}' "/proc/$pid/stat")
    rss=$(awk '/^VmRSS/ {print $2}' "/proc/$pid/status")
    echo "$ts,$ticks,$rss,$clk" >> "$prefix-proc.csv"
  fi
  sleep 1
done
