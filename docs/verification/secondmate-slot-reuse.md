# Secondmate slot reuse verification

Audience: maintainer verification.

This record supports the active guarantee that retiring a secondmate whose home is a leased Treehouse slot leaves nothing of that secondmate in the slot, so the next secondmate seeded onto it starts clean.
[`docs/configuration.md`](../configuration.md) owns the operator-facing rule and `bin/fm-teardown.sh` owns the removal, the leftover-process reap, and the unlanded-clone refusal.
The portable regressions in `tests/fm-secondmate-safety.test.sh` prove the teardown logic against a fake pool; this record proves the real Treehouse side.

## Real Treehouse keeps a retired home's ignored files

`treehouse return --force` keeps git-ignored files in the slot it takes back, and the next `treehouse get --lease` hands out that same slot.
A secondmate home's marker, records, and project clones are all git-ignored, so before this fix the retired secondmate's `.fm-secondmate-home` stayed in the slot and the next seed onto it was refused as already marked.

## Real Treehouse, real seed and teardown

Verified on 2026-09-24 with treehouse v2.3.0, git 2.48.1, herdr 0.9.1 on Darwin 27.0.0, at commit b866479 plus this guard.
The guard drives real `bin/fm-home-seed.sh` and `bin/fm-teardown.sh` from a throwaway primary Firstmate with its own origin.
Every Treehouse call goes through a throwaway wrapper that runs the real binary with a throwaway `HOME` and a throwaway `--root`, under one private temp dir removed at exit.
L1 to L6 close the secondmate's endpoint through a stand-in tmux, because the endpoint is not their subject and tmux is not installed on the verifying machine.
L7 spawns and retires real secondmates in a named non-default Herdr lab session through `bin/fm-herdr-lab.sh`.
L6's failed return is injected by the wrapper refusing one `return` call; the restore that follows, and the retry, run against the real binary.
L6 records the nested secondmate's route in the retiring parent's registry as well as its own, the shape `tests/fm-secondmate-safety.test.sh` uses, because forced cleanup validates nested homes against the retiring parent's registry.

The guard is the command that refreshes this record.
`FM_TREEHOUSE_LIVE_BIN` names the real binary when the `treehouse` on `PATH` is a wrapper that pins its own root:

```sh
FM_TREEHOUSE_LIVE_BIN=<real treehouse binary> \
  bash tests/fm-secondmate-slot-reuse-live-e2e.test.sh
```

It exited 0.
Observed output, with the private temp dir shown as `<tmp>`, the lab suffix as `<n>`, and the Herdr supervision banner lines omitted:

