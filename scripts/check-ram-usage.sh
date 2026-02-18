#!/bin/bash

# RAM Monitoring Script for macOS
# Tiered alerts with automatic process killing at critical levels
# Thresholds: <90% silence, 90-94% alert only, 95%+ kill priority processes
# Usage: ./check-ram-usage.sh [--dry-run]

set -euo pipefail

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
fi

LOG_FILE="$HOME/logs/ram-kills.log"
mkdir -p "$(dirname "$LOG_FILE")"

if [[ ! -f "$LOG_FILE" ]]; then
    echo "# RAM Kill Log - Created $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOG_FILE"
    echo "# Format: timestamp | PID | process_name | ram_mb | reason" >> "$LOG_FILE"
    echo "---" >> "$LOG_FILE"
fi

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Parse PhysMem output
MEM_INFO=$(top -l 1 | grep PhysMem || echo "PhysMem: 0M used, 0M unused")

USED=$(echo "$MEM_INFO" | sed -E 's/.*PhysMem: ([0-9.]+)([MG]) used.*/\1 \2/')
UNUSED=$(echo "$MEM_INFO" | sed -E 's/.*[,\)] ([0-9.]+)([MG]) unused.*/\1 \2/')

used_value=$(echo "$USED" | awk '{print $1}')
used_unit=$(echo "$USED" | awk '{print $2}')
unused_value=$(echo "$UNUSED" | awk '{print $1}')
unused_unit=$(echo "$UNUSED" | awk '{print $2}')

if [[ "$used_unit" == "G" ]]; then
    used_mb=$(echo "$used_value * 1024" | bc)
else
    used_mb=$used_value
fi

if [[ "$unused_unit" == "G" ]]; then
    unused_mb=$(echo "$unused_value * 1024" | bc)
else
    unused_mb=$unused_value
fi

total_mb=$(echo "$used_mb + $unused_mb" | bc -l)
total_gb=$(echo "$total_mb / 1024" | bc -l | xargs printf "%.2f")
used_gb=$(echo "$used_mb / 1024" | bc -l | xargs printf "%.2f")
ram_pct=$(echo "($used_mb / $total_mb) * 100" | bc -l | xargs printf "%.1f")

# Get top 10 memory processes
TOP_PROCS=$(ps aux | awk 'NR>1 {print $2, $4, $11}' | sort -nrk2 | head -10)

# Build JSON array for top processes
TOP_PROCS_JSON="["
first=true
while IFS= read -r line; do
    pid=$(echo "$line" | awk '{print $1}')
    mem_pct=$(echo "$line" | awk '{print $2}')
    cmd=$(echo "$line" | awk '{for(i=3;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ $//')
    user=$(ps -p "$pid" -o user= 2>/dev/null || echo "unknown")
    proc_ram_mb=$(echo "($mem_pct / 100) * $total_mb" | bc -l | xargs printf "%.1f")
    proc_name=$(basename "$cmd" | cut -d' ' -f1)

    if [[ "$first" == true ]]; then
        first=false
    else
        TOP_PROCS_JSON+=","
    fi

    TOP_PROCS_JSON+="{\"pid\":$pid,\"name\":\"$proc_name\",\"ram_mb\":$proc_ram_mb,\"user\":\"$user\"}"
done <<< "$TOP_PROCS"
TOP_PROCS_JSON+="]"

# Protected processes
GATEWAY_PID=$(ps aux | grep -E '[o]penclaw-gateway' | awk '{print $2}' || echo "")
BEEPER_PIDS=$(ps aux | grep -E '[B]eeper' | awk '{print $2}' || echo "")

# Check if process is protected
is_protected() {
    local pid=$1
    local cmd=$2
    local user=$3

    [[ "$pid" == "1" ]] && return 0
    [[ -n "$GATEWAY_PID" ]] && [[ "$pid" == "$GATEWAY_PID" ]] && return 0
    echo "$BEEPER_PIDS" | grep -qw "$pid" && return 0
    echo "$cmd" | grep -qiE 'Beeper' && return 0
    # Never kill Proton Mail Bridge (email sync)
    echo "$cmd" | grep -qiE 'Proton Mail Bridge|bridge-gui|/bridge --grpc' && return 0
    [[ "$user" =~ ^_ ]] && return 0
    echo "$cmd" | grep -qE '(kernel_task|loginwindow|WindowServer|launchd|systemstats|sshd)' && return 0
    return 1
}

# Helper: safe-to-kill non-priority processes
is_safe_to_kill() {
    local pid=$1
    local cmd=$2
    local user=$3
    local age_sec=${4:-0}

    is_protected "$pid" "$cmd" "$user" && return 1

    # Safe: node orphans, test runners, cache/build processes
    echo "$cmd" | grep -qE '(pnpm test|jest|/tmp/|cache|build)' && return 0
    echo "$cmd" | grep -q 'node' && ! ps -p $(ps -o ppid= -p "$pid" 2>/dev/null || echo "1") &>/dev/null && return 0
    echo "$cmd" | grep -q 'python' && [[ $age_sec -gt 3600 ]] && return 0

    return 1
}

kill_process() {
    local pid=$1
    local name=$2
    local ram_mb=$3
    local reason=$4

    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY-RUN] Would kill PID $pid ($name, ${ram_mb}MB) - $reason" >&2
    else
        if kill -9 "$pid" 2>/dev/null; then
            echo "$TIMESTAMP | $pid | $name | $ram_mb | $reason" >> "$LOG_FILE"
            echo "Killed PID $pid ($name, ${ram_mb}MB) - $reason" >&2
        else
            echo "Failed to kill PID $pid" >&2
            return 1
        fi
    fi
    return 0
}

