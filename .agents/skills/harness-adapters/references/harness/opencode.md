# OpenCode

The tracked primary plugins target pinned OpenCode 2.3.2.
OpenCode 1 primary plugin support is retired because the two plugin APIs require different entry points and lifecycle hooks.
OpenCode workers are not ported: `../../../bin/fm-spawn.sh` still writes the OpenCode 1 busy-state plugin into each worker worktree, so an OpenCode worker needs OpenCode 1, and dispatching an OpenCode worker on OpenCode 2 is not supported yet.
Claude Code and Codex workers are unaffected.
Earlier OpenCode 1 observations below are historical until reverified on OpenCode 2.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | The Firstmate-owned OpenCode 1 worker plugin's semantic `session.status`: `busy` and `retry` are active, `idle` is inactive, latched to the worker's own session. |
| Exit command | `/exit`. |
| Interrupt | Double Escape; it is known to be flaky while a long shell command runs, so use `../../../bin/fm-control.sh <task-id> relaunch` for a wedged pane. |
| Skill invocation | No separate verified form beyond normal slash-command behavior; use natural language when the exact command is uncertain. |
| Resume | Relaunch with `--continue` to resume the most recent session for the current directory, then send the next instruction after the TUI is ready because `--prompt` does not auto-submit alongside `--continue`. |
| Model flag | `--model <provider/model>`. |
| Effort flag | None for Firstmate's interactive `opencode --prompt` launch; `opencode run` has `--variant`, but that is not this path. The effort instead rides the launch's `OPENCODE_CONFIG_CONTENT` JSON as the `build` agent's `variant` keyed to the resolved model, the config schema's per-model reasoning-effort field verified on 1.18.32. It is emitted only when the resolved model's provider is known to expose that effort as a variant (`anthropic/*`: high, max; `openai/*`: low, medium, high, xhigh); with no model resolved, another provider, or an effort outside its family's list, the variant is omitted and the permission-only launch is unchanged. |
| Model discovery | Run `opencode models [provider]` to list available provider/model identifiers. |
| Trust dialog | None. |
| Marker | None; OpenCode publishes no identity marker, so `../../../bin/fm-harness.sh` identifies it from process ancestry. |

OpenCode can auto-upgrade in the background, and the running TUI can exit mid-task.
That behavior was observed live during an upgrade from 1.15.7 to 1.17.3.
If the pane shows the exit banner, use the verified resume path above.

## Busy-queued Enter

While OpenCode 1.18.4 is mid-turn, its composer accepts Enter as a "send when the turn ends" keystroke but does not clear the typed text until the turn finishes.
Without a conversion, every typed-plane send to a busy OpenCode pane falsely reports "Enter swallowed", and a daemon escalation that lands while the primary is mid-turn appears wedged.

Tmux and Herdr delegate this exception to the one `fm_composer_queued_enter_verdict` policy in `../../../bin/fm-composer-lib.sh`.
Backend-specific signals are documented in `../../../docs/tmux-backend.md` and `../../../docs/herdr-backend.md`.
Regression coverage is `../../../tests/fm-tmux-submit-busy.test.sh`, `../../../tests/fm-composer-lib.test.sh`, and `../../../tests/fm-backend-herdr.test.sh`.
The live Herdr guard is `FM_HERDR_SUBMIT_CONFIRM_LIVE=1 ../../../tests/fm-herdr-submit-confirm-live-e2e.test.sh`.

## Primary integration

The five tracked plugins export OpenCode 2 default definitions with `id` and `setup` from `.opencode/plugins/`.
They use the V2 runtime context directly and have no package dependency; the verified CLI pin is 2.3.2.
The session-start plugin subscribes only to `session.created`, then queues one nudge per session id when `../../../bin/fm-sessionstart-nudge.sh` prints one; a `--continue` resume or a session reopened in the TUI gets no new digest.
The watcher and turn-end plugins subscribe to terminal `session.execution.*` events.
The turn-end callback is passive and queues one follow-up with `ctx.session.prompt({ delivery: "queue" })` when `../../../bin/fm-turnend-guard.sh` returns 2.
In a home with `config/supervision-host` the watch-arm plugin spawns the supervision host instead of `../../../bin/fm-watch-arm.sh`, with Claude's print mode as its headless engine; [`supervision-host.md`](../../../../../docs/supervision-host.md) owns the host.
Headless `opencode run` may process an immediate queued follow-up, but cannot receive a later watcher wake after its process exits.
On native Windows, the operational-input adapter runs its Bash helper through `bash`; macOS and Linux invoke it directly.

The companion `.opencode/plugins/fm-primary-watch-arm.js` owns normal TUI watcher supervision, wakes it through `ctx.session.prompt`, and coordinates with the guard before a blind-turn follow-up.
The PreToolUse-equivalent watcher-arm seatbelt blocks by throwing from `ctx.tool.hook("execute.before")` for shell commands.
