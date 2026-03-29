# Runbook — OpenClaw Fork Update Flow

This repo is maintained as a fork of `openclaw/openclaw`.

The safe default is:

- keep local `main` tracking `origin/main`
- merge upstream changes into the fork through a branch/PR
- after fork `main` is updated, run `pnpm update:fork` locally to rebuild, verify, and rotate the live gateway onto the fresh runtime

## Standard flow

### 1) Sync upstream into the fork

From a clean checkout:

```bash
git fetch origin --prune
git fetch upstream --prune --tags
git switch main
git merge --ff-only origin/main
```

Create a sync branch, merge upstream, resolve conflicts, validate, and merge that branch back into fork `main`.

Notes:

- keep `origin` = fork (`dewgie-bot/openclaw`)
- keep `upstream` = source (`openclaw/openclaw`)
- prefer upstream-first conflict resolution, then re-apply minimal fork deltas

### 2) Update the local runtime after fork `main` changes

Fast-forward local `main` to the merged fork head, then run:

```bash
pnpm update:fork
```

Useful variants:

```bash
pnpm update:fork -- --dry-run
pnpm update:fork -- --no-restart
```

## What `pnpm update:fork` does

The wrapper (`scripts/update-fork.sh`) adds fork-specific guardrails around `openclaw update`.

It:

- requires `main` to track `origin/main`
- requires a clean worktree for real updates
- allows inspection-oriented `--dry-run` on a dirty worktree
- checks whether `origin/main` is behind `upstream/main`
- runs `openclaw update`
- smoke-checks built artifacts (`dist`)
- verifies the live CLI/runtime separately from built files
- verifies the gateway actually rotated after restart by comparing daemon PID and process start time
- verifies gateway HTTP and WebSocket health using the gateway's reported probe URL/config instead of a hardcoded port
- prints a concise verification summary for maintainers

## Expected day-to-day maintainer workflow

After a fork sync PR merges:

```bash
git fetch origin --prune
git switch main
git merge --ff-only origin/main
pnpm update:fork
```

## If the wrapper stops you

### Dirty worktree

Commit or stash changes before a real update.

For inspection only:

```bash
pnpm update:fork -- --dry-run
```

### Fork is behind upstream

Merge upstream into the fork first.

If you intentionally only want a dry-run preview while behind upstream:

```bash
OPENCLAW_UPDATE_FORK_ALLOW_BEHIND=1 pnpm update:fork -- --dry-run
```

### Gateway verification fails

Check:

```bash
openclaw --version
openclaw status
openclaw gateway status
```

Manual restart fallback:

```bash
openclaw gateway restart
```

## Anti-pattern to avoid

Do **not** treat these as separate, memory-based steps:

- sync code locally
- assume `dist/` is fresh
- manually restart later
- assume the daemon picked up the new build

Use the wrapper so build, restart, and live verification stay coupled.
