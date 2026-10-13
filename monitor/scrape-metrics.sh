#!/usr/bin/env bash
set -u
url=$1
out=$2
interval=${3:-2}

keep='^(process_cpu_seconds_total|process_resident_memory_bytes|go_memstats_heap_inuse_bytes|go_goroutines|go_gc_duration_seconds_count|http_requests_in_flight|http_requests_total|http_request_duration_seconds_sum|http_request_duration_seconds_count)[ {]'

echo "ts,series,value" > "$out"
while true; do
  ts=$(date +%s)
  curl -s --max-time 5 "$url/metrics" | grep -E "$keep" | \
    awk -v ts="$ts" '{v=$NF; s=$0; sub(/ [^ ]+$/, "", s); gsub(/"/, "\x27", s); printf "%s,\"%s\",%s\n", ts, s, v}' >> "$out"
  sleep "$interval"
done
