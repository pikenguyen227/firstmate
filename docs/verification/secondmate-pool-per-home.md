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
The same run, measured directly, showed a second clone being handed the first clone's returned slot, which is why a secondmate home needs its own root.

Verified on 2026-09-23 with treehouse v2.3.0, herdr 0.9.1, git 2.48.1 on Darwin 27.0.0.
The guard drives real `bin/fm-spawn.sh --backend herdr` and `bin/fm-teardown.sh` in a named non-default Herdr lab session through `bin/fm-herdr-lab.sh`.
Every Treehouse call goes through a throwaway wrapper that injects a leading `--root` (the shape of an installed wrapper that pins a root), with a throwaway `HOME`, a throwaway default root per scenario, and throwaway homes and clones of a throwaway origin under one private temp dir removed at exit.
Leftover foreign slots are seeded the way they really arose: the secondmate clone leases slots from the shared default root and returns them.

The guard is the command that refreshes this record.
The output below predates moving secondmate pools outside the home: its S1 paths show the earlier `<mate>/state/treehouse-pool` root, while the guard's S1 now expects the home's own root under `<user state>/firstmate/treehouse-pools/` and asserts that no ancestor of the worktree holds the home's `CLAUDE.md` or `AGENTS.md`; its next run replaces this output.
`FM_TREEHOUSE_LIVE_BIN` names the real binary when the `treehouse` on `PATH` is a wrapper that pins its own root:

```sh
FM_SPAWN_POOL_PER_HOME_LIVE_E2E=1 FM_TREEHOUSE_LIVE_BIN=<real treehouse binary> \
  bash tests/fm-spawn-pool-per-home-live-e2e.test.sh
```

It exited 0.
Observed output, with the private temp dir shown as `<tmp>`, the lab suffix as `<n>`, and a tab as `<TAB>`:

```text
# treehouse binary: <tmp>/real-bin/treehouse (v2.3.0)
# primary clone common dir: <tmp>/primary-home/projects/app/.git
# secondmate clone common dir: <tmp>/mate-home/projects/app/.git
# S5 leased <tmp>/s5-later-root/.treehouse/app-71aa23/1/app
ok - treehouse v2.3.0: S5 a later --root wins over a wrapper's leading --root
# lab session: fm-lab-fm-pool-live-<n>
# spawn livep1 home=primary-home rc=0 elapsed=5s
#   out| spawned livep1 harness=sh kind=ship mode=no-mistakes yolo=off window=fm-lab-fm-pool-live-<n>:w1:p2 worktree=<tmp>/default-root-s12/.treehouse/app-71aa23/1/app
#   treehouse (cwd<TAB>argv)| <tmp>/primary-home/projects/app<TAB>get
ok - treehouse v2.3.0: S2 primary spawn lands in the default pool on its own clone (<tmp>/default-root-s12/.treehouse/app-71aa23/1/app)
# spawn livem1 home=mate-home rc=0 elapsed=5s
#   out| spawned livem1 harness=sh kind=ship mode=no-mistakes yolo=off window=fm-lab-fm-pool-live-<n>:w2:p2 worktree=<tmp>/mate-home/state/treehouse-pool/.treehouse/app-71aa23/1/app
#   treehouse (cwd<TAB>argv)| <tmp>/mate-home/projects/app<TAB>--root <tmp>/mate-home/state/treehouse-pool get
ok - treehouse v2.3.0: S1 secondmate spawn lands in its own pool on its own clone (<tmp>/mate-home/state/treehouse-pool/.treehouse/app-71aa23/1/app)
# S3 seeded free foreign slot <tmp>/default-root-s3/.treehouse/app-71aa23/1/app
# spawn livep2 home=primary-home rc=0 elapsed=8s
#   out| spawned livep2 harness=sh kind=ship mode=no-mistakes yolo=off window=fm-lab-fm-pool-live-<n>:w3:p2 worktree=<tmp>/default-root-s3/.treehouse/app-71aa23/2/app
#   treehouse (cwd<TAB>argv)| <tmp>/primary-home/projects/app<TAB>get
#   treehouse (cwd<TAB>argv)| <tmp>/primary-home/projects/app<TAB>get
ok - treehouse v2.3.0: S3 primary skips a foreign slot in 8s and a nested get lands in a new own-clone slot (<tmp>/default-root-s3/.treehouse/app-71aa23/2/app); foreign slot intact
ok - treehouse v2.3.0: S5 a nested get inside a held slot's subshell hands out a different slot
# S4 seeded free foreign slots:
#   <tmp>/default-root-s4/.treehouse/app-71aa23/1/app
#   <tmp>/default-root-s4/.treehouse/app-71aa23/2/app
#   <tmp>/default-root-s4/.treehouse/app-71aa23/3/app
#   <tmp>/default-root-s4/.treehouse/app-71aa23/4/app
#   <tmp>/default-root-s4/.treehouse/app-71aa23/5/app
# spawn livep3 home=primary-home rc=1 elapsed=12s
#   err| error: treehouse get kept handing out worktrees of another clone instead of this home's project '<tmp>/primary-home/projects/app' (treehouse root 'configured default'); rejected slots:
#   err|   <tmp>/default-root-s4/.treehouse/app-71aa23/1/app (worktree of git common dir '<tmp>/mate-home/projects/app/.git')
#   err|   <tmp>/default-root-s4/.treehouse/app-71aa23/2/app (worktree of git common dir '<tmp>/mate-home/projects/app/.git')
#   err|   <tmp>/default-root-s4/.treehouse/app-71aa23/3/app (worktree of git common dir '<tmp>/mate-home/projects/app/.git')
#   err|   <tmp>/default-root-s4/.treehouse/app-71aa23/4/app (worktree of git common dir '<tmp>/mate-home/projects/app/.git')
#   err| these slots were left untouched; clean them deliberately (for example with treehouse destroy) once they hold no live work; inspect window fm-lab-fm-pool-live-<n>:w4:p2
#   treehouse (cwd<TAB>argv)| <tmp>/primary-home/projects/app<TAB>get
#   treehouse (cwd<TAB>argv)| <tmp>/primary-home/projects/app<TAB>get
#   treehouse (cwd<TAB>argv)| <tmp>/primary-home/projects/app<TAB>get
#   treehouse (cwd<TAB>argv)| <tmp>/primary-home/projects/app<TAB>get
ok - treehouse v2.3.0: S4 primary fails after the retry bound naming 4 foreign slots and their owning clone; all 5 left intact
```

What each scenario establishes:

- S1: a secondmate spawn on a repository the primary also holds, while the default pool held a free slot of the primary's clone, typed `treehouse --root <mate>/state/treehouse-pool get` and landed on a worktree of its own clone in that pool; its teardown returned the slot.
- S2: a primary spawn typed plain `treehouse get` and landed in the default pool on its own clone.
- S3: a primary handed a free slot made by the secondmate clone skipped it in 8s, typed the nested `cd -- <proj> && treehouse get` from inside that slot's subshell, and landed in a new slot of its own clone; the foreign slot stayed in place as a worktree of the secondmate clone.
- S4: in a default pool of five free foreign slots the primary spawn failed after three retries, naming four rejected slots and their owning clone, and all five stayed in place.
- S5: the real binary honoured a later `--root` over the wrapper's leading one and never wrote to the leading root's pool, and (from S3) a nested `treehouse get` inside a held slot's subshell handed out a different slot.
