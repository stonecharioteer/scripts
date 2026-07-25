# gitx - Git Workflow Helpers

`gitx.sh` is a single entry point for the everyday feature-branch loop: start a branch,
see what it changed, check the PR, keep up with the default branch, and clean up
afterwards.

## Why This Exists

The individual pieces were already here — `check-pr.sh` for PR status, `gi-select.sh` for
gitignore templates — but everything else lived in shell history as half-remembered
plumbing. Three problems kept recurring:

- **"What did this branch actually change?"** `git diff main` answers the wrong question
  once `main` has moved on. The right answer needs the merge base, which nobody types by
  hand every time.
- **Squash-merged branches pile up.** `git branch --merged` never lists them, because a
  squash merge shares no commits with the branch it came from. They accumulate until you
  delete them by memory and hope.
- **Every repo has a different default branch.** `main`, `master`, `development`, `trunk`.
  Hardcoding one guarantees the helper breaks on the next repo.

`gitx` solves each once, then puts them behind one dispatcher with consistent help,
colors, and interactive pickers.

## Features

- **Merge-base aware diffs** - `changed` never reports commits that landed on the default
  branch after you branched off
- **Squash-merge detection** - `cleanup` finds branches GitHub squashed, which
  `git branch --merged` misses entirely
- **Default branch detection** - reads the remote's `HEAD` symref, and asks the remote
  directly when a local guess would be ambiguous, so a repo whose default is `development`
  but which also has a `main` is not mistaken for a `main` repo
- **Deploy-branch awareness** - `status --vs main` reports where you sit relative to any
  other branch, for repos where the default branch is not the one you ship from
- **Checkout-free updates** - `sync` fast-forwards the default branch while you stay on
  your feature branch
- **fzf and gum throughout** - branch and file pickers with live diff previews, gum
  spinners for fetches, gum multi-select before any deletion
- **Dry run by default** - `cleanup` never deletes anything until you pass `--apply`
- **Pipe friendly** - `--name-only` and the picker's selection both go to stdout, so they
  compose with `xargs`

## Requirements

| Tool          | Needed for                                          |
| ------------- | --------------------------------------------------- |
| `git`         | everything                                          |
| `fzf`         | branch and changed-file pickers (`changed -i`)      |
| `gum`         | prompts, spinners, `cleanup` selection, `gitignore` |
| `uv` and `gh` | `gitx pr` (delegates to `check-pr.sh`)              |

`fzf` and `gum` are optional: without them the pickers degrade to non-interactive output
and prompts fall back to a plain `read`.

## Layout

```
gitx.sh                 # dispatcher: global options, command routing, help
gitx/lib/common.sh      # colors, logging, git queries, fzf/gum helpers
gitx/lib/status.sh      # gitx status
gitx/lib/changed.sh     # gitx changed
gitx/lib/branch.sh      # gitx branch
gitx/lib/sync.sh        # gitx sync
gitx/lib/cleanup.sh     # gitx cleanup
gitx/lib/pr.sh          # gitx pr      -> check-pr.sh
gitx/lib/gitignore.sh   # gitx gitignore -> gi-select.sh
```

## Commands

### status

Where you are relative to everything else, in seven lines.

```bash
gitx status
gitx status --fetch      # refresh from the remote first so counts are current
```

```
Repository  scripts (/Users/you/code/checkouts/personal/scripts)
Branch      feat/git-tools
Upstream    origin/feat/git-tools in sync
Default     main (tracking origin/main)
Position    ahead 3, behind 1 (rebase or merge to catch up)
Worktree    0 staged, 1 unstaged, 9 untracked
Stashes     none
Last commit 2b3b0d6 Merge pull request #29 (5 days ago)
```

**Comparing against another branch.** When the branch you deploy from is not the default
branch, `--vs` adds a `Compare` row. Repeat it for more than one, or set
`GITX_STATUS_COMPARE` once per repo:

```bash
gitx status --vs main                    # development is default, main deploys
gitx status --vs main --vs staging
GITX_STATUS_COMPARE=main gitx status
```

```
Default     development (tracking origin/development)
Position    ahead 2, behind 0 vs origin/development
Compare     ahead 20, behind 21 vs origin/main
```

A ref that does not exist is reported in place rather than being fatal, so a stale entry in
`GITX_STATUS_COMPARE` cannot break the command.

### changed

Files a branch changed relative to the default branch, with added/removed line counts.
The comparison is against the merge base, so commits that landed on the default branch
afterwards are not reported as your changes.

```bash
gitx changed                        # current branch vs default branch
gitx changed feat/other-work        # a specific branch
gitx changed --dirty                # include uncommitted working tree changes
gitx changed --base release/1.2     # compare against another base
gitx changed --stat                 # git's own --stat rendering
```

```
Base        origin/main (merge base 2b3b0d6)
Head        feat/git-tools (3 commits)

  +214   -0  gitx.sh
  +197   -0  gitx/lib/cleanup.sh
    +0   -3  README.md

  3 files changed, +411, -3
```

Interactive mode picks the branch with fzf, then browses the changed files with a live
diff preview. Selected paths are printed to stdout, so they pipe into anything:

