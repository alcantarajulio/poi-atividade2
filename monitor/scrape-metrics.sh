#!/usr/bin/env bash
set -u
url=$1
out=$2
interval=${3:-2}

keep='^(process_cpu_seconds_total|process_resident_memory_bytes|go_memstats_heap_inuse_bytes|go_goroutines|go_gc_duration_seconds_count|http_requests_in_flight|http_requests_total|http_request_duration_seconds_sum|http_request_duration_seconds_count)[ {]'

echo "ts,series,value" > "$out"
while true; do
  # Carimbo fracionário, no meio da requisição: o contador é lido em algum ponto entre os dois.
  t0=$(date +%s.%N)
  body=$(curl -s --max-time 5 "$url/metrics")
  t1=$(date +%s.%N)
  ts=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.3f", (a + b) / 2 }')
  printf '%s\n' "$body" | grep -E "$keep" | \
    awk -v ts="$ts" '{v=$NF; s=$0; sub(/ [^ ]+$/, "", s); gsub(/"/, "\x27", s); printf "%s,\"%s\",%s\n", ts, s, v}' >> "$out"
  sleep "$interval"
done
