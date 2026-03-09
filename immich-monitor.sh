#!/bin/bash
set -euo pipefail

NAME=$(basename "$0" .sh)

# Configuration
CONTAINER_FILTER="immich"
IDLE_DURATION=20            # Seconds to stay under CPU threshold
CHECK_INTERVAL=0.250        # Interval between checks (seconds)
PORT_WAKEUP=2283            # Port to watch for wake-up activity
CPU_THRESHOLD=1             # Below this CPU usage is considered idle
COOLDOWN_AFTER_UNPAUSE=300  # Optional, set to 0 to disable

# Scheduled run windows
SCHEDULED_STARTS=("00:05" "01:55")  # Align with nightly tasks and backups
SCHEDULED_DURATIONS=(1200 1200)     # time in seconds

# Logging
# if using not systmd set to "/dev/kmsg" or custom logfile to use orriginal logging 
LOGFILE="/dev/kmsg"

# Internal
frozen=false
last_unpause_time=0

# Permission check: must be root OR in docker group
if [[ "$EUID" -ne 0 ]]; then
  # Ensure the docker group exists
  if ! getent group docker >/dev/null; then
    echo "$NAME: [ERROR] docker group does not exist on this system"
    exit 1
  fi

  # Ensure the user is in the docker group
  if ! id -nG "$USER" | grep -qw "docker"; then
    echo "$NAME: [ERROR] This script must be run as root or a user in the docker group"
    exit 1
  fi
fi

# Wait until docker is available
start_time=$(date +%s)
while ! docker info > /dev/null 2>&1; do
  if (( $(date +%s) - start_time >= 600 )); then
    echo "$NAME: [ERROR] timeout: docker not available after 10 minutes."
    exit 1
  fi
  sleep "$CHECK_INTERVAL"
done

# Redirect all stdout and stderr to /dev/kmsg for kernel log visibility
if [[ -n "${LOGFILE:-}" ]]; then
  exec >> "$LOGFILE" 2>&1
fi

# If not running under systemd, fork into background
if [ -z "$INVOCATION_ID" ]; then
    # Already in background? If so, don't fork again
    if [ -z "$IMMICH_MONITOR_FORKED" ]; then
        export IMMICH_MONITOR_FORKED=1
        nohup "$0" "$@" >/dev/null 2>&1 &
        exit 0
    fi
fi

cpuavg() {
  docker ps -q --filter "name=$CONTAINER_FILTER" | xargs -r -I {} \
    docker stats {} --no-stream --format "{{.CPUPerc}}" | sed 's/%//' \
    | awk '{sum += int($1)} END {print (NR > 0 ? sum : 0)}'
}

freeze() {
  echo "$NAME: [INFO] $CONTAINER_FILTER containers: freeze"
  docker ps --filter "name=$CONTAINER_FILTER" --format "{{.Names}}" | sort -r | while read -r name; do
    docker pause "$name" > /dev/null 2>&1 || true
  done
  frozen=true
}

resume() {
  echo "$NAME: [INFO] $CONTAINER_FILTER containers: resume"
  docker ps --filter "name=$CONTAINER_FILTER" --format "{{.Names}}" | sort | while read -r name; do
    docker unpause "$name" > /dev/null 2>&1 || true
  done
  frozen=false
  last_unpause_time=$(date +%s)
}

wakeup() {
  netstat -tn | awk -v port="$PORT_WAKEUP" '$6 == "ESTABLISHED" && $4 ~ ":"port"$"' | grep -q .
}

in_any_window() {
  local now=$(date +%s)

  for i in "${!SCHEDULED_STARTS[@]}"; do
    local start=$(date -d "${SCHEDULED_STARTS[$i]}" +%s)
    local end=$(( start + SCHEDULED_DURATIONS[$i] ))

    if (( end < start )); then
      end=$(( end + 86400 ))
      if (( now < start )); then
        now=$(( now + 86400 ))
      fi
    fi

    if (( now >= start && now <= end )); then
      return 0
    fi
  done

  return 1
}

(
trap resume EXIT
echo "$NAME: [INFO] $CONTAINER_FILTER containers: looker"

idle_start=""

while true; do
  current_time=$(date +%s)

  if in_any_window; then
    if $frozen; then
      resume
    fi
    sleep "$CHECK_INTERVAL"
    continue
  fi

  if wakeup; then
    # Always extend cooldown on network activity
    last_unpause_time=$(date +%s)
    
    if $frozen; then
      resume
    fi
    idle_start=""
    sleep "$CHECK_INTERVAL"
    continue
  fi

  if (( COOLDOWN_AFTER_UNPAUSE > 0 )) && \
     (( current_time - last_unpause_time < COOLDOWN_AFTER_UNPAUSE )); then
    sleep "$CHECK_INTERVAL"
    continue
  fi

  if ! $frozen; then
    cpu_usage=$(cpuavg)
    current_time=$(date +%s)

    if [[ "$cpu_usage" -lt "$CPU_THRESHOLD" ]]; then
      if [[ -z "$idle_start" ]]; then
        idle_start=$current_time
      elif (( current_time - idle_start >= IDLE_DURATION )); then
        freeze
      fi
    else
      idle_start=""
    fi
  fi

  sleep "$CHECK_INTERVAL"
done
)
