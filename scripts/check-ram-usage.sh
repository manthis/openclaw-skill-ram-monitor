#!/bin/bash

# RAM Monitoring Script for macOS
# Tiered alerts with automatic process killing at critical levels
# Thresholds: <90% silence, 90-94% alert only, 95%+ kill priority processes
# Usage: ./check-ram-usage.sh [--dry-run]
#
# Performance notes:
# - Single `ps aux` call cached in variable (was called 5+ times)
# - awk used for arithmetic instead of bc (faster, no subshell)
# - JSON built via jq at end instead of manual string concatenation

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

# Parse PhysMem — single call
MEM_INFO=$(top -l 1 | grep PhysMem || echo "PhysMem: 0M used, 0M unused")

USED=$(echo "$MEM_INFO" | sed -E 's/.*PhysMem: ([0-9.]+)([MG]) used.*/\1 \2/')
UNUSED=$(echo "$MEM_INFO" | sed -E 's/.*[,\)] ([0-9.]+)([MG]) unused.*/\1 \2/')

# Use awk for all arithmetic (avoids multiple bc calls)
read -r used_mb unused_mb total_mb total_gb used_gb ram_pct <<< $(awk -v uv="$(echo "$USED" | awk '{print $1}')" \
    -v uu="$(echo "$USED" | awk '{print $2}')" \
    -v fv="$(echo "$UNUSED" | awk '{print $1}')" \
    -v fu="$(echo "$UNUSED" | awk '{print $2}')" '
BEGIN {
    um = (uu == "G") ? uv * 1024 : uv
    fm = (fu == "G") ? fv * 1024 : fv
    tm = um + fm
    printf "%.0f %.0f %.0f %.2f %.2f %.1f\n", um, fm, tm, tm/1024, um/1024, (um/tm)*100
}')

# Cache ps aux output once (was called 5+ times in original)
PS_CACHE=$(ps aux)

# Get top 10 memory processes — build JSON via jq (no manual string building)
TOP_PROCS_RAW=$(echo "$PS_CACHE" | awk 'NR>1 {print $2, $4, $11}' | sort -nrk2 | head -10)
TOP_PROCS_JSON=$(echo "$TOP_PROCS_RAW" | while IFS= read -r line; do
    pid=$(echo "$line" | awk '{print $1}')
    mem_pct=$(echo "$line" | awk '{print $2}')
    cmd=$(echo "$line" | awk '{for(i=3;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ $//')
    user=$(echo "$PS_CACHE" | awk -v p="$pid" '$2 == p {print $1; exit}')
    proc_ram_mb=$(awk "BEGIN {printf \"%.1f\", ($mem_pct / 100) * $total_mb}")
    proc_name=$(basename "$cmd" | cut -d' ' -f1)
    printf '{"pid":%s,"name":"%s","ram_mb":%s,"user":"%s"}\n' "$pid" "$proc_name" "$proc_ram_mb" "${user:-unknown}"
done | jq -s '.')

# Protected processes — single grep calls
GATEWAY_PID=$(echo "$PS_CACHE" | grep -E '[o]penclaw-gateway' | awk '{print $2}' || echo "")
BEEPER_PIDS=$(echo "$PS_CACHE" | grep -E '[B]eeper' | awk '{print $2}' || echo "")

is_protected() {
    local pid=$1 cmd=$2 user=$3
    [[ "$pid" == "1" ]] && return 0
    [[ -n "$GATEWAY_PID" && "$pid" == "$GATEWAY_PID" ]] && return 0
    echo "$BEEPER_PIDS" | grep -qw "$pid" && return 0
    echo "$cmd" | grep -qiE 'Beeper' && return 0
    echo "$cmd" | grep -qiE 'Proton Mail Bridge|bridge-gui|/bridge --grpc' && return 0
    [[ "$user" =~ ^_ ]] && return 0
    echo "$cmd" | grep -qE '(kernel_task|loginwindow|WindowServer|launchd|systemstats|sshd)' && return 0
    return 1
}

is_safe_to_kill() {
    local pid=$1 cmd=$2 user=$3 age_sec=${4:-0}
    is_protected "$pid" "$cmd" "$user" && return 1
    echo "$cmd" | grep -qE '(pnpm test|jest|/tmp/|cache|build)' && return 0
    if echo "$cmd" | grep -q 'node'; then
        local ppid
        ppid=$(echo "$PS_CACHE" | awk -v p="$pid" '$2 == p {print $3; exit}')
        echo "$PS_CACHE" | awk -v p="$ppid" '$2 == p {found=1} END {exit !found}' || return 0
    fi
    echo "$cmd" | grep -q 'python' && [[ $age_sec -gt 3600 ]] && return 0
    return 1
}

kill_process() {
    local pid=$1 name=$2 ram_mb=$3 reason=$4
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
KILLED_NDJSON=""

if awk "BEGIN {exit !($ram_pct >= 95)}"; then
    LEVEL="critical"

    # PRIORITY 1: Kill ALL Brave Browser processes
    echo "95% threshold - killing ALL Brave processes..." >&2
    echo "$PS_CACHE" | grep -iE '[B]rave Browser' | awk '{print $2, $4}' | while read -r brave_pid brave_mem_pct; do
        [[ -z "$brave_pid" ]] && continue
        brave_ram_mb=$(awk "BEGIN {printf \"%.1f\", ($brave_mem_pct / 100) * $total_mb}")
        if kill_process "$brave_pid" "Brave Browser" "$brave_ram_mb" "95% - Brave priority kill"; then
            echo "{\"pid\":${brave_pid},\"name\":\"Brave Browser\",\"ram_mb\":${brave_ram_mb},\"reason\":\"95% - Brave priority\"}"
        fi
    done > /tmp/ram-killed.$$.ndjson

    # PRIORITY 2: Kill ALL iTerm2 processes
    echo "95% threshold - killing ALL iTerm2 processes..." >&2
    echo "$PS_CACHE" | grep -iE '[i]Term' | awk '{print $2, $4}' | while read -r iterm_pid iterm_mem_pct; do
        [[ -z "$iterm_pid" ]] && continue
        iterm_ram_mb=$(awk "BEGIN {printf \"%.1f\", ($iterm_mem_pct / 100) * $total_mb}")
        if kill_process "$iterm_pid" "iTerm2" "$iterm_ram_mb" "95% - iTerm2 priority kill"; then
            echo "{\"pid\":${iterm_pid},\"name\":\"iTerm2\",\"ram_mb\":${iterm_ram_mb},\"reason\":\"95% - iTerm2 priority\"}"
        fi
    done >> /tmp/ram-killed.$$.ndjson

    # PRIORITY 3: Kill other safe-to-kill processes
    echo "95% threshold - checking safe-to-kill processes..." >&2
    echo "$TOP_PROCS_RAW" | while IFS= read -r line; do
        pid=$(echo "$line" | awk '{print $1}')
        mem_pct=$(echo "$line" | awk '{print $2}')
        cmd=$(echo "$line" | awk '{for(i=3;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ $//')
        user=$(echo "$PS_CACHE" | awk -v p="$pid" '$2 == p {print $1; exit}')

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

        proc_ram_mb=$(awk "BEGIN {printf \"%.1f\", ($mem_pct / 100) * $total_mb}")
        proc_name=$(basename "$cmd" | cut -d' ' -f1)

        if is_safe_to_kill "$pid" "$cmd" "${user:-unknown}" "$age_sec"; then
            if kill_process "$pid" "$proc_name" "$proc_ram_mb" "95% - safe to kill"; then
                echo "{\"pid\":${pid},\"name\":\"${proc_name}\",\"ram_mb\":${proc_ram_mb},\"reason\":\"95% - safe to kill\"}"
            fi
        fi
    done >> /tmp/ram-killed.$$.ndjson

    KILLED_NDJSON=$(cat /tmp/ram-killed.$$.ndjson 2>/dev/null || echo "")
    rm -f /tmp/ram-killed.$$.ndjson

elif awk "BEGIN {exit !($ram_pct >= 90)}"; then
    LEVEL="warning"
fi

# Build killed JSON array
if [[ -n "$KILLED_NDJSON" ]]; then
    KILLED_JSON=$(echo "$KILLED_NDJSON" | jq -s '.')
else
    KILLED_JSON="[]"
fi

# Output JSON — single jq call
jq -n \
    --arg ts "$TIMESTAMP" \
    --argjson ram_pct "$ram_pct" \
    --arg ram_used_gb "$used_gb" \
    --arg ram_total_gb "$total_gb" \
    --arg level "$LEVEL" \
    --argjson top "$TOP_PROCS_JSON" \
    --argjson killed "$KILLED_JSON" \
    '{
        timestamp: $ts,
        ram_pct: $ram_pct,
        ram_used_gb: ($ram_used_gb | tonumber),
        ram_total_gb: ($ram_total_gb | tonumber),
        level: $level,
        top_processes: $top,
        killed: $killed
    }'