```text
# treehouse binary: <tmp>/real-bin/treehouse (v2.3.0)
# git: git version 2.48.1
# seed first rc=0 home=<tmp>/pool-root/.treehouse/primary-b9e5a1/1/primary
# L1 slot <tmp>/pool-root/.treehouse/primary-b9e5a1/1/primary is leased (held by first)
# L1 home-owned entries before retirement: .fm-secondmate-home .fm-secondmate-parent config data projects state
# fm-teardown.sh first  rc=0
# seed second rc=0 home=<tmp>/pool-root/.treehouse/primary-b9e5a1/1/primary
# L1 slot <tmp>/pool-root/.treehouse/primary-b9e5a1/1/primary is leased (held by second); marker=second
ok - treehouse v2.3.0: L1 retiring a pooled secondmate frees its real slot and the next seed takes it
# L2 detached pid <pid> cwd=<tmp>/pool-root/.treehouse/primary-b9e5a1/1/primary/projects/alpha
# fm-teardown.sh second  rc=0
#   teardown| teardown: reaping leaked secondmate home process(es) for second: <pid>
# seed third rc=0 home=<tmp>/pool-root/.treehouse/primary-b9e5a1/1/primary
ok - treehouse v2.3.0: L2 a detached process inside the home is reaped and the slot is freed
# L3 lsof on teardown PATH: none
# fm-teardown.sh third  rc=0
#   teardown| warning: lsof is unavailable; cannot resolve the tmux pane process group for third
ok - treehouse v2.3.0: L3 retirement without lsof completes with a warning and frees the slot
# seed keeper rc=0 home=<tmp>/pool-root/.treehouse/primary-b9e5a1/1/primary
# fm-teardown.sh keeper  rc=1
#   teardown| REFUSED: secondmate home project clone <tmp>/pool-root/.treehouse/primary-b9e5a1/1/primary/projects/alpha has local commit <sha> that no remote contains
#   teardown| Retiring secondmate home <tmp>/pool-root/.treehouse/primary-b9e5a1/1/primary would delete that unlanded work, so the home is left intact.
#   teardown| Land or push the work in each named clone and re-run, or get the captain's explicit OK to discard it, then --force.
# L4 after unpushed-commit refusal: slot leased (held by keeper), marker=keeper
# fm-teardown.sh keeper  rc=1
#   teardown| REFUSED: secondmate home project clone <tmp>/pool-root/.treehouse/primary-b9e5a1/1/primary/projects/scratch is not the top of its own git clone
#   teardown| Retiring secondmate home <tmp>/pool-root/.treehouse/primary-b9e5a1/1/primary would delete that unlanded work, so the home is left intact.
#   teardown| Land or push the work in each named clone and re-run, or get the captain's explicit OK to discard it, then --force.
# L4 after non-git refusal: slot leased (held by keeper), marker=keeper
ok - treehouse v2.3.0: L4 unpushed work and a non-git directory refuse retirement and keep the home and lease
# fm-teardown.sh keeper  rc=0
# seed fifth rc=0 home=<tmp>/pool-root/.treehouse/primary-b9e5a1/1/primary
ok - treehouse v2.3.0: L5 a stray .DS_Store under projects/ does not block retirement
# seed nested rc=0 home=<tmp>/pool-root/.treehouse/primary-b9e5a1/2/primary
# L6 parent slot <tmp>/pool-root/.treehouse/primary-b9e5a1/1/primary is leased (held by fifth); nested slot <tmp>/pool-root/.treehouse/primary-b9e5a1/2/primary is leased (held by nested)
# fm-teardown.sh fifth --force rc=0
# L6 after forced retirement: parent slot available, nested slot available
ok - treehouse v2.3.0: L6 a forced retirement sweeps a nested secondmate and frees both real slots
# seed sixth rc=0 home=<tmp>/pool-root/.treehouse/primary-b9e5a1/1/primary
# L6 sixth sources before: live-src.source
# fm-teardown.sh sixth  rc=1
#   teardown| injected return failure
#   teardown| error: treehouse return failed for secondmate home <tmp>/pool-root/.treehouse/primary-b9e5a1/1/primary; lease may still be held
# L6 after failed return: slot leased (held by sixth), marker=sixth, sources: live-src.<id>.last-launch live-src.runner live-src.source
# fm-teardown.sh sixth  rc=0
ok - treehouse v2.3.0: L6 a failed return restores the home and its process-event registration, and a retry frees the slot
# L7 lab session: fm-lab-fm-slot-live-<n>
# seed labfirst rc=0 home=<tmp>/pool-root/.treehouse/primary-b9e5a1/1/primary
# L7 spawn labfirst rc=0
#   out| spawned labfirst harness=sh kind=secondmate mode=secondmate yolo=off window=fm-lab-fm-slot-live-<n>:w1:p2 worktree=<tmp>/pool-root/.treehouse/primary-b9e5a1/1/primary
# fm-teardown.sh labfirst  rc=0
# seed labsecond rc=0 home=<tmp>/pool-root/.treehouse/primary-b9e5a1/1/primary
# L7 spawn labsecond rc=0
#   out| spawned labsecond harness=sh kind=secondmate mode=secondmate yolo=off window=fm-lab-fm-slot-live-<n>:w2:p2 worktree=<tmp>/pool-root/.treehouse/primary-b9e5a1/1/primary
# L7 labsecond pane w2:p2 live on slot <tmp>/pool-root/.treehouse/primary-b9e5a1/1/primary (leased (held by labsecond)), marker=labsecond
# fm-teardown.sh labsecond  rc=0
ok - treehouse v2.3.0: L7 in a Herdr lab a secondmate retires and a new one seeds and launches on the same slot
```

