# Personal Utility Scripts

A collection of bash scripts for automation and file processing tasks, ranging from simple utilities to comprehensive automation pipelines.

## 📚 Documentation

Each script has detailed documentation in the [`docs/`](docs/) folder with comprehensive usage examples, troubleshooting guides, and technical details.

## 🚀 Quick Reference

### Audiobook Processing
- **[audiobook-pipeline.sh](docs/audiobook-pipeline.md)** - Complete audiobook processing pipeline from Audible download to MP3 segments
- **[audiobook-split.sh](docs/audiobook-split.md)** - Split audiobooks into smaller segments for swimming headphones
- **[audible-download.sh](docs/audible-download.md)** - Bulk download audiobooks from Audible with filtering options

### Development Tools
- **[ai-usage-collect.py](docs/ai-usage-collect.md)** - Collect Claude Code, Codex, pi, opencode, and Grok usage from local/SSH hosts into cached JSON/CSV stats and a static HTML dashboard
- **[check-pr.sh](check-pr.sh)** - Show one-line GitHub PR merge status with color-coded blockers, check runner/machine info, reviews, and bot activity (CodeRabbit, etc.)
- **[env-diff.sh](docs/env-diff.md)** - Compare `.env` files in a gum table while redacting token-like values
- **[gi-select.sh](docs/gi-select.md)** - Interactive .gitignore file generator using GitHub's gitignore templates
- **[highlight-manager.sh](docs/highlight-manager.md)** - Manage Kindle highlights with DuckDB storage and beautiful terminal display

### Notifications
- **[simple-notify.sh](docs/simple-notify.md)** - Send Simplepush notifications with curl and a JSON payload

### Infrastructure Monitoring
- **[power-monitor](docs/power-monitor.md)** - House and room-level power monitoring with backup-aware logic and MAC validation

### System Configuration
- **[set-locale.sh](docs/set-locale.md)** - Configure en_US.UTF-8 locale with cleanup options for unused locales
- **[laptop/x13-flow](laptop/x13-flow/README.md)** - ASUS X13 Flow screen and health helper scripts used by distributed-dotfiles

## 🎯 Quick Start Examples

```bash
# Download and process audiobooks for swimming
./audiobook-pipeline.sh automate --duration 480  # 8-minute segments

# Split existing audiobook into 5-minute segments  
./audiobook-split.sh audiobook.m4b 300

# Download recent Audible purchases
./audible-download.sh --start-date "2024-01-01" --all

# Check status of open PR for current branch
./check-pr.sh  # Show one-line merge status plus checks and bot reviews
./check-pr.sh -w  # Watch mode, refresh every 30 seconds
./check-pr.sh --concise  # Show only summary and items needing attention
./check-pr.sh /path/to/repo  # Check a PR from another repository directory

# Collect AI coding-agent usage into raw/daily JSON/CSV stats and ai-usage.html
./ai-usage-collect.py
./ai-usage-collect.py --host eqr5 --host macbook=stone@macbook.local

# Diff env files without printing token-like values
./env-diff.sh .env .env.example
./env-diff.sh --all .env.local .env.production

# Generate .gitignore for Python project
./gi-select.sh  # Interactive selection

# Send a Simplepush notification
./simple-notify.sh "Build finished"

# Import Kindle highlights from multiple devices
./highlight-manager.sh import kindle_*.txt koreader_*.txt

# Monitor house power status
./power-monitor/power-monitor.sh status

# Configure system locale to en_US.UTF-8
./set-locale.sh

# Clean up unused locales to save space
./set-locale.sh --cleanup
```

## 📋 Requirements by Script

| Script | Main Requirements |
|--------|------------------|
| audiobook-pipeline | `uvx`, `audible-cli`, `ffmpeg`, `gum` |
| audiobook-split | `ffmpeg`, `gum` |
| audible-download | `uvx`, `audible-cli`, `gum` |
| ai-usage-collect | `python3`, `ssh` for remote hosts, `ccusage`/`npx` for Claude cost data |
| check-pr | `uv`, `gh`, `git` |
| env-diff | `gum`, `awk`, `sort` |
| gi-select | `gum`, gitignore repository |
| highlight-manager | `duckdb`, `gum`, `jq`, `python3` |
| simple-notify | `curl` |
| power-monitor | `duckdb`, `ping`, `arp`, `jq`, `gum` |
| set-locale | `locale-gen`, `sudo` access |
| laptop/x13-flow | `gum`, `uv`, `systemctl`, distributed-dotfiles laptop-health role |

## 🏗️ Installation

1. **Clone repository**:
   ```bash
   git clone <repository-url> ~/scripts
   cd ~/scripts
   ```

2. **Install common dependencies**:
   ```bash
   # Ubuntu/Debian
   sudo apt update && sudo apt install ffmpeg jq gum duckdb
   
   # Install uvx for Python tools
   pip install uvx
   ```

3. **Set up individual scripts** (see respective documentation for detailed setup):
   ```bash
   # Audible authentication
   uvx --from audible-cli audible quickstart
   
   # Power monitor initialization
   ./power-monitor/power-monitor.sh init
   
   # Gitignore templates
   git clone https://github.com/github/gitignore.git ~/code/tools/gitignore
   ```

## 📖 Documentation Structure

```
docs/
├── audiobook-pipeline.md    # Complete audiobook processing
├── audiobook-split.md       # Audio segmentation
├── audible-download.md      # Audible bulk downloads
├── ai-usage-collect.md      # AI coding-agent usage collection
├── env-diff.md             # Secret-safe env file diffing
├── gi-select.md            # Interactive gitignore generation
├── highlight-manager.md     # Kindle highlights management
├── simple-notify.md        # Simplepush notifications
├── power-monitor.md        # Power monitoring system
├── set-locale.md           # System locale configuration
└── til/                    # Today I Learned entries
    ├── README.md           # TIL index
    └── 2025-07-13.md       # Crontab, flock, logger learnings
```

## 🎓 Learning Resources

The [`docs/til/`](docs/til/) folder contains practical development learnings:
- **[TIL Index](docs/til/README.md)** - Browse all Today I Learned entries
- **[Crontab & Automation](docs/til/2025-07-13.md)** - Environment setup, process locking, system logging

## 🔧 Development Guidelines

- **Language**: Bash for shell scripts with focus on portability
- **Quality**: All scripts pass shellcheck validation
- **User Experience**: Comprehensive help text, progress feedback, meaningful error messages
- **Dependencies**: Document all external tool requirements
- **Documentation**: Each script has detailed docs with real-world usage examples

## 🚨 Common Issues

### Audiobook Processing
- **FFmpeg version**: Requires 4.4+ for AAXC format support
- **Audible authentication**: Run `uvx --from audible-cli audible quickstart` if downloads fail

### Power Monitor
- **DuckDB not found**: Ensure `~/.local/bin` is in PATH for cron jobs
- **Network detection**: Some devices require ARP table validation when ping is disabled
- **False positives fixed**: Recent update (2025-07-13) eliminates room status false positives during outages

### General
- **Permission errors**: Ensure scripts have executable permissions (`chmod +x script.sh`)
- **Dependency issues**: Check requirements section in individual documentation

## 🤝 Contributing

1. Follow existing bash scripting patterns and style
2. Add comprehensive help system (`-h/--help`)
3. Include input validation and error handling
4. Update documentation in `docs/` folder
5. Add TIL entries for new techniques or gotchas

## 📄 License

Personal utility scripts for automation and file processing. See individual script headers for specific licensing information.