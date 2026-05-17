---
name: github-workflow
description: Use when creating PRs, managing branches, merging with automerge, or cleaning up worktrees for the C&C Red Alert + Tiberian Dawn port. Covers the gh CLI patterns, worktree protocol, and common mistakes like stashing from the wrong branch or misusing --repo flags.
version: 0.1.0
---

# GitHub Workflow Skill

> **Tools available via `pi-battlecontrol-dev` extension:** All build/test tools.
> PR and branch operations use git + `gh` CLI directly.

This skill documents the project's GitHub PR and branch workflow. Every PR **must**
have automerge enabled. Every push **must** be preceded by `ci_local()`.

---

## Phase 0 — Before you start: check what exists

Always run this first. The most common mistake is operating without knowing what
worktrees, branches, or PRs already exist.

```bash
# 1. Check worktrees
git worktree list

# 2. Check current branch
git branch --show-current

# 3. Check open PRs
gh pr list --repo hughobrien/battlecontrol --state open

# 4. Check status of the current working tree
git status
```

---

## §1 — The worktree protocol

> **All changes must be made inside a worktree.** Never commit directly to `master`
> in the root worktree while a worktree is active.

### §1.1 — Enter or create a worktree

The extension tool `EnterWorktree(name: "<NAME>")` creates `.claude/worktrees/<NAME>/`
on a new branch `worktree-<NAME>` reset to `origin/master`.

To re-enter an existing worktree:

```bash
git worktree list            # find the path
EnterWorktree(path: "<path>")
```

### §1.2 — Working inside a worktree

```bash
cd .claude/worktrees/<NAME>/
git status
# ... make changes, commit, build, test ...
```

### §1.3 — Exiting a worktree (keeping branch)

```bash
ExitWorktree(action: "keep")
```

### §1.4 — Cleanup after merge

From the root worktree:

```bash
git pull origin master
git worktree remove .claude/worktrees/<NAME>
git branch -d worktree-<NAME>
```

### §1.5 — Cancel / abandon a worktree

```bash
git worktree remove .claude/worktrees/<NAME> --force
git branch -D worktree-<NAME>
```

---

## §2 — Branch and PR workflow

### §2.1 — Creating a new branch from an existing PR branch

Sometimes you need to build on top of another PR's branch (e.g., when the first PR
is still open and you have further refinements).

```bash
# 1. Fetch the latest remote
git fetch origin

# 2. Check out a new branch from the existing PR branch
git checkout -b worktree-<NEW-NAME> origin/<EXISTING-BRANCH>

# 3. Make your changes on top
# ... edit files ...
git add <files>
git commit -m "<description>"

# 4. Push the new branch
git push origin HEAD

# 5. Create a PR against master
gh pr create --repo hughobrien/battlecontrol \
  --title "<short description>" \
  --body "<details>" \
  --base master
```

### §2.2 — Checking PR status

```bash
# View PR details
gh pr view <number> --repo hughobrien/battlecontrol

# Check CI status
gh pr view <number> --repo hughobrien/battlecontrol \
  --json statusCheckRollup,mergeStateStatus

# Check automerge status
gh pr view <number> --repo hughobrien/battlecontrol \
  --json autoMergeRequest

# List all open PRs
gh pr list --repo hughobrien/battlecontrol --state open
```

### §2.3 — Enabling automerge

> **Every PR must have automerge enabled.** This is not optional.

```bash
# When on the PR's branch (no --repo needed):
gh pr merge --auto --merge

# When on a different branch, specify the PR number + --repo:
gh pr merge <number> --auto --merge --repo hughobrien/battlecontrol
```

### §2.4 — Creating a PR from a fresh branch

```bash
# 1. Push your branch
git push origin HEAD

# 2. Create PR
gh pr create --repo hughobrien/battlecontrol \
  --title "<short description>" \
  --body "<details>" \
  --base master

# 3. ⚠️ Enable automerge immediately (note the PR number from step 2 output)
gh pr merge <number> --auto --merge
```

---

## §3 — Common mistakes (and how to avoid them)

### §3.1 — `--repo` flag requires the PR number

**Problem:** This fails:
```bash
gh pr merge --auto --merge --repo hughobrien/battlecontrol
# error: argument required when using the --repo flag
```

**Root cause:** When `--repo` is used, `gh` needs the PR number as a positional
argument. It doesn't infer it from the current branch.

**Fix:** Pass the PR number before the flags when using `--repo`:
```bash
gh pr merge 222 --auto --merge --repo hughobrien/battlecontrol
```

Or omit `--repo` when on the PR's branch:
```bash
# When checked out to the PR's branch:
gh pr merge --auto --merge
```

### §3.2 — Working in root master instead of a worktree

**Problem:** Making changes on `master` branch directly, then finding a worktree
already exists with similar work.

**Prevention:** Always run `git worktree list` and `git branch --show-current` before
starting any work. If a worktree exists for the task, use it. If you're on `master`,
check `gh pr list` to see if the changes are already in a PR.

**Fix:** If you've already made changes on `master` that belong in a worktree branch:
```bash
# Stash the changes (use -u for untracked/new files)
git stash push -m "desc" -u

# Create a new branch / worktree
git checkout -b worktree-<NAME> origin/master

# Pop the stash
git stash pop
```

### §3.3 — `git stash pop` causing conflicts