What each scenario establishes:

- L1: a retired secondmate's slot is `available` with no `.fm-secondmate-home`, `.fm-secondmate-parent`, `data`, `state`, `config`, or `projects` left, its meta and registry route are gone, and the next seed gets the same slot from the real pool with a marker naming the new secondmate.
- L2: a detached `sleep` whose working directory is inside the home's project clone is reaped by a retirement without `--force`, and the slot is freed and reused.
- L3: with `lsof` off `PATH`, retirement warns and completes, and the slot is freed.
- L4: an unpushed commit in a project clone, and then a non-git directory under `projects/`, each refuse retirement naming the path; the marker, the work, the meta, and the real lease stay, and the endpoint is not closed.
- L5: a stray `.DS_Store` under `projects/` does not block retirement.
- L6: a forced retirement of a secondmate with a nested secondmate on its own leased slot frees and clears both real slots; a failed return puts the home's files and its real `fm-procevent.sh` source registration back and keeps the lease, meta, and registry route, and a retry then frees the slot.
- L7: in a Herdr lab, a secondmate spawned on a leased slot is retired (its pane closed), and a new secondmate is seeded onto the same slot and launches there.

The same guard run against base commit 87e5c29 (the tree before this fix) fails at L1:

```text
# treehouse binary: <tmp>/real-bin/treehouse (v2.3.0)
# git: git version 2.48.1
# seed first rc=0 home=<tmp>/pool-root/.treehouse/primary-9192ed/1/primary
# L1 slot <tmp>/pool-root/.treehouse/primary-9192ed/1/primary is leased (held by first)
# L1 home-owned entries before retirement: .fm-secondmate-home .fm-secondmate-parent config data projects state
# fm-teardown.sh first  rc=0
not ok - treehouse v2.3.0: L1: retired secondmate left .fm-secondmate-home in the returned slot <tmp>/pool-root/.treehouse/primary-9192ed/1/primary
```

## Herdr end-to-end family

On 2026-09-24, with herdr 0.9.1 and `treehouse` on `PATH` replaced by a wrapper that runs the real v2.3.0 binary with a throwaway `HOME` and `--root`, each test ran in its own `fm-lab-*` session through `bin/fm-herdr-lab.sh`:

- `tests/fm-backend-herdr-agent-exit-shell-e2e.test.sh`: skipped (`skip: live: pi absent`).
- `tests/fm-backend-herdr-focus-flash-e2e.test.sh`: exited 0.
- `tests/fm-backend-herdr-launcher-workspace-e2e.test.sh`: exited 0.
- `tests/fm-backend-herdr-prune-safety-e2e.test.sh`, `tests/fm-backend-herdr-respawn-idem-e2e.test.sh`, `tests/fm-backend-herdr-stale-active-tab-e2e.test.sh`, `tests/fm-backend-herdr-workspace-per-home-e2e.test.sh`, `tests/fm-herdr-session-cleanup-e2e.test.sh`, `tests/fm-secondmate-lifecycle-e2e.test.sh`, and `tests/fm-spawn-pool-per-home-live-e2e.test.sh`: each exited 0.
- `tests/fm-backend-herdr-presentation-e2e.test.sh`: exited 1 after 670s. Its projection, cleanup, and teardown checks passed, and one concurrent secondmate recovery case failed with `error: herdr presentation recovery could not acquire its session lock; refusing a concurrent resume`. That is the recovery path, not retirement, and it ran while other agents' test suites were loading the machine. It was not rerun, so it is not recorded as passed.

The default Herdr session's workspace and tab list, captured read-only before and after the slot-reuse guard run, was identical.
After the whole family it had no added workspace or tab. One workspace that already existed, labelled `firstmate` and holding the tab `fm-settle-single-stale-z1` of another task, was gone. Every test here addressed only its own `fm-lab-*` session, but other agents were working in the default session at the same time, so this record does not establish what removed it.
tmux is not installed on the verifying machine, so tmux-backend coverage of these scenarios is left to CI.
