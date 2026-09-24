On 2026-09-24, with herdr 0.9.1 and `treehouse` on `PATH` replaced by a wrapper that runs the real v2.3.0 binary with a throwaway `HOME` and `--root`, each test ran in its own `fm-lab-*` session through `bin/fm-herdr-lab.sh`:

- `tests/fm-backend-herdr-agent-exit-shell-e2e.test.sh`: skipped (`skip: live: pi absent`).
- `tests/fm-backend-herdr-focus-flash-e2e.test.sh`: exited 0.
- `tests/fm-backend-herdr-launcher-workspace-e2e.test.sh`: exited 0.
- The remaining family tests (presentation, prune-safety, respawn-idem, stale-active-tab, workspace-per-home, session-cleanup, spawn-pool-per-home) had not finished when this record was written; they are not recorded as passed here.

The default Herdr session's workspace and tab list, captured read-only before and after the slot-reuse guard run, was identical: no workspace or tab was added.
tmux is not installed on the verifying machine, so tmux-backend coverage of these scenarios is left to CI.
