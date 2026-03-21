#!/bin/bash
set -euo pipefail

NAME=$(basename "$0" .sh)

# Configuration
CONTAINER_FILTER="immich"
IDLE_DURATION=20            # Seconds to stay under CPU threshold
CHECK_INTERVAL=0.250        # Interval between checks (seconds) - base value
IDLE_CHECK_INTERVAL=2.0     # Slower interval when frozen
PORT_WAKEUP=80              # Port to watch for wake-up activity
CPU_THRESHOLD=1             # Below this CPU usage is considered idle
COOLDOWN_AFTER_UNPAUSE=300  # Optional, set to 0 to disable

# Scheduled run windows
SCHEDULED_STARTS=("00:05" "01:55")  # Align with nightly tasks and backups
SCHEDULED_DURATIONS=(1200 1200)     # time in seconds

# Logging
# When running under systemd (INVOCATION_ID set): output goes to stdout/stderr (captured by systemd)
# When running standalone: optionally redirect to /dev/kmsg
LOGFILE=""
if [ -z "$INVOCATION_ID" ]; then
  # Only redirect to kmsg when NOT running under systemd
  LOGFILE="/dev/kmsg"
fi

# Internal
frozen=false
last_unpause_time=0
PIDFILE="/var/run/immich-monitor.pid"

# Cleanup function for PID file
cleanup() {
  if [[ -f "$PIDFILE" ]]; then
    rm -f "$PIDFILE"
  fi
}

# Check if another instance is running
check_existing_instance() {
  if [[ -f "$PIDFILE" ]]; then
    local existing_pid
    existing_pid=$(cat "$PIDFILE" 2>/dev/null)
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      echo "$NAME: [ERROR] Another instance is already running (PID: $existing_pid)"
      exit 1
    else
      echo "$NAME: [WARN] Removing stale PID file"
      rm -f "$PIDFILE"
    fi
  fi
}

# Validate scheduled starts configuration
validate_schedule_config() {
  for i in "${!SCHEDULED_STARTS[@]}"; do
    local time_str="${SCHEDULED_STARTS[$i]}"
    if [[ ! "$time_str" =~ ^[0-2][0-9]:[0-5][0-9]$ ]]; then
      echo "$NAME: [ERROR] Invalid time format in SCHEDULED_STARTS[$i]: $time_str (expected HH:MM)"
      exit 1
    fi
    
    local duration="${SCHEDULED_DURATIONS[$i]}"
    if [[ ! "$duration" =~ ^[0-9]+$ ]] || (( duration <= 0 )); then
      echo "$NAME: [ERROR] Invalid duration in SCHEDULED_DURATIONS[$i]: $duration (expected positive integer seconds)"
      exit 1
    fi
  done
}

# Validate configuration
validate_schedule_config

# Permission check
if [[ "$EUID" -ne 0 ]]; then
  echo "$NAME: [ERROR] This script must be run as root"
  exit 1
fi

# Wait until docker is available
start_time=$(date +%s)
sleep 60  # Initial delay to allow system to stabilize and docker to start  
while ! docker info > /dev/null 2>&1; do
  if (( $(date +%s) - start_time >= 600 )); then
    echo "$NAME: [ERROR] timeout: docker not available after 10 minutes."
    exit 1
  fi
  sleep "$CHECK_INTERVAL"
done

# Redirect all stdout and stderr based on systemd presence
if [[ -n "${LOGFILE:-}" ]] && [[ "$LOGFILE" == "/dev/kmsg" ]]; then
  exec >> "$LOGFILE" 2>&1
fi

# If not running under systemd, fork into background
if [ -z "$INVOCATION_ID" ]; then
    # Check for existing instances
    check_existing_instance
    
    # Already in background? If so, don't fork again
    if [ -z "$IMMICH_MONITOR_FORKED" ]; then
        export IMMICH_MONITOR_FORKED=1
        echo $$ > "$PIDFILE"
        trap cleanup EXIT
        nohup "$0" "$@" >/dev/null 2>&1 &
        exit 0
    fi
else
    # Running under systemd - create PID file for monitoring
    echo $$ > "$PIDFILE"
    trap cleanup EXIT
fi