**Problem:** Stashing changes on one branch, switching branches, then popping causes
conflicts because the file content differs between branches.

**Prevention:** Before popping a stash, verify what's in it:
```bash
git stash show -p stash@{0} | head -40
```

Compare the stash diff against the current branch's content. If they modify the same
lines, expect conflicts.

**Fix:** Instead of `git stash pop`, apply the stash as a patch:
```bash
git stash show -p stash@{0} | git apply
git stash drop stash@{0}
```

This attempts a clean patch application on the working tree without merging. If it
fails, you can inspect the diff and apply portions manually.

### §3.4 — Not checking for existing PRs before taking action

**Problem:** Creating duplicate work or a duplicate PR.

**Prevention:** Before any PR-related operation:
```bash
gh pr list --repo hughobrien/battlecontrol --state open
```

Also check if the current branch has a PR already:
```bash
gh pr view 2>/dev/null && echo "PR EXISTS" || echo "NO PR"
```

### §3.5 — Forgetting automerge

**Problem:** Creating a PR but not enabling automerge. The PR sits open indefinitely
waiting for manual merge.

**Prevention:** After every `gh pr create`, immediately run:
```bash
gh pr merge --auto --merge
```

### §3.6 — Stash doesn't save untracked files

**Problem:** Running `git stash` with new (untracked) files — the stash only saves
tracked/modified files. After popping, the new files are gone.

**Fix:** Use `-u` (or `--include-untracked`) to include untracked files:
```bash
git stash push -m "message" -u
```

Or for a full clean including ignored files:
```bash
git stash push -m "message" -a   # --all
```

### §3.7 — Not rebasing before pushing a PR branch

**Problem:** Pushing a branch that's behind `origin/master` causes merge conflicts
in the PR.

**Fix:** Before pushing, rebase:
```bash
git fetch origin
git rebase origin/master --autostash
git push origin HEAD --force-with-lease
```

### §3.8 — Leaving a stale stash behind

**Problem:** Stash entries accumulate and get reused accidentally.

**Prevention:** Drop stashes after use:
```bash
git stash drop stash@{0}
```

Or clear all stashes:
```bash
git stash clear
```

### §3.9 — Not cleaning up worktrees after merge

**Problem:** Worktrees accumulate on disk, causing confusion about which branches
are still active.

**Fix:** After a PR merges and you've pulled the latest master:
```bash
git worktree remove .claude/worktrees/<NAME>
git branch -d worktree-<NAME>
```

Check for stale worktrees:
```bash
git worktree list
# Prune any with missing branches:
git worktree prune
```

---

## §4 — Quick reference card

### gh CLI patterns

| Action | Command |
|--------|---------|
| Create PR | `gh pr create --repo hughobrien/battlecontrol --title "..." --body "..." --base master` |
| Enable automerge (on branch) | `gh pr merge --auto --merge` |
| Enable automerge (by number) | `gh pr merge <N> --auto --merge --repo hughobrien/battlecontrol` |
| View PR | `gh pr view <N> --repo hughobrien/battlecontrol` |
| View CI checks | `gh pr view <N> --repo hughobrien/battlecontrol --json statusCheckRollup` |
| List open PRs | `gh pr list --repo hughobrien/battlecontrol --state open` |
| View automerge status | `gh pr view <N> --repo hughobrien/battlecontrol --json autoMergeRequest` |

### git branch / worktree commands

| Action | Command |
|--------|---------|
| List worktrees | `git worktree list` |
| Create worktree | `git worktree add <PATH> -b <BRANCH> <BASE>` |
| Create branch from origin | `git checkout -b <NAME> origin/<BASE>` |
| Show stash contents | `git stash show -p stash@{0}` |
| Apply stash as patch | `git stash show -p stash@{0} \| git apply` |
| Stash with untracked files | `git stash push -m "msg" -u` |
| Drop specific stash | `git stash drop stash@{0}` |
| Remove worktree | `git worktree remove <PATH>` |
| Force-remove worktree | `git worktree remove <PATH> --force` |
| Prune stale worktrees | `git worktree prune` |
| Delete local branch | `git branch -d <NAME>` |
| Force-delete local branch | `git branch -D <NAME>` |

### Pre-flight checklist

Before any git/PR operation, verify:

```
□ git worktree list         — check for existing worktrees
□ git branch --show-current — confirm you're on the right branch
□ gh pr list                — check for existing PRs
□ git status                — check for uncommitted changes
□ git fetch origin          — make sure origin is up to date
□ git stash list            — check for leftover stashes
```

---

## §5 — Verification bar

| Gate | How | Expected |
|------|-----|----------|
| PR created | `gh pr view <N>` | Shows PR with correct title, base `master` |
| Automerge enabled | `gh pr view <N> --json autoMergeRequest` | `autoMergeRequest` is not null |
| No local changes after PR | `git status` | Clean working tree |
| No leftover stash | `git stash list` | Empty output |
| No stale worktrees | `git worktree list` | Only active worktrees |
| Skill file exists | `ls skills/github-workflow/SKILL.md` | File present |
| Skill indexed | `grep github-workflow skills/README.md` | Entry in table |

---

## Related skills

This skill is referenced by:
- **ci-cd** — CI/CD pipeline also uses gh CLI for workflow triggers
- **parity-comparison** — PRs for parity fixes follow this workflow
- **e2e-testing** — Test PRs must pass the T1/T2 smoke gate before merge
