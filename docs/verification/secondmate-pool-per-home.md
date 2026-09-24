# Secondmate Treehouse pool verification

Audience: maintainer verification.

This record supports the active guarantee that every firstmate home gets task worktrees of its own project clone, even when another home holds a clone of the same repository.
[`docs/configuration.md`](../configuration.md) owns the operator-facing rule and `fm_treehouse_home_pool_root` in [`bin/fm-wake-lib.sh`](../../bin/fm-wake-lib.sh) owns where each home's pool lives.
The portable regression `tests/fm-spawn-pool-per-home.test.sh` proves the spawn logic against a fake treehouse; this record proves the real Treehouse side of the contract.

## Real Treehouse, single-slot destroy

When a pre-move in-home pool holds a slot claimed by a task the home still records, `fm_treehouse_pool_root_drain` in [`bin/fm-wake-lib.sh`](../../bin/fm-wake-lib.sh) offers each other slot to `treehouse --root <root> destroy <worktree> --yes` instead of the pool-wide `--all`, and relies on that form keeping a slot that holds work.

Verified on 2026-09-24 with treehouse v2.3.0 on Darwin, in a throwaway sandbox (throwaway `HOME`, origin, clone, and `--root`, shown as `<tmp>`).
Three slots were leased with `treehouse --root <tmp>/root get --lease --no-fetch`; slot 1 was returned (disposable), slot 2 was returned and then made dirty with an untracked file, and slot 3 was left leased.
Each was then destroyed on its own with `treehouse --root <tmp>/root destroy <slot worktree> --yes`, in this order, with these results (Treehouse's report quoted as recorded, abbreviated where marked `...`):

```text
slot 2 (dirty):       did not destroy 2 (dirty); re-run with --include-unlanded   exit 1, worktree still present
slot 3 (leased):      did not destroy 3 (leased); re-run with --include-leased    exit 1, worktree still present
slot 1 (disposable):  Destroyed 1 worktree ... [disposable]                        exit 0, worktree gone
```

So single-slot destroy applies the same safe-by-default checks as the pool-wide form: it removes only a disposable slot and refuses, with a non-zero exit, one that is dirty or leased.
Scenario S6 of `tests/fm-spawn-pool-per-home-live-e2e.test.sh` repeats this against the real binary outside the Herdr lab and is the command that refreshes this section.

## Real Treehouse, real spawn, Herdr lab

Treehouse names a pool by repository, so on one root every clone of a repository shares one pool whose slots are worktrees of whichever clone created them.
An earlier run, measured directly, showed a second clone being handed the first clone's returned slot, which is why a secondmate home needs its own root.

Verified on 2026-09-24 with treehouse v2.3.0, herdr 0.9.1, git 2.48.1 on Darwin 27.0.0; tmux is not installed on this host and no scenario needs it.
The guard drives real `bin/fm-spawn.sh --backend herdr` (including `--relaunch`) and `bin/fm-teardown.sh` (task teardown and secondmate retirement) in a named non-default Herdr lab session through `bin/fm-herdr-lab.sh`.
Every Treehouse call goes through a throwaway wrapper that injects a leading `--root` (the shape of an installed wrapper that pins a root), with a throwaway `HOME`, a throwaway default root per scenario, and throwaway homes and clones of a throwaway origin under one private temp dir removed at exit.
Leftover foreign slots are seeded the way they really arose: the secondmate clone leases slots from the shared default root and returns them.
Workers run `sh -c 'echo pool-live-ok; exec sleep 600'` as a raw launch command, so no agent starts and no prompt is submitted.

The guard is the command that refreshes this record.
`FM_TREEHOUSE_LIVE_BIN` names the real binary when the `treehouse` on `PATH` is a wrapper that pins its own root:

```sh
FM_SPAWN_POOL_PER_HOME_LIVE_E2E=1 FM_TREEHOUSE_LIVE_BIN=<real treehouse binary> \
  PATH=<dir holding herdr>:$PATH bash tests/fm-spawn-pool-per-home-live-e2e.test.sh
```

It exited 0.
Observed output, with the private temp dir shown as `<tmp>`, the lab suffix as `<n>`, and a tab as `<TAB>`:

```text
# treehouse binary: <tmp>/real-bin/treehouse (v2.3.0)
# primary clone common dir: <tmp>/primary-home/projects/app/.git
# secondmate clone common dir: <tmp>/mate-home/projects/app/.git
# S5 leased <tmp>/s5-later-root/.treehouse/app-4f66b9/1/app
ok - treehouse v2.3.0: S5 a later --root wins over a wrapper's leading --root
# S6 destroy <tmp>/s6-root/.treehouse/app-4f66b9/2/app rc=1
#   | 🌳 Destroyed 0 worktrees in <tmp>/s6-root/.treehouse/app-4f66b9/2/app.
#   | 🌳 Skipped 1 worktree:
#   |   2     [dirty]  <tmp>/s6-root/.treehouse/app-4f66b9/2/app  re-run with --include-unlanded to include
#   | did not destroy 2 (dirty); re-run with --include-unlanded
# S6 destroy <tmp>/s6-root/.treehouse/app-4f66b9/3/app rc=1
#   | 🌳 Destroyed 0 worktrees in <tmp>/s6-root/.treehouse/app-4f66b9/3/app.
#   | 🌳 Skipped 1 worktree:
#   |   3     [leased]  <tmp>/s6-root/.treehouse/app-4f66b9/3/app  re-run with --include-leased to include
#   | did not destroy 3 (leased); re-run with --include-leased
# S6 destroy <tmp>/s6-root/.treehouse/app-4f66b9/1/app rc=0
#   | 🌳 Destroyed 1 worktree in <tmp>/s6-root/.treehouse/app-4f66b9/1/app and freed 360 B.
#   |   1     [disposable]  360 B  <tmp>/s6-root/.treehouse/app-4f66b9/1/app
ok - treehouse v2.3.0: S6 single-slot destroy removes a disposable slot and refuses a dirty or leased one
# lab session: fm-lab-fm-pool-live-<n>
# spawn livep1 home=primary-home rc=0 elapsed=8s
#   out| spawned livep1 harness=sh kind=ship mode=no-mistakes yolo=off window=fm-lab-fm-pool-live-<n>:w1:p2 worktree=<tmp>/default-root-s12/.treehouse/app-4f66b9/1/app
#   treehouse (cwd<TAB>argv)| <tmp>/primary-home/projects/app<TAB>get
ok - treehouse v2.3.0: S2 primary spawn lands in the default pool on its own clone (<tmp>/default-root-s12/.treehouse/app-4f66b9/1/app)
# spawn livem1 home=mate-home rc=0 elapsed=8s
#   out| spawned livem1 harness=sh kind=ship mode=no-mistakes yolo=off window=fm-lab-fm-pool-live-<n>:w2:p2 worktree=<tmp>/user-state/firstmate/treehouse-pools/livemate-57b4b6c5fe39/.treehouse/app-4f66b9/1/app
#   treehouse (cwd<TAB>argv)| <tmp>/mate-home/projects/app<TAB>--root <tmp>/user-state/firstmate/treehouse-pools/livemate-57b4b6c5fe39 get
ok - treehouse v2.3.0: S1 secondmate spawn lands in its own pool on its own clone (<tmp>/user-state/firstmate/treehouse-pools/livemate-57b4b6c5fe39/.treehouse/app-4f66b9/1/app)
# S3 seeded free foreign slot <tmp>/default-root-s3/.treehouse/app-4f66b9/1/app
# spawn livep2 home=primary-home rc=0 elapsed=12s
#   out| spawned livep2 harness=sh kind=ship mode=no-mistakes yolo=off window=fm-lab-fm-pool-live-<n>:w3:p2 worktree=<tmp>/default-root-s3/.treehouse/app-4f66b9/2/app
#   treehouse (cwd<TAB>argv)| <tmp>/primary-home/projects/app<TAB>get
#   treehouse (cwd<TAB>argv)| <tmp>/primary-home/projects/app<TAB>get
ok - treehouse v2.3.0: S3 primary skips a foreign slot in 12s and a nested get lands in a new own-clone slot (<tmp>/default-root-s3/.treehouse/app-4f66b9/2/app); foreign slot intact
ok - treehouse v2.3.0: S5 a nested get inside a held slot's subshell hands out a different slot
# S4 seeded free foreign slots:
#   <tmp>/default-root-s4/.treehouse/app-4f66b9/1/app
#   <tmp>/default-root-s4/.treehouse/app-4f66b9/2/app
#   <tmp>/default-root-s4/.treehouse/app-4f66b9/3/app
#   <tmp>/default-root-s4/.treehouse/app-4f66b9/4/app
#   <tmp>/default-root-s4/.treehouse/app-4f66b9/5/app
# spawn livep3 home=primary-home rc=1 elapsed=12s
#   err| error: treehouse get kept handing out worktrees of another clone instead of this home's project '<tmp>/primary-home/projects/app' (treehouse root 'configured default'); rejected slots:
#   err|   <tmp>/default-root-s4/.treehouse/app-4f66b9/1/app (worktree of git common dir '<tmp>/mate-home/projects/app/.git')
#   err|   <tmp>/default-root-s4/.treehouse/app-4f66b9/2/app (worktree of git common dir '<tmp>/mate-home/projects/app/.git')
#   err|   <tmp>/default-root-s4/.treehouse/app-4f66b9/3/app (worktree of git common dir '<tmp>/mate-home/projects/app/.git')
#   err|   <tmp>/default-root-s4/.treehouse/app-4f66b9/4/app (worktree of git common dir '<tmp>/mate-home/projects/app/.git')
#   err| these slots were left untouched; clean them deliberately (for example with treehouse destroy) once they hold no live work; inspect window fm-lab-fm-pool-live-<n>:w4:p2
#   treehouse (cwd<TAB>argv)| <tmp>/primary-home/projects/app<TAB>get
#   treehouse (cwd<TAB>argv)| <tmp>/primary-home/projects/app<TAB>get
#   treehouse (cwd<TAB>argv)| <tmp>/primary-home/projects/app<TAB>get
#   treehouse (cwd<TAB>argv)| <tmp>/primary-home/projects/app<TAB>get
ok - treehouse v2.3.0: S4 primary fails after the retry bound naming 4 foreign slots and their owning clone; all 5 left intact
# spawn livem7 home=mate-home rc=1 elapsed=2s
#   err| error: could not resolve this home's own Treehouse pool root: pool root '<tmp>/mate-home/user-state/firstmate/treehouse-pools/livemate-57b4b6c5fe39' sits under firstmate home '<tmp>/mate-home', whose supervisor instructions its workers would load; refusing to allocate a worktree from another home's pool; inspect window fm-lab-fm-pool-live-<n>:w5:p2
#   treehouse (cwd<TAB>argv)| 
ok - treehouse v2.3.0: S7 a pool root under a firstmate home refuses the spawn before any treehouse call
# S8 seeded legacy slots: claimed=<tmp>/mate-home/state/treehouse-pool/.treehouse/app-4f66b9/1 free=<tmp>/mate-home/state/treehouse-pool/.treehouse/app-4f66b9/2 dirty=<tmp>/mate-home/state/treehouse-pool/.treehouse/app-4f66b9/3 leased=<tmp>/mate-home/state/treehouse-pool/.treehouse/app-4f66b9/4
# spawn livem8 home=mate-home rc=0 elapsed=10s
#   out| spawned livem8 harness=sh kind=ship mode=no-mistakes yolo=off window=fm-lab-fm-pool-live-<n>:w5:p3 worktree=<tmp>/user-state/firstmate/treehouse-pools/livemate-57b4b6c5fe39/.treehouse/app-4f66b9/1/app
#   err| warning: this home's retired in-home Treehouse pool <tmp>/mate-home/state/treehouse-pool still holds slots it could not drain; they were left untouched and are no longer handed out:
#   err| <tmp>/mate-home/state/treehouse-pool/.treehouse/app-4f66b9/1 (claimed by task livelegacy)
#   err| <tmp>/mate-home/state/treehouse-pool/.treehouse/app-4f66b9/3 (kept by Treehouse: leased, in use, or holding dirty or unlanded work)
#   err| <tmp>/mate-home/state/treehouse-pool/.treehouse/app-4f66b9/4 (kept by Treehouse: leased, in use, or holding dirty or unlanded work)
#   treehouse (cwd<TAB>argv)| <tmp>/mate-home/projects/app<TAB>--root <tmp>/user-state/firstmate/treehouse-pools/livemate-57b4b6c5fe39 get
ok - treehouse v2.3.0: S8 the next spawn drains the legacy in-home pool: the disposable slot is removed; the claimed, dirty and leased slots are kept and reported
# relaunch livem8 home=mate-home rc=1
#   err| error: task livem8's recorded worktree '<tmp>/mate-home/state/treehouse-pool/.treehouse/app-4f66b9/1/app' sits under firstmate home '<tmp>/mate-home', whose supervisor instructions a worker there would load; refusing to relaunch; land or save its work, tear the task down, and spawn it again; inspect window fm-lab-fm-pool-live-<n>:w5:p4
# relaunch livem8 home=mate-home rc=0
#   out| spawned livem8 harness=sh kind=ship mode=no-mistakes yolo=off window=fm-lab-fm-pool-live-<n>:w5:p5 worktree=<tmp>/user-state/firstmate/treehouse-pools/livemate-57b4b6c5fe39/.treehouse/app-4f66b9/1/app
ok - treehouse v2.3.0: S9 relaunch refuses a recorded worktree inside the home, naming it, and relaunches one in the outside pool
# retire livemate rc=1
#   | 🌳 Destroyed 0 worktrees in <tmp>/user-state/firstmate/treehouse-pools/livemate-57b4b6c5fe39/.treehouse/app-4f66b9.
#   | 🌳 Skipped 1 worktree:
#   |   1     [dirty]  <tmp>/user-state/firstmate/treehouse-pools/livemate-57b4b6c5fe39/.treehouse/app-4f66b9/1/app  re-run with --include-unlanded to include
#   | 🌳 Destroyed 1 worktree in <tmp>/mate-home/state/treehouse-pool/.treehouse/app-4f66b9 and freed 497 B.
#   |   1     [disposable]  497 B  <tmp>/mate-home/state/treehouse-pool/.treehouse/app-4f66b9/1/app
#   | 🌳 Skipped 2 worktrees:
#   |   3     [dirty]   <tmp>/mate-home/state/treehouse-pool/.treehouse/app-4f66b9/3/app  re-run with --include-unlanded to include
#   |   4     [leased]  <tmp>/mate-home/state/treehouse-pool/.treehouse/app-4f66b9/4/app  leased: name the exact path with --include-leased (never removed by --all)
#   | REFUSED: secondmate home <tmp>/mate-home still owns Treehouse pool slots it could not clean; left intact:
#   | <tmp>/user-state/firstmate/treehouse-pools/livemate-57b4b6c5fe39/.treehouse/app-4f66b9/1 (kept by Treehouse: leased, in use, or holding dirty or unlanded work)
#   | <tmp>/mate-home/state/treehouse-pool/.treehouse/app-4f66b9/3 (kept by Treehouse: leased, in use, or holding dirty or unlanded work)
#   | <tmp>/mate-home/state/treehouse-pool/.treehouse/app-4f66b9/4 (kept by Treehouse: leased, in use, or holding dirty or unlanded work)
# retire livemate rc=0
#   | 🌳 Destroyed 1 worktree in <tmp>/user-state/firstmate/treehouse-pools/livemate-57b4b6c5fe39/.treehouse/app-4f66b9 and freed 356 B.
#   |   1     [disposable]  356 B  <tmp>/user-state/firstmate/treehouse-pools/livemate-57b4b6c5fe39/.treehouse/app-4f66b9/1/app
#   | 🌳 Destroyed 2 worktrees in <tmp>/mate-home/state/treehouse-pool/.treehouse/app-4f66b9 and freed 715 B.
#   |   3     [disposable]  357 B  <tmp>/mate-home/state/treehouse-pool/.treehouse/app-4f66b9/3/app
#   |   4     [disposable]  358 B  <tmp>/mate-home/state/treehouse-pool/.treehouse/app-4f66b9/4/app
#   | teardown livemate complete (window fm-lab-fm-pool-live-<n>:w9:p9, worktree <tmp>/mate-home)
ok - treehouse v2.3.0: S10 retiring a secondmate refuses while any slot of either pool holds work, then cleans its outside pool and its legacy pool
```

`herdr workspace list` and `herdr tab list` on the default session returned the same workspace and tab ids and labels before and after the run, and `herdr session list` showed no `fm-lab-fm-pool-live-*` session left; the private temp dir was removed.

What each scenario establishes:

- S1: a secondmate spawn on a repository the primary also holds, while the default pool held a free slot of the primary's clone, typed `treehouse --root <user state>/firstmate/treehouse-pools/<id>-<hash> get` and landed on a worktree of its own clone in that pool, outside the home, with no ancestor directory holding the home's `CLAUDE.md` or `AGENTS.md`; its teardown returned the slot.
- S2: a primary spawn typed plain `treehouse get` and landed in the default pool on its own clone.
- S3: a primary handed a free slot made by the secondmate clone skipped it, typed the nested `cd -- <proj> && treehouse get` from inside that slot's subshell, and landed in a new slot of its own clone; the foreign slot stayed in place as a worktree of the secondmate clone.
- S4: in a default pool of five free foreign slots the primary spawn failed after three retries, naming four rejected slots and their owning clone, and all five stayed in place.
- S5: the real binary honoured a later `--root` over the wrapper's leading one and never wrote to the leading root's pool, and (from S3) a nested `treehouse get` inside a held slot's subshell handed out a different slot.
- S6: single-slot destroy removed the disposable slot and refused the dirty and leased ones with exit 1, as recorded in the section above.
- S7: a secondmate spawn whose pool root resolved under its own home refused, naming the home, and made no Treehouse call and no task record.
- S8: with the pre-move `<home>/state/treehouse-pool` holding a slot claimed by a task the home still records, a disposable slot, a dirty slot and a leased slot, the next secondmate spawn landed in the outside pool, removed only the disposable slot, and reported the other three with their reasons.
- S9: relaunching a task whose record points at the in-home claimed slot refused, naming the home; pointed back at its outside-pool worktree, the same relaunch succeeded on that worktree.
- S10: retiring the secondmate from the primary refused while the outside slot held uncommitted work and the legacy pool held a dirty and a leased slot, naming each and keeping all work, the home and its record; once those were clean, retirement removed both pools and the home.
