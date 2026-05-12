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

  This creates `.claude/worktrees/TIM-272/` on a new branch `worktree-TIM-272`.
  After creation, immediately reset to `battlecontrol/master` so the worktree
  starts from the team's working master, not the upstream EA base:

  ```bash
  git fetch battlecontrol
  git reset --hard battlecontrol/master
  ```

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

## Done workflow (merging back to master via Pull Request)

When the issue is complete, from inside the worktree:

```bash
# 1. Make sure everything is committed
git status

# 2. Sync with any upstream changes other agents may have merged
git fetch battlecontrol
git rebase battlecontrol/master --autostash

# 3. Push your branch
git push battlecontrol HEAD
```

Open a PR and enable automerge:

```bash
# 4. Open a PR (skip if one is already open for this branch)
gh pr create --repo hughobrien/battlecontrol \
  --title "TIM-{id}: <short description>" \
  --body "Closes TIM-{id}" \
  --base master

# 5. Enable automerge — PR merges automatically once "Compile and link" passes
gh pr merge --auto --merge
```

Then exit the worktree **keeping** the branch:

```
ExitWorktree(action: "keep")
```

After GitHub merges the PR automatically, clean up from `_default`:

```bash
# 6. Pull the merged changes into local master
git pull battlecontrol master

# 7. Remove the worktree directory and delete the local branch
git worktree remove .claude/worktrees/TIM-{id}
git branch -d worktree-TIM-{id}
```

## Cancellation / abandonment workflow

From `_default` (after `ExitWorktree(action: "keep")`):

```bash
git worktree remove .claude/worktrees/TIM-{id} --force
git branch -D worktree-TIM-{id}
```

## Notes

- New worktrees branch from `battlecontrol/master`. After the PR automerges, pull
  `battlecontrol/master` before cleanup so the next worktree starts from a complete state.
- Worktrees live at `.claude/worktrees/TIM-{id}/` — this path is gitignored.
- Local branches created by `EnterWorktree` are named `worktree-TIM-{id}` (not `TIM-{id}`).
- If `EnterWorktree` is called for a name that already exists as a branch or directory,
  use the `path:` form instead to re-enter the existing worktree.
