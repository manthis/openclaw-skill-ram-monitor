# RAM Monitor Skill

**Purpose:** Monitor RAM usage with tiered alerts and automatic process killing at critical levels.

## Overview

This skill monitors system RAM usage and takes action based on configurable thresholds:
- **< 90%** → Silence (no alert, no action)
- **90-94%** → Alert via Telegram with top memory consumers (monitoring only)
- **95%+** → Kill priority processes (Brave, iTerm2, safe-to-kill), then ask user

Designed to integrate with OpenClaw's heartbeat system for periodic monitoring.

## Features

- **Tiered response** - Alert-only at 90%, auto-kill at 95%
- **Priority killing** - Brave Browser → iTerm2 → safe-to-kill processes
- **Strict protection** - Never kills openclaw-gateway, Beeper, or system processes
- **JSON output** - Structured data for easy parsing
- **Kill logging** - All kills logged to `~/logs/ram-kills.log`
- **Dry-run mode** - Test without actually killing anything

## Requirements

- **bash** (4.0+)
- **top** - System monitoring (standard on macOS)
- **bc** - Floating point calculations
- **ps** - Process listing (standard)

## Installation

### Quick Install

```bash
git clone https://github.com/manthis/openclaw-skill-ram-monitor.git ~/.openclaw/workspace/skills/ram-monitor
cp ~/.openclaw/workspace/skills/ram-monitor/scripts/check-ram-usage.sh ~/bin/
chmod +x ~/bin/check-ram-usage.sh
```

## Configuration

### Thresholds

| Threshold | Level | Action |
|-----------|-------|--------|
| < 90% | `ok` | Silence |
| 90-94% | `warning` | Alert with top processes |
| ≥ 95% | `critical` | Kill priority processes + alert |

### Protected Processes (NEVER killed)

- `openclaw-gateway`
- `Beeper` (all processes)
- System processes (`kernel_task`, `WindowServer`, `launchd`, `loginwindow`, `systemstats`, `sshd`)
- Processes owned by system users (`_*`)

### Kill Priority at 95%

1. **ALL Brave Browser** processes
2. **ALL iTerm2** processes
3. Safe-to-kill processes (node orphans, test runners, cache/build processes)

After killing → agent asks Max if more action needed.

## Usage

### Standalone

```bash
~/bin/check-ram-usage.sh          # Run with real kills
~/bin/check-ram-usage.sh --dry-run # Test mode (no kills)
```

### Integration with OpenClaw HEARTBEAT

Add to `HEARTBEAT.md`:

```markdown
## RAM Monitoring (every heartbeat)
- Run `~/bin/check-ram-usage.sh`
- If level=warning (90-94%) → Alert Telegram with top processes
- If level=critical (95%+) → Alert Telegram with killed processes, ask Max if more needed
- If level=ok → Silence
```

**Agent behavior:**

```bash
RAM_JSON=$(~/bin/check-ram-usage.sh)
LEVEL=$(echo "$RAM_JSON" | jq -r '.level')

if [ "$LEVEL" == "warning" ]; then
    # Send alert with top processes list
elif [ "$LEVEL" == "critical" ]; then
    # Send alert with killed processes + ask Max
fi
```

## Output Format

### JSON Structure

```json
{
  "timestamp": "2026-02-18T20:00:00Z",
  "ram_pct": 92.5,
  "ram_used_gb": 14.80,
  "ram_total_gb": 16.00,
  "level": "warning",
  "top_processes": [
    {"pid": 1234, "name": "Brave", "ram_mb": 2048.0, "user": "manthis"}
  ],
  "killed": []
}
```

### Alert Examples

**Warning (90-94%):**
```
⚠️ RAM Warning: 92.5%

Memory: 14.80GB / 16.00GB

Top Memory Consumers:
1. Brave Browser - 2048MB
2. iTerm2 - 512MB
3. node - 384MB

No action taken. Monitoring...
```

**Critical (95%+):**
```
🚨 RAM Critical: 96.2%

Memory: 15.39GB / 16.00GB

KILLED PROCESSES:
- Brave Browser (PID 1234) - 2048MB
- iTerm2 (PID 5678) - 512MB

Top Remaining Processes:
1. kernel_task - 1024MB (protected)

Freed ~2560MB. Need more cleanup?
```

## Kill Log

All kills are logged to `~/logs/ram-kills.log`:
```
# Format: timestamp | PID | process_name | ram_mb | reason
2026-02-18T20:00:00Z | 1234 | Brave Browser | 2048.0 | 95% - Brave priority kill
```

## Security Considerations

- No hardcoded credentials
- Read-only operations below 95%
- Protected process list prevents catastrophic kills
- Dry-run mode for safe testing
- All kills logged for audit

## License

MIT License

## Author

Created for OpenClaw by Maxime Auburtin
