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

- **[ai-usage-collect.py](docs/ai-usage-collect.md)** - Collect ccusage-backed AI coding stats from local/SSH hosts in parallel into append-only per-host ledgers, JSON/CSV, an offline-capable responsive dashboard, and a shareable PNG infographic; run via `ai-usage.sh` so uv resolves matplotlib
- **[check-pr.sh](check-pr.sh)** - Show one-line GitHub PR merge status with color-coded blockers, checks sorted worst-first, runner/machine info, previous-run verdict and timing trend (regressed/fixed/slower), reviews, and bot activity (CodeRabbit, etc.)
- **[env-diff.sh](docs/env-diff.md)** - Compare `.env` files in a gum table while redacting token-like values
- **[gi-select.sh](docs/gi-select.md)** - Interactive .gitignore file generator using GitHub's gitignore templates
- **[gitx.sh](docs/gitx.md)** - Git workflow dispatcher: branch status, merge-base changed files with +/- counts, conventional branch creation, checkout-free default-branch sync, squash-merge-aware branch cleanup, and wrappers for check-pr and gi-select
- **[highlight-manager.sh](docs/highlight-manager.md)** - Manage Kindle highlights with DuckDB storage and beautiful terminal display

### Notifications

- **[ntfy.sh](docs/ntfy.md)** - Publish notifications to the self-hosted ntfy server at `ntfy.home.arpa` (default topic: `alerts`; common topics: `agents`, `chores`)
- **[simple-notify.sh](docs/simple-notify.md)** - Legacy Simplepush notifications with curl and a JSON payload

### Infrastructure Monitoring

- **[power-monitor](docs/power-monitor.md)** - House and room-level power monitoring with backup-aware logic and MAC validation

### System Configuration

- **[set-locale.sh](docs/set-locale.md)** - Configure en_US.UTF-8 locale with cleanup options for unused locales
- **[laptop/](laptop/README.md)** - Laptop helpers for distributed-dotfiles (`thinkpads/` headless tools, `x13-flow/` screen/health helpers)
- **[homelab/jellyfin](homelab/jellyfin/README.md)** - Dry-run Jellyfin music library organizer (`music_manage.py`)

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
./check-pr.sh -w -i 10  # Watch mode with a 10-second interval
./check-pr.sh --concise  # Show only summary and items needing attention
./check-pr.sh /path/to/repo  # Check a PR from another repository directory

# Git workflow helpers behind one dispatcher
./gitx.sh status  # Branch, upstream, default-branch, worktree, stashes
./gitx.sh changed  # Files this branch changed vs the default branch, with +/- counts
./gitx.sh changed -i  # Pick a branch with fzf, browse its files with a diff preview
./gitx.sh branch feat add git tools  # Create feat/add-git-tools off an updated main
./gitx.sh sync --rebase  # Fetch, fast-forward main, rebase the current branch
./gitx.sh cleanup  # List merged and squash-merged branches (dry run)
./gitx.sh cleanup --apply  # Delete them after a gum confirmation
./gitx.sh pr --concise  # Wraps check-pr.sh

# Collect AI coding-agent usage into JSON/CSV stats, ai-usage.html, and a shareable infographic
./ai-usage.sh
./ai-usage.sh --host eqr5 --host macbook=stone@macbook.local

# Diff env files without printing token-like values
./env-diff.sh .env .env.example
./env-diff.sh --all .env.local .env.production

# Generate .gitignore for Python project
./gi-select.sh  # Interactive selection

# Send an ntfy notification
./ntfy.sh "Quick alert to the default alerts topic"
./ntfy.sh agents "Agent done: tests passed"
./ntfy.sh chores "Take out trash bins tonight"

# Legacy Simplepush notification
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

| Script             | Main Requirements                                                                                              |
| ------------------ | -------------------------------------------------------------------------------------------------------------- |
| audiobook-pipeline | `uvx`, `audible-cli`, `ffmpeg`, `gum`                                                                          |
| audiobook-split    | `ffmpeg`, `gum`                                                                                                |
| audible-download   | `uvx`, `audible-cli`, `gum`                                                                                    |
| ai-usage-collect   | `uv` (matplotlib for the infographic), `ssh` for remote hosts, `ccusage`/`npx` for unified usage and cost data |
| check-pr           | `uv`, `gh`, `git`                                                                                              |
| env-diff           | `gum`, `awk`, `sort`                                                                                           |
| gi-select          | `gum`, gitignore repository                                                                                    |
| gitx               | `git`; `fzf` and `gum` for pickers and prompts; `uv` + `gh` for `gitx pr`                                      |
| highlight-manager  | `duckdb`, `gum`, `jq`, `python3`                                                                               |
| ntfy               | `curl`                                                                                                         |
| simple-notify      | `curl`                                                                                                         |
| power-monitor      | `duckdb`, `ping`, `arp`, `jq`, `gum`                                                                           |
| set-locale         | `locale-gen`, `sudo` access                                                                                    |
| laptop/thinkpads   | `nmcli`, `systemctl`, sysfs battery thresholds                                                                 |
| laptop/x13-flow    | `gum`, `uv`, `systemctl`, distributed-dotfiles laptop-health role                                              |

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
├── gitx.md                 # Git workflow dispatcher
├── highlight-manager.md     # Kindle highlights management
├── ntfy.md                 # Self-hosted ntfy notifications
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
- **Formatting**: Markdown is formatted by Prettier through pre-commit; install with `pre-commit install`
  and run manually with `pre-commit run prettier --all-files`.
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
