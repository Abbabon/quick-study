# AGENTS.md

Rules for any coding agent working in this repo. Project details live in `CLAUDE.md`.

## Worktrees

- One worktree per feature: `git worktree add ../quick-study-<feature> -b feat/<feature>`.
- **Remove a worktree as soon as its branch is merged into master**, in the same session as the merge:

  ```sh
  git worktree remove ../quick-study-<feature>
  git branch -d feat/<feature>
  ```

- Before ending a session, run `git worktree list` and remove any worktree whose branch is already merged (`git branch --merged master`).
- Keep worktrees for unmerged branches. Never `--force`-remove a worktree with uncommitted changes without asking.
