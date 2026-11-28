# Supervised Codex unit lane on Linux

Use this opt-in workflow when the user explicitly selects an external Codex worker for a
bounded, reviewable unit. The driver owns the brief, review and integration. This is a
separate unit lane: the driver's gate does not count it as a native worker or grant the
driver an editing budget. Integrate the reviewed result through the repository's normal
Git workflow. Native workers and ACP remain the defaults.

## Before launch

- Record the driver's delegation decision. Confirm the user authorized this provider for
  the repository and brief, and that the Codex CLI is authenticated. Do not substitute a
  different provider, CLI or model.
- Use a clean, dedicated worktree under the Codex gate root. Record its canonical path,
  starting commit, unit name and owned files. The lane must be the only writer while running.
- Ensure the [Codex adapter](../../../adapters/codex/hooks.json) is installed and its hooks
  are trusted. Verify effective hook and project configuration first on a synthetic fixture.
  `--ignore-user-config` can prevent the installed gate from running. Do not use it to
  make this workflow pass, disable hooks, or trust an unfamiliar project's tools. If the
  expected hooks or permissions cannot be verified, use an existing worker path.
- This procedure uses the
  [Codex relay from `delegate-skills@48b53d3`](https://github.com/amElnagdy/delegate-skills/blob/48b53d33b53ef260de76c3d2c1313e2c62a24820/skills/codex-delegate/scripts/relay.mjs).
  Obtain it as a separately reviewed local file at that revision; HI does not install or
  download it. Use Node, Git and a working `systemd --user` instance. Test CLI compatibility
  before changing either pinned component.

## Start and authorize

Start a supervised turn with a **read-only** brief that asks Codex to confirm the worktree,
without receiving the editing task yet. The example assumes default Codex and HI config
paths. Set `WORKTREE`, `RELAY`, `BRIEF` and a unique systemd service name `RUN_UNIT` before
running it; use a different service name for each turn. Create `OUT_DIR` with `mktemp -d`
under a private directory outside the sandbox's writable roots, including `/tmp` and
`$TMPDIR` when writable. Keep the brief and results restricted to the current user.

```bash
systemd-run --user --wait --collect --unit "$RUN_UNIT" --service-type=exec \
  --property=KillMode=control-group --property=TimeoutStopSec=10s \
  --property=RuntimeMaxSec=12min --setenv="PATH=$PATH" --setenv=LANE_MODE=unit \
  -- node "$RELAY" --brief "$BRIEF" --cd "$WORKTREE" --out-dir "$OUT_DIR" \
  --sandbox read-only --timeout 10m --web-search disabled --clean-env --keep-env LANE_MODE
```

The service owns the child and its descendants even if they start new process groups.
Record the exit from `systemd-run --wait`. Confirm the service stopped before reading a
final receipt or reusing the worktree. A nonzero exit is not a successful turn.
Systemd supervision is not a filesystem or network sandbox; Codex still needs the correct
explicit sandbox and hook policy. If supervision fails or does not settle, preserve the
worktree and investigate before launching another turn.

Check `events.jsonl` in the new run directory for `thread.started`. Compare its ID with
`threadId` in `result.json` and record it along with the canonical worktree and base. Missing
or conflicting evidence is a stop; a preflight error can write a result without starting
Codex. Confirm the reported working directory and that the worktree is still clean. Use
the exact observed ID as `THREAD` for this lane. The supervisor may set `LANE_MODE=unit`,
but that alone does not grant a gate decision. The coordinator records the decision for
the child's thread in the same gate state Codex uses:

```bash
env LANE_MODE=unit "$GATE" decide "$WORKTREE" "$THREAD" direct \
  "lane: execute the authorized Codex unit"
```

Here `GATE` is the local HI `hierarchical-implementation-gate.sh` path. Do not authorize
a thread from another run or worktree. For nondefault gate state or root settings, pass
the same reviewed settings to both the service and this command. If Codex uses a custom
`CODEX_HOME`, pass it to the service with `--setenv` and preserve it through the relay with
`--keep-env CODEX_HOME`; verify that the trusted hooks load from that location.

## Edit, correct and review

Use the same supervised command for each editing turn, with a fresh output directory,
`--sandbox workspace-write --session "$THREAD"` and the same `WORKTREE`. Set the sandbox
explicitly on **every** turn; do not add network access or use `--resume-last`. Give only
the bounded implementation brief on the first editing turn and a delta brief on a
correction. No staging, commits, publication or further workers by the lane. Check the
same thread and effective worktree after each turn; `thread.started` on resume identifies
the resumed thread, not a new worker.

Once the service settles, independently inspect Git from the recorded base, the index
and untracked files, and run the unit's checks. Also compare `HEAD` with the base to catch
an unexpected commit and check ignored paths when the unit might have written to them.
`completed` is a process outcome; Codex can exit successfully after
a hook denied the edit. `touchedFiles` is just a point-in-time Git observation and cannot
replace review. The driver decides whether to accept, correct or redo the work.

For cancellation, request `SIGTERM` on the supervisor service's **main process** with
`systemctl --user kill --kill-whom=main --signal=SIGTERM "$RUN_UNIT"` and await service exit.
If it does not exit, use `systemctl --user stop "$RUN_UNIT"` to stop the control group.
The relay may update `result.json` again after a shutdown-time write. If the run fails, is
cancelled or has an uncertain close, keep the worktree and receipt for inspection. Do not
automatically retry, integrate or remove partial edits.

The relay stores brief, events and stderr outside the worktree. Use a new private directory
per turn. Record the unit, worktree, base, service name, sandbox, thread ID and
`delegate-relay.result.v1` process outcome. Record the driver's verification separately,
including whether Git reported a clean tree, changes, or was unavailable. After review
or explicit recovery, retain only the metadata and verification evidence needed, and
remove transient artifacts according to the repository's retention policy. Don't publish
the raw transcript as evidence.
