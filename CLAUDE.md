# Claude Development Context

## Repository Purpose

Personal utility scripts for automation and file processing tasks. Scripts range from simple one-liners to comprehensive bash utilities for tasks like format conversion, file manipulation, and system automation.

## Development Guidelines

- **Language**: Bash for shell scripts with portability focus
- **Quality**: All scripts must pass shellcheck validation
- **Dependencies**: Document external tool requirements (ffmpeg, gum, etc.)
- **UX**: Helpful error messages, progress feedback, comprehensive help text
- **Compatibility**: Cross-platform support, especially filename handling (FAT32, etc.)

## Script Requirements

- Executable permissions, proper shebang, and clean structure
- Command-line parsing with help options (-h/--help)
- Input validation, dependency checking, and error handling
- Progress indicators for long-running operations

## Coding Style & Preferences

- **Filenames**: Descriptive names with hyphens (`audiobook-split.sh`)
- **Output naming**: Use directory name as file prefix when custom output specified
- **Numbering**: Dynamic digits based on count (2 for <100, 3 for <1000), start from 1
- **Performance**: Intelligent thread count, single-pass when memory constrained
- **Documentation**: README updates with "why" context, features, examples
- **Git**: Feature branches, descriptive commits, squash merges
- **UI**: Optional prompts only with defaults, not explicit user values

## Development Rules

- **Never commit to main branch**
- **Never use pkill on generic processes like `python3`**
- **Always update README when changing scripts**
- **Read script code before attempting to use them**
- **Use ripgrep instead of grep in context (not in code)**

## Development Log

### Audiobook Pipeline Enhancement (2025-07-09)

Enhanced audiobook-pipeline.sh with modular design and smart automation:

- **Auto-conversion**: Fixed file detection using before/after comparison
- **Help system**: Added `-h/--help` for all subcommands
- **Modular commands**: Separated download, convert, split, and automate workflows
- **Auto-discovery**: Smart file detection and processing without explicit arguments
- **Multi-tier fallback**: ASIN → title → word-based file detection

### Power Monitor System Development (2025-07-11 to 2025-07-13)

Complete power monitoring system for house/room-level status tracking:

**Core Features**:

- **Backup-aware logic**: Differentiates main vs backup power switches
- **MAC validation**: Prevents IP conflict false positives via ARP table
- **Three-stage detection**: Ping → ARP check → ARP refresh fallback
- **DuckDB integration**: Fixed compatibility issues, clean SQL output parsing
- **Modular design**: Separated lib/ modules (database, network, power-logic, config, ui)

**Key Fixes**:

- **ARP false positives**: Enhanced freshness validation (REACHABLE/DELAY vs STALE)
- **Detection method tracking**: Numeric codes (0=FAILED, 1=PING_ONLY, 2=PING_MAC, 3=ARP_FRESH, etc.)
- **Uptime calculation**: Fixed to track actual state changes, not latest record time
- **Room status parsing**: Fixed cross-contamination bug using section-by-section parsing
- **Crontab automation**: PATH setup, flock locking, logger integration for production deployment

**Power States**: ONLINE (green), BACKUP (yellow), CRITICAL/OFFLINE (red)
**Monitoring**: Real-time status, historical analysis, automated cron deployment

### gitx Dispatcher and check-pr Rework (2026-07-25)

Wrapped the git tooling behind `gitx.sh` (dispatcher + `gitx/lib/` modules, following
power-monitor's layout) and reworked `check-pr.py`.

**gitx commands**: `status`, `changed`, `branch`, `sync`, `cleanup`, plus `pr` and
`gitignore` delegating to `check-pr.sh` and `gi-select.sh`.

**Key decisions**:

- **Merge-base diffs**: `changed` uses `git diff <merge-base>` so commits landing on the
  default branch afterwards are not attributed to the branch
- **Squash-merge detection**: replay the branch tree as one commit on the merge base, then
  `git cherry` against the default branch. `git branch --merged` cannot see these
- **Checkout-free sync**: `git fetch origin main:main` fast-forwards the default branch
  from a feature branch; a diverged local branch is reported, never forced
- **Default branch detection**: remote `HEAD` symref first, then `main`/`master`/`trunk`/
  `develop` on the remote, then locally. No network in read-only commands
- **fzf vs gum**: fzf for pickers with previews, gum for prompts/spinners/multi-select.
  Pickers gate on a usable `/dev/tty`, not `-t 1`, so `-i --name-only | xargs` still works
- **Dry run default**: `cleanup` requires `--apply`; `-d` for merged, `-D` only for
  squash-merged

**check-pr fixes**:

- **Sorting**: checks ordered failing → pending → other → skipped → passing, alphabetical
  within a state, so rows stop shuffling between refreshes
- **Short terminals**: split fetching (`collect_state`) from rendering (`render_state`) so
  watch mode re-renders each tick at the current size, drops passing checks when too tall,
  then truncates with a marker. Rich's `Live` was silently cropping the bottom
- **Previous run column**: `Previous` (verdict + duration) and `Trend`
  (regressed/fixed/still failing/slower N×/running long N×). Regressions and overruns are
  promoted into "Needs attention"
- **Previous-duration bug**: baselines came from cancelled runs, so several jobs all
  reported the cancellation timestamp (identical bogus values). Cancelled runs are now
  excluded
- **Review bug**: a COMMENTED review overwrote that user's earlier APPROVED; only
  APPROVED/CHANGES_REQUESTED/DISMISSED are decisive now
- **Watch keybindings**: `r` refreshes now, `q` quits, via cbreak mode on stdin (skipped
  when stdin is not a tty, so cron and pipes are unaffected). Refresh spam is contained
  two ways: a 3s cooldown on manual refreshes, and discarding keys buffered during a fetch
  (a queued keypress would otherwise become one API burst per press). `q` is still honored
  from that buffer, since a fetch can take seconds
- **API calls**: job details came one `gh api` call per check. Run ids are already in the
  check link, so jobs are fetched per _run_ instead: 24 checks over 12 runs went from ~37
  calls to 18, and the branch run-history fetch now overlaps the job listings

### Locale Configuration Script (2025-08-15)

Created set-locale.sh for comprehensive locale management:

**Core Features**:

- **Automatic Setup**: Generates and configures `en_US.UTF-8` locale with all `LC_*` variables
- **System Integration**: Updates /etc/default/locale and current session without restart
- **Cleanup Option**: Removes unused locales (--cleanup) keeping only en_US.UTF-8 and C/POSIX
- **Verification**: Complete locale status checking (--verify) with detailed output

**Key Components**:

- **Safety First**: Backup creation before cleanup, confirmation prompts for destructive actions
- **Cross-platform**: Works with different locale-gen implementations and system configurations
- **Immediate Effect**: Updates current session environment variables for instant usage
- **Space Optimization**: Cleans both locale.gen and locale archive to minimize disk usage
