#!/bin/bash
# Development helper: rebuilds the app whenever build/.request changes (lets Claude trigger builds).
# Double-click to start, close the Terminal window (or Ctrl-C) to stop.
cd "$(dirname "$0")"
mkdir -p build
echo "HX Bridge build watcher — waiting for build requests. Close this window to stop."
last="$(cat build/.request 2>/dev/null)"
while true; do
  cur="$(cat build/.request 2>/dev/null)"
  if [[ -n "$cur" && "$cur" != "$last" ]]; then
    last="$cur"
    args="${cur#* }"; [[ "$args" == "$cur" ]] && args=""
    echo "== $(date '+%H:%M:%S') build request: $cur"
    ./build.sh $args > build/last-run.txt 2>&1
    code=$?
    echo "exit=$code" >> build/last-run.txt
    echo "$cur exit=$code" > build/.done
    echo "   finished (exit $code)"
  fi
  sleep 1
done