# Determine level and action
LEVEL="ok"
KILLED_JSON="[]"

if (( $(echo "$ram_pct >= 95" | bc -l) )); then
    LEVEL="critical"
    KILLED_ARRAY=()

    # PRIORITY 1: Kill ALL Brave Browser processes
    echo "95% threshold - killing ALL Brave processes..." >&2
    BRAVE_PIDS=$(ps aux | grep -iE '[B]rave Browser' | awk '{print $2}')
    if [[ -n "$BRAVE_PIDS" ]]; then
        while IFS= read -r brave_pid; do
            [[ -z "$brave_pid" ]] && continue
            brave_mem_pct=$(ps aux | awk -v pid="$brave_pid" '$2 == pid {print $4}')
            brave_ram_mb=$(echo "($brave_mem_pct / 100) * $total_mb" | bc -l | xargs printf "%.1f")
            if kill_process "$brave_pid" "Brave Browser" "$brave_ram_mb" "95% - Brave priority kill"; then
                KILLED_ARRAY+=("{\"pid\":$brave_pid,\"name\":\"Brave Browser\",\"ram_mb\":$brave_ram_mb,\"reason\":\"95% - Brave priority\"}")
            fi
        done <<< "$BRAVE_PIDS"
    fi

    # PRIORITY 2: Kill ALL iTerm2 processes
    echo "95% threshold - killing ALL iTerm2 processes..." >&2
    ITERM_PIDS=$(ps aux | grep -iE '[i]Term' | awk '{print $2}')
    if [[ -n "$ITERM_PIDS" ]]; then
        while IFS= read -r iterm_pid; do
            [[ -z "$iterm_pid" ]] && continue
            iterm_mem_pct=$(ps aux | awk -v pid="$iterm_pid" '$2 == pid {print $4}')
            iterm_ram_mb=$(echo "($iterm_mem_pct / 100) * $total_mb" | bc -l | xargs printf "%.1f")
            if kill_process "$iterm_pid" "iTerm2" "$iterm_ram_mb" "95% - iTerm2 priority kill"; then
                KILLED_ARRAY+=("{\"pid\":$iterm_pid,\"name\":\"iTerm2\",\"ram_mb\":$iterm_ram_mb,\"reason\":\"95% - iTerm2 priority\"}")
            fi
        done <<< "$ITERM_PIDS"
    fi

    # PRIORITY 3: Kill other safe-to-kill processes
    echo "95% threshold - checking safe-to-kill processes..." >&2
    while IFS= read -r line; do
        pid=$(echo "$line" | awk '{print $1}')
        mem_pct=$(echo "$line" | awk '{print $2}')
        cmd=$(echo "$line" | awk '{for(i=3;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ $//')
        user=$(ps -p "$pid" -o user= 2>/dev/null || echo "unknown")

        echo "$cmd" | grep -qiE 'Brave|iTerm' && continue

        elapsed=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ' || echo "0")
        age_sec=0
        if [[ "$elapsed" =~ ([0-9]+)-([0-9]+):([0-9]+):([0-9]+) ]]; then
            age_sec=$((${BASH_REMATCH[1]} * 86400 + ${BASH_REMATCH[2]} * 3600 + ${BASH_REMATCH[3]} * 60 + ${BASH_REMATCH[4]}))
        elif [[ "$elapsed" =~ ([0-9]+):([0-9]+):([0-9]+) ]]; then
            age_sec=$((${BASH_REMATCH[1]} * 3600 + ${BASH_REMATCH[2]} * 60 + ${BASH_REMATCH[3]}))
        elif [[ "$elapsed" =~ ([0-9]+):([0-9]+) ]]; then
            age_sec=$((${BASH_REMATCH[1]} * 60 + ${BASH_REMATCH[2]}))
        fi

        proc_ram_mb=$(echo "($mem_pct / 100) * $total_mb" | bc -l | xargs printf "%.1f")
        proc_name=$(basename "$cmd" | cut -d' ' -f1)

        if is_safe_to_kill "$pid" "$cmd" "$user" "$age_sec"; then
            if kill_process "$pid" "$proc_name" "$proc_ram_mb" "95% - safe to kill"; then
                KILLED_ARRAY+=("{\"pid\":$pid,\"name\":\"$proc_name\",\"ram_mb\":$proc_ram_mb,\"reason\":\"95% - safe to kill\"}")
            fi
        fi
    done <<< "$TOP_PROCS"

    # Build killed JSON
    if [[ ${#KILLED_ARRAY[@]} -gt 0 ]]; then
        KILLED_JSON="["
        for i in "${!KILLED_ARRAY[@]}"; do
            [[ $i -gt 0 ]] && KILLED_JSON+=","
            KILLED_JSON+="${KILLED_ARRAY[$i]}"
        done
        KILLED_JSON+="]"
    fi

elif (( $(echo "$ram_pct >= 90" | bc -l) )); then
    LEVEL="warning"
    # 90-94%: Alert only, NO killing. Just report top processes.
fi

# Output JSON
cat <<EOF
{
  "timestamp": "$TIMESTAMP",
  "ram_pct": $ram_pct,
  "ram_used_gb": $used_gb,
  "ram_total_gb": $total_gb,
  "level": "$LEVEL",
  "top_processes": $TOP_PROCS_JSON,
  "killed": $KILLED_JSON
}
EOF
