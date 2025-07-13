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
- **[gi-select.sh](docs/gi-select.md)** - Interactive .gitignore file generator using GitHub's gitignore templates
- **[highlight-manager.sh](docs/highlight-manager.md)** - Manage Kindle highlights with DuckDB storage and beautiful terminal display

### Infrastructure Monitoring
- **[power-monitor](docs/power-monitor.md)** - House and room-level power monitoring with backup-aware logic and MAC validation

## 🎯 Quick Start Examples

```bash
# Download and process audiobooks for swimming
./audiobook-pipeline.sh automate --duration 480  # 8-minute segments

# Split existing audiobook into 5-minute segments  
./audiobook-split.sh audiobook.m4b 300

# Download recent Audible purchases
./audible-download.sh --start-date "2024-01-01" --all

# Generate .gitignore for Python project
./gi-select.sh  # Interactive selection

# Import Kindle highlights from multiple devices
./highlight-manager.sh import kindle_*.txt koreader_*.txt

# Monitor house power status
./power-monitor/power-monitor.sh status
```

## 📋 Requirements by Script

| Script | Main Requirements |
|--------|------------------|
| audiobook-pipeline | `uvx`, `audible-cli`, `ffmpeg`, `gum` |
| audiobook-split | `ffmpeg`, `gum` |
| audible-download | `uvx`, `audible-cli`, `gum` |
| gi-select | `gum`, gitignore repository |
| highlight-manager | `duckdb`, `gum`, `jq`, `python3` |
| power-monitor | `duckdb`, `ping`, `arp`, `jq`, `gum` |

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
├── gi-select.md            # Interactive gitignore generation
├── highlight-manager.md     # Kindle highlights management
├── power-monitor.md        # Power monitoring system
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