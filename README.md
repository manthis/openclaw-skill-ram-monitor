# OpenClaw RAM Monitor Skill

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform](https://img.shields.io/badge/platform-macOS-lightgrey.svg)

A proactive RAM monitoring skill for [OpenClaw](https://github.com/openclaw/openclaw) with tiered alerts and automatic process killing.

## Features

- 🔇 **< 90%** → Total silence
- ⚠️ **90-94%** → Telegram alert with top memory consumers
- 🚨 **95%+** → Auto-kill priority processes (Brave, iTerm2, safe-to-kill)
- 🛡️ **Protected processes** → openclaw-gateway, Beeper, system processes never touched
- 📝 **Kill logging** → All kills logged to `~/logs/ram-kills.log`
- 🧪 **Dry-run mode** → Test without killing

## Quick Start

```bash
# Clone into OpenClaw workspace
git clone https://github.com/manthis/openclaw-skill-ram-monitor.git ~/.openclaw/workspace/skills/ram-monitor

# Install script
cp ~/.openclaw/workspace/skills/ram-monitor/scripts/check-ram-usage.sh ~/bin/
chmod +x ~/bin/check-ram-usage.sh

# Test it
~/bin/check-ram-usage.sh --dry-run | jq .
```

## Requirements

- **macOS** (uses `top` PhysMem parsing)
- **bash** 4.0+
- **bc** - Calculator (pre-installed on macOS)

## Thresholds

| RAM Usage | Level | Action |
|-----------|-------|--------|
| < 90% | `ok` | Silence |
| 90-94% | `warning` | Alert only (Telegram) |
| ≥ 95% | `critical` | Kill processes + alert |

## Kill Priority at 95%

1. 🌐 **ALL Brave Browser** processes
2. 💻 **ALL iTerm2** processes
3. 🔧 Safe-to-kill (node orphans, test runners, cache processes)

## Protected Processes (NEVER killed)

- `openclaw-gateway`
- `Beeper` (all related processes)
- `Proton Mail Bridge` (email sync - IMAP/SMTP)
- System processes (`kernel_task`, `WindowServer`, `launchd`, etc.)

## Usage

```bash
# Normal run
~/bin/check-ram-usage.sh

# Dry run (no kills)
~/bin/check-ram-usage.sh --dry-run

# Pretty output
~/bin/check-ram-usage.sh | jq .
```

## JSON Output

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

## OpenClaw Integration

Add to your `HEARTBEAT.md`:

```markdown
## RAM Monitoring (every heartbeat)
- Run `~/bin/check-ram-usage.sh`
- If level=warning → Alert Telegram with top processes
- If level=critical → Alert with killed processes, ask if more cleanup needed
- If level=ok → Silence
```

## Documentation

See [SKILL.md](SKILL.md) for complete documentation.

## License

MIT License

## Author

Created for OpenClaw by [Maxime Auburtin](https://github.com/manthis)