cpuavg() {
  local cpu_sum=0
  local container_count=0
  
  # Get list of running containers matching filter
  local containers
  containers=$(docker ps -q --filter "name=$CONTAINER_FILTER" 2>/dev/null) || {
    echo "$NAME: [WARN] Failed to get container list, returning 0"
    echo 0
    return
  }
  
  # If no containers found, return 0
  if [[ -z "$containers" ]]; then
    echo 0
    return
  fi
  
  # Get CPU stats for each container with error handling
  while IFS= read -r container_id; do
    if [[ -n "$container_id" ]]; then
      local cpu_perc
      cpu_perc=$(docker stats "$container_id" --no-stream --format "{{.CPUPerc}}" 2>/dev/null | sed 's/%//' 2>/dev/null) || {
        echo "$NAME: [WARN] Failed to get stats for container $container_id"
        continue
      }
      # Only add if we got a valid number
      if [[ "$cpu_perc" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        cpu_sum=$(( cpu_sum + ${cpu_perc%.*} ))
        ((container_count++))
      fi
    fi
  done <<< "$containers"
  
  echo "$cpu_sum"
}

# Define deterministic container order for freeze/resume operations
# Freeze order: dependents first (web -> server -> services -> databases)
FREEZE_ORDER=("immich-web" "immich-server" "immich-machine-learning" "immich-typesense" "immich-redis" "immich-postgres")
# Resume order: dependencies first (databases -> services -> server -> web)  
RESUME_ORDER=("immich-postgres" "immich-redis" "immich-typesense" "immich-machine-learning" "immich-server" "immich-web")

# Dynamic container discovery function
discover_containers() {
  # Get all running containers matching the filter
  local all_containers
  all_containers=$(docker ps --filter "name=$CONTAINER_FILTER" --format "{{.Names}}" 2>/dev/null | sort) || return 1
  
  # Try to order them deterministically based on known patterns
  local ordered_containers=()
  
  # Add containers in preferred freeze order if they exist
  for name in "${FREEZE_ORDER[@]}"; do
    if echo "$all_containers" | grep -q "^${name}$"; then
      ordered_containers+=("$name")
    fi
  done
  
  # Add any remaining containers that weren't in the preferred order
  for name in $all_containers; do
    if [[ ! " ${ordered_containers[*]} " =~ " ${name} " ]]; then
      ordered_containers+=("$name")
    fi
  done
  
  # Return the ordered list
  printf '%s\n' "${ordered_containers[@]}"
}

# Get containers in freeze order (reverse dependency)
get_freeze_order() {
  local result
  result=$(discover_containers 2>/dev/null | tac 2>/dev/null || true)
  
  # Fallback to hardcoded array if dynamic discovery fails
  if [[ -z "$result" ]]; then
    printf '%s\n' "${FREEZE_ORDER[@]}"
  else
    echo "$result"
  fi
}

# Get containers in resume order (dependency order)
get_resume_order() {
  local result
  result=$(discover_containers 2>/dev/null || true)
  
  # Fallback to hardcoded array if dynamic discovery fails
  if [[ -z "$result" ]]; then
    printf '%s\n' "${RESUME_ORDER[@]}"
  else
    echo "$result"
  fi
}

freeze() {
  echo "$NAME: [INFO] $CONTAINER_FILTER containers: freeze"
  local containers
  containers=$(get_freeze_order)
  
  if [[ -z "$containers" ]]; then
    echo "$NAME: [ERROR] No containers found for freezing"
    return 1
  fi
  
  while IFS= read -r name; do
    if [[ -n "$name" ]] && docker ps --filter "name=^${name}$" --format "{{.Names}}" 2>/dev/null | grep -q "^${name}$"; then
      echo "$NAME: [INFO] pausing container: $name"
      docker pause "$name" > /dev/null 2>&1 || {
        echo "$NAME: [WARN] Failed to pause container: $name"
      }
    fi
  done <<< "$containers"
  echo "$NAME: [INFO] Container freeze sequence completed"
  frozen=true
}

resume() {
  echo "$NAME: [INFO] $CONTAINER_FILTER containers: resume"
  local containers
  containers=$(get_resume_order)
  
  if [[ -z "$containers" ]]; then
    echo "$NAME: [ERROR] No containers found for resuming"
    return 1
  fi
  
  # Resume containers sequentially with health checks
  while IFS= read -r name; do
    if [[ -n "$name" ]]; then
      echo "$NAME: [INFO] resuming container: $name"
      docker unpause "$name" > /dev/null 2>&1 || {
        echo "$NAME: [WARN] Failed to resume container: $name"
        continue
      }
      
      # Wait for container to stabilize
      sleep 1
      
      # Check if container is healthy after resume
      if ! check_single_container_health "$name"; then
        echo "$NAME: [INFO] Restarting unhealthy container: $name"
        docker restart "$name" >/dev/null 2>&1 || {
          echo "$NAME: [ERROR] Failed to restart container: $name"
          continue
        }
        
        # Wait for restart and verify health
        sleep 3
        if ! check_single_container_health "$name"; then
          echo "$NAME: [ERROR] Container $name still unhealthy after restart"
        fi
      fi
    fi
  done <<< "$containers"
  
  echo "$NAME: [INFO] Container resume sequence completed"
  frozen=false
  last_unpause_time=$(date +%s)
}

# Check health of a single container
check_single_container_health() {
  local name="$1"
  
  # Check if container is running
  if ! docker ps --filter "name=^${name}$" --filter "status=running" --format "{{.Names}}" 2>/dev/null | grep -q "^${name}$"; then
    echo "$NAME: [WARN] Container $name is not running"
    return 1
  fi
  
  # Check container health (if healthcheck is configured)
  local health_status
  health_status=$(docker inspect "$name" --format "{{.State.Health.Status}}" 2>/dev/null || echo "unknown")
  
  if [[ "$health_status" == "healthy" ]]; then
    echo "$NAME: [DEBUG] Container $name health status: healthy"
    return 0
  elif [[ "$health_status" == "unhealthy" ]]; then
    echo "$NAME: [WARN] Container $name health status: unhealthy"
    return 1
  elif [[ "$health_status" == "unknown" ]]; then
    # No healthcheck configured, check if container is responding
    if [[ "$name" == *"postgres"* ]]; then
      if docker exec "$name" pg_isready -U postgres -h localhost >/dev/null 2>&1; then
        echo "$NAME: [DEBUG] PostgreSQL container $name responding"
        return 0
      else
        echo "$NAME: [WARN] PostgreSQL container $name not responding"
        return 1
      fi
    elif [[ "$name" == *"redis"* ]]; then
      if docker exec "$name" redis-cli ping >/dev/null 2>&1; then
        echo "$NAME: [DEBUG] Redis container $name responding"
        return 0
      else
        echo "$NAME: [WARN] Redis container $name not responding"
        return 1
      fi
    else
      # For other containers without healthchecks, assume healthy if running
      echo "$NAME: [DEBUG] Container $name running (no healthcheck)"
      return 0
    fi
  fi

  return 0
}

wakeup() {
  # Extract packet counter for the DNAT rule on the wakeup port
  local current_pkts=$(
      nft list table ip nat 2>/dev/null \
          | grep -E "tcp dport ${PORT_WAKEUP}\b" \
          | grep -E "dnat" \
          | grep -o "packets [0-9]*" \
          | awk '{print $2}'
  )
  
  # First run: initialize and return false
  if [[ -z "${LAST_PKTS:-}" ]]; then
      LAST_PKTS=$current_pkts
      return 1
  fi

  # If packet count increased → external traffic detected
  if (( current_pkts > LAST_PKTS )); then
      LAST_PKTS=$current_pkts
      return 0
  fi

  # No new packets
  LAST_PKTS=$current_pkts
  return 1
}

in_any_window() {
  local now=$(date +%s)
  local today_date
  today_date=$(date -u +%Y-%m-%d)  # Use UTC date for consistency

  for i in "${!SCHEDULED_STARTS[@]}"; do
    local start_time="${SCHEDULED_STARTS[$i]}"
    local duration="${SCHEDULED_DURATIONS[$i]}"
    
    # Validate time format (HH:MM)
    if [[ ! "$start_time" =~ ^[0-2][0-9]:[0-5][0-9]$ ]]; then
      echo "$NAME: [WARN] Invalid time format in SCHEDULED_STARTS[$i]: $start_time"
      continue
    fi
    
    # Parse start time in UTC for today
    local start_datetime="${today_date}T${start_time}:00Z"
    local start
    start=$(date -d "$start_datetime" +%s 2>/dev/null) || {
      echo "$NAME: [WARN] Failed to parse scheduled time: $start_datetime"
      continue
    }
    
    local end=$(( start + duration ))

    # Handle wraparound to next day
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

  # Adaptive polling: slower when frozen, faster when monitoring
  if $frozen; then
    sleep "$IDLE_CHECK_INTERVAL"
  else
    sleep "$CHECK_INTERVAL"
  fi
done
)
