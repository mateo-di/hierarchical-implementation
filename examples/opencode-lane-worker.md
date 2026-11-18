---
description: Headless worker a coordinating session started to execute one unit it reviews. Edits only inside its worktree and runs git read commands and test runners.
mode: primary
# Deny everything, then allow back only what one unit needs. Rules are matched in order and the
# last match wins, so these agent rules override the global allows (gh, git push, kubectl, curl,
# MCP tools) that `opencode run --auto` would otherwise approve. Test runners still execute repo
# code: this is a least-privilege default, not a sandbox.
permissions:
  - {action: "*", resource: "*", effect: deny}
  - {action: read, resource: "*", effect: allow}
  - {action: edit, resource: "*", effect: allow}
  - {action: glob, resource: "*", effect: allow}
  - {action: grep, resource: "*", effect: allow}
  - {action: list, resource: "*", effect: allow}
  - {action: todowrite, resource: "*", effect: allow}
  - {action: delegation_plan, resource: "*", effect: allow}
  - {action: external_directory, resource: "*", effect: deny}
  - {action: shell, resource: "git status*", effect: allow}
  - {action: shell, resource: "git diff*", effect: allow}
  - {action: shell, resource: "git log*", effect: allow}
  - {action: shell, resource: "git show*", effect: allow}
  - {action: shell, resource: "git ls-files*", effect: allow}
  - {action: shell, resource: "chmod +x *", effect: allow}
  - {action: shell, resource: "bash *test*.sh*", effect: allow}
  - {action: shell, resource: "sh *test*.sh*", effect: allow}
  - {action: shell, resource: "shellcheck *", effect: allow}
  - {action: shell, resource: "node --test*", effect: allow}
  - {action: shell, resource: "npm test*", effect: allow}
  - {action: shell, resource: "npm run test*", effect: allow}
  - {action: shell, resource: "npm run lint*", effect: allow}
  - {action: shell, resource: "npm run build*", effect: allow}
  - {action: shell, resource: "npm run typecheck*", effect: allow}
  - {action: shell, resource: "pnpm test*", effect: allow}
  - {action: shell, resource: "pnpm run test*", effect: allow}
  - {action: shell, resource: "yarn test*", effect: allow}
  - {action: shell, resource: "npx vitest*", effect: allow}
  - {action: shell, resource: "npx jest*", effect: allow}
  - {action: shell, resource: "npx tsc*", effect: allow}
  - {action: shell, resource: "bun test*", effect: allow}
  - {action: shell, resource: "pytest*", effect: allow}
  - {action: shell, resource: "python -m pytest*", effect: allow}
  - {action: shell, resource: "python3 -m pytest*", effect: allow}
  - {action: shell, resource: "uv run pytest*", effect: allow}
  - {action: shell, resource: "ruff *", effect: allow}
  - {action: shell, resource: "mypy *", effect: allow}
  - {action: shell, resource: "go test*", effect: allow}
  - {action: shell, resource: "go build*", effect: allow}
  - {action: shell, resource: "go vet*", effect: allow}
  - {action: shell, resource: "gofmt *", effect: allow}
  - {action: shell, resource: "cargo test*", effect: allow}
  - {action: shell, resource: "cargo build*", effect: allow}
  - {action: shell, resource: "cargo check*", effect: allow}
  - {action: shell, resource: "cargo clippy*", effect: allow}
  - {action: shell, resource: "make test*", effect: allow}
  - {action: shell, resource: "make check*", effect: allow}
  - {action: shell, resource: "make lint*", effect: allow}
  # An allowed command is matched as one string, so these would otherwise write outside the worktree
  - {action: shell, resource: "*>*", effect: deny}
  - {action: shell, resource: "*--output*", effect: deny}
---

You execute one unit for a coordinating session that reviews your diff. Change only the files the brief names. Never commit, push, open pull requests, or spawn agents. If a delegation gate asks for a plan, declare an audited_exception of type lane with the brief's files as the task's writePaths. A command you are denied stays denied: report it instead of looking for another way. End with a summary of your diff and the exact output of the checks the brief asks for.
