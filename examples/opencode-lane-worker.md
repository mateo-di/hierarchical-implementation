---
description: Worker a coordinating session runs over ACP to execute one unit it reviews. Keeps your own opencode permissions, denies commits, pushes and subagents, and turns high-impact commands into asks the coordinating session answers.
mode: primary
# Agent rules are checked after your global rules and the last match wins, so these only narrow
# them. The worker runs without --auto: every action left at "ask" goes to the coordinating
# session, which allows it once or rejects it. These rules narrow what a cooperative model runs.
# They are not a sandbox: a command your global rules allow, such as an interpreter, can still
# reach git or the network, so review the diff.
permissions:
  - {action: subagent, resource: "*", effect: deny}
  - {action: question, resource: "*", effect: deny}
  # MCP tools are named <server>_<tool>
  - {action: "*_*", resource: "*", effect: ask}
  - {action: delegation_plan, resource: "*", effect: allow}
  - {action: external_directory, resource: "*", effect: ask}
  - {action: webfetch, resource: "*", effect: ask}
  - {action: shell, resource: "git reset*", effect: ask}
  - {action: shell, resource: "git clean*", effect: ask}
  - {action: shell, resource: "git stash*", effect: ask}
  - {action: shell, resource: "gh *", effect: ask}
  - {action: shell, resource: "rm *", effect: ask}
  - {action: shell, resource: "kill *", effect: ask}
  - {action: shell, resource: "curl *", effect: ask}
  - {action: shell, resource: "wget *", effect: ask}
  - {action: shell, resource: "npm install*", effect: ask}
  - {action: shell, resource: "pip install*", effect: ask}
  - {action: shell, resource: "docker *", effect: ask}
  - {action: shell, resource: "kubectl *", effect: ask}
  - {action: shell, resource: "helm *", effect: ask}
  - {action: shell, resource: "terraform *", effect: ask}
  - {action: shell, resource: "gcloud *", effect: ask}
  - {action: shell, resource: "aws *", effect: ask}
  - {action: shell, resource: "az *", effect: ask}
  - {action: shell, resource: "psql *", effect: ask}
  - {action: shell, resource: "git -*", effect: ask}
  - {action: shell, resource: "*/git *", effect: ask}
  - {action: shell, resource: "env *", effect: ask}
  - {action: shell, resource: "command *", effect: ask}
  - {action: shell, resource: "bash -c*", effect: ask}
  - {action: shell, resource: "sh -c*", effect: ask}
  - {action: shell, resource: "ssh *", effect: ask}
  - {action: shell, resource: "scp *", effect: ask}
  # the last match wins, so the denies come after the asks they narrow
  - {action: shell, resource: "git commit*", effect: deny}
  - {action: shell, resource: "git push*", effect: deny}
  - {action: shell, resource: "git rebase*", effect: deny}
  - {action: shell, resource: "gh pr create*", effect: deny}
  - {action: shell, resource: "claude *", effect: deny}
  - {action: shell, resource: "opencode *", effect: deny}
  - {action: shell, resource: "codex *", effect: deny}
  - {action: shell, resource: "agy *", effect: deny}
---

You execute one unit for a coordinating session that reviews your diff. Change only the files the brief names. Never commit, push, open pull requests, or spawn agents. If a delegation gate asks for a plan, declare an audited_exception of type lane with the brief's files as the task's writePaths. You start in the worktree; run git as plain `git diff` or `git status`, never with `-C`. Some actions wait for the coordinating session to allow them. A rejected or denied action stays refused: report it instead of looking for another way. End with a summary of your diff and the exact output of the checks the brief asks for.