```bash
gitx changed -i                          # browse with diff preview
gitx changed -i --name-only | xargs $EDITOR
gitx changed --name-only | xargs shellcheck
```

`-i` needs a terminal for the picker, but stdout can still be piped: fzf draws on
`/dev/tty` and writes only the selection to stdout.

### branch

Create a conventionally named branch off an up-to-date default branch and switch to it.

```bash
gitx branch feat add git tools          # -> feat/add-git-tools
gitx branch fix "PR status colours"     # -> fix/pr-status-colours
gitx branch docs/gitx-usage             # contains a slash: used verbatim
gitx branch --from v1.2.0 fix backport  # branch off a tag
gitx branch -n feat try something       # print the name, create nothing
gitx branch                             # gum prompts for type and description
```

Types: `feat` `fix` `docs` `chore` `refactor` `test` `perf` `ci` `build` `style`.
Descriptions are slugified (lowercased, punctuation collapsed to hyphens) and the result
is validated with `git check-ref-format` before anything is created.

### sync

Fetch with prune, fast-forward the default branch, then report divergence. The default
branch is updated even while you are on a feature branch, using a fast-forward-only
refspec fetch, so no checkout dance is needed. Nothing is rewritten unless you ask.

```bash
gitx sync                # fetch, fast-forward main, report status
gitx sync --rebase       # ...and rebase the current branch onto main
gitx sync --no-fetch     # report only, no network
```

If the local default branch has diverged from the remote, `sync` says so and leaves it
alone rather than guessing.

### cleanup

Delete local branches whose work already landed, including squash-merged ones.

```bash
gitx cleanup                 # dry run: list what would go
gitx cleanup --apply         # gum multi-select, everything preselected
gitx cleanup --apply --yes   # no prompting, for scripts
gitx cleanup --prune         # also drop stale remote-tracking refs
gitx cleanup --no-squashed   # skip squash detection (faster on big repos)
```

```
Base        origin/main
Protected   main master feat/git-tools

  feat/merged                merged         b965f89 3 days ago
  feat/squashed              squash-merged  2ca13d5 2 days ago

Dry run: nothing deleted. Re-run with --apply to delete these 2 branch(es).
```

The default branch, the current branch, `main`, and `master` are always protected. Add
more with `GITX_PROTECTED_BRANCHES`. Merged branches are removed with `git branch -d`;
only squash-merged ones need `-D`, since git cannot see the equivalence itself.

**How squash detection works:** the branch's tree is replayed as a single commit on top of
the merge base, then `git cherry` is asked whether an equivalent patch already exists on
the default branch. The probe commit is never referenced, so it is garbage collected.

### pr

PR merge status, checks, reviews, and bot activity. Delegates to `check-pr.sh`, so every
option it accepts works here.

```bash
gitx pr
gitx pr --concise
gitx pr -w                 # watch mode
gitx pr -w -i 10           # watch, refreshing every 10 seconds
```

In watch mode, `r` refreshes immediately and `q` quits. Manual refreshes have a
three-second cooldown, and keys pressed while a refresh is in flight are discarded, so
holding `r` down cannot turn into a burst of API calls.

### gitignore

Append GitHub's gitignore templates to `./.gitignore`, chosen with gum. Delegates to
`gi-select.sh`.

```bash
gitx gitignore
gitx gi
```

## Global Options

```
-h, --help              Show help (also: gitx help COMMAND)
-V, --version           Show the gitx version
-C, --directory DIR     Run as if gitx started in DIR
    --remote NAME       Remote to use (default: origin, else the first remote)
    --default-branch B  Override default branch detection
    --no-color          Disable colored output
```

## Environment

| Variable                  | Effect                                     |
| ------------------------- | ------------------------------------------ |
| `GITX_REMOTE`             | Default remote name                        |
| `GITX_DEFAULT_BRANCH`     | Default branch name, skipping detection    |
| `GITX_PROTECTED_BRANCHES` | Extra branches `cleanup` must never delete |
| `GITX_STATUS_COMPARE`     | Default `--vs` refs for `status`           |
| `NO_COLOR`                | Disable colored output                     |

## Command Aliases

| Command     | Aliases  |
| ----------- | -------- |
| `status`    | `st`     |
| `changed`   | `files`  |
| `branch`    | `new`    |
| `sync`      | `update` |
| `cleanup`   | `tidy`   |
| `gitignore` | `gi`     |

## Suggested Alias

```bash
alias gitx='~/code/checkouts/personal/scripts/gitx.sh'
```

## Notes and Gotchas

- **`changed` on a mode-only change** reports `+0 -0`. That matches `git diff --numstat`;
  the file did change (its mode), just not its contents.
- **`cleanup` costs a few git calls per branch** when squash detection is on
  (`merge-base`, `rev-parse`, `commit-tree`, `cherry`). On a repo with hundreds of stale
  branches, `--no-squashed` is noticeably faster.
- **`sync --rebase` refuses to run with a dirty tree.** Commit or stash first; it will not
  stash on your behalf.
- **Uncommitted changes carry over** when `branch` switches, which is normal git
  behaviour. It warns so the carry-over is not a surprise.
