# Worktree Protocol (Required for all engineering agents)

All engineering agents (FoundingEngineer, StaffEngineer, WineExpert) **MUST** work in a
per-issue git worktree. This prevents filesystem collisions when multiple agents run
concurrently on the same repository.

## Entering a worktree

At the start of every heartbeat that touches source files or runs builds, before doing
anything else:

**1 — Check whether a worktree already exists for this issue:**

```bash
git worktree list
```

Look for a path containing the issue identifier (e.g. `TIM-272`).

**2 — Enter or create:**

- Worktree already listed → enter it:
  ```
  EnterWorktree(path: "<absolute-path-shown-in-git-worktree-list>")
  ```

- No worktree yet → create one:
  ```
  EnterWorktree(name: "<ISSUE-IDENTIFIER>")
  ```
  Example: `EnterWorktree(name: "TIM-272")`

  This creates `.claude/worktrees/TIM-272/` on a new branch `TIM-272` branching
  from `origin/master`.

**3 — Confirm you are on the right branch:**

```bash
git branch --show-current   # should print TIM-272 (or whatever the issue ID is)
```

## Working in the worktree

- Commit normally to the issue branch as you go.
- **Never** commit directly to `master` in the root `_default` worktree while an issue
  worktree is active.
- Run builds and tests from inside the worktree — build artifacts are local to the
  worktree directory, so concurrent agents don't collide.

## Done workflow (merging back to master)

When the issue is complete, from inside the worktree:

```bash
# 1. Make sure everything is committed
git status

# 2. Sync with any upstream changes other agents may have merged
git fetch origin
git rebase origin/master --autostash

# 3. Push your branch to origin for safekeeping
git push origin HEAD
```

Then exit the worktree **keeping** the branch:

```
ExitWorktree(action: "keep")
```

Now back in `_default` (on branch `master`):

```bash
# 4. Update local master from origin (incorporates other agents' recent merges)
git pull origin master

# 5. Fast-forward merge the issue branch
git merge TIM-{id} --ff-only

# 6. Push master to origin
git push origin master

# 7. Remove the worktree directory and delete the branch
git worktree remove .claude/worktrees/TIM-{id}
git branch -d TIM-{id}
```

## Cancellation / abandonment workflow

From `_default` (after `ExitWorktree(action: "keep")`):

```bash
git worktree remove .claude/worktrees/TIM-{id} --force
git branch -D TIM-{id}
```

## Notes

- New worktrees branch from `origin/master` (the default). The done workflow pushes
  to `origin/master` before cleanup so the next worktree always starts from a complete
  state.
- Worktrees live at `.claude/worktrees/TIM-{id}/` — this path is gitignored.
- If `EnterWorktree` is called for a name that already exists as a branch or directory,
  use the `path:` form instead to re-enter the existing worktree.
