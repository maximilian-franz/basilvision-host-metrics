#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  # shellcheck source=.env
  source "$SCRIPT_DIR/.env"
fi

get_load_1m() {
  awk '{print $1}' /proc/loadavg
}

get_memory_used_percent() {
  awk '
    /^MemTotal:/ { total=$2 }
    /^MemAvailable:/ { avail=$2 }
    END {
      if (total == 0) {
        print "0.00"
        exit 1
      }
      used=((total-avail)/total)*100
      printf "%.2f", used
    }
  ' /proc/meminfo
}

get_cpu_temp_c() {
  local thermal_path="/sys/class/thermal/thermal_zone0/temp"

  if [[ -f "$thermal_path" ]]; then
    awk '{ printf "%.2f", $1 / 1000 }' "$thermal_path"
    return 0
  fi

  if command -v vcgencmd >/dev/null 2>&1; then
    vcgencmd measure_temp | sed -E "s/temp=([0-9.]+).*/\1/"
    return 0
  fi

  return 1
}

get_systemd_is_active() {
  local unit="$1"
  if systemctl is-active --quiet "$unit"; then
    echo 1
  else
    echo 0
  fi
}

get_systemd_is_failed() {
  local unit="$1"
  local state
  state="$(systemctl is-failed "$unit" 2>/dev/null || true)"
  if [[ "$state" == "failed" ]]; then
    echo 1
  else
    echo 0
  fi
}

get_uptime_seconds() {
  awk '{ printf "%.2f", $1 }' /proc/uptime
}

get_root_disk_used_percent() {
  df -P / | awk 'NR==2 {gsub(/%/, "", $5); printf "%.2f", $5}'
}

main() {
  local load_1m
  local memory_used_percent
  local uptime_seconds
  local disk_root_used_percent
  local motion_service_active
  local motion_snapshot_service_active
  local motion_snapshot_timer_active
  local motion_service_failed
  local motion_snapshot_service_failed
  local cpu_temp_c=""
  local sensors_json
  local payload

  load_1m="$(get_load_1m)"
  memory_used_percent="$(get_memory_used_percent)"
  uptime_seconds="$(get_uptime_seconds)"
  disk_root_used_percent="$(get_root_disk_used_percent)"

  motion_service_active="$(get_systemd_is_active "motion.service")"
  motion_snapshot_service_active="$(get_systemd_is_active "motion-snapshot.service")"
  motion_snapshot_timer_active="$(get_systemd_is_active "motion-snapshot.timer")"

  motion_service_failed="$(get_systemd_is_failed "motion.service")"
  motion_snapshot_service_failed="$(get_systemd_is_failed "motion-snapshot.service")"

  if cpu_temp_c="$(get_cpu_temp_c 2>/dev/null)"; then
    :
  else
    cpu_temp_c=""
  fi

  sensors_json=$(cat <<EOF
{
  "heartbeat": { "value": 1, "unit": "bool" },
  "load_1m": { "value": $load_1m, "unit": "load" },
  "memory_used_percent": { "value": $memory_used_percent, "unit": "%" },
  "motion_service_active": { "value": $motion_service_active, "unit": "bool" },
  "motion_snapshot_service_active": { "value": $motion_snapshot_service_active, "unit": "bool" },
  "motion_snapshot_timer_active": { "value": $motion_snapshot_timer_active, "unit": "bool" },
  "motion_service_failed": { "value": $motion_service_failed, "unit": "bool" },
  "motion_snapshot_service_failed": { "value": $motion_snapshot_service_failed, "unit": "bool" },
  "uptime_seconds": { "value": $uptime_seconds, "unit": "s" },
  "disk_root_used_percent": { "value": $disk_root_used_percent, "unit": "%" }
}
EOF
)

  if [[ -n "$cpu_temp_c" ]]; then
    sensors_json=$(cat <<EOF
{
  "heartbeat": { "value": 1, "unit": "bool" },
  "load_1m": { "value": $load_1m, "unit": "load" },
  "memory_used_percent": { "value": $memory_used_percent, "unit": "%" },
  "cpu_temp_c": { "value": $cpu_temp_c, "unit": "C" },
  "motion_service_active": { "value": $motion_service_active, "unit": "bool" },
  "motion_snapshot_service_active": { "value": $motion_snapshot_service_active, "unit": "bool" },
  "motion_snapshot_timer_active": { "value": $motion_snapshot_timer_active, "unit": "bool" },
  "motion_service_failed": { "value": $motion_service_failed, "unit": "bool" },
  "motion_snapshot_service_failed": { "value": $motion_snapshot_service_failed, "unit": "bool" },
  "uptime_seconds": { "value": $uptime_seconds, "unit": "s" },
  "disk_root_used_percent": { "value": $disk_root_used_percent, "unit": "%" }
}
EOF
)
  fi

  payload=$(cat <<EOF
{
  "name": "$NAME",
  "device_uuid": "$DEVICE_UUID",
  "sensors": $sensors_json
}
EOF
)

  echo "$payload"

  curl --fail --show-error --silent \
    -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "x-api-key: $API_KEY" \
    -d "$payload"

  echo
  echo "POST succeeded"
}

main "$@"
