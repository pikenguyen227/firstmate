Your scout task has been promoted to a ship task, mode=local-only. Your window, worktree, and context stay as they are; only the contract below changes.

# Task
## Captain's intent
Implement the investigated change.

## Firstmate spec
If these promotion steps were already completed before a relaunch, preserve the existing `fm/guide-scout` branch and continue from its current state; do not repeat them destructively.
1. **Verify isolation before anything else.** Run `pwd -P` and `git rev-parse --show-toplevel`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from. If either does not resolve to the worktree you were launched in, stop and escalate to firstmate.
2. Inventory this worktree's scratch state with `git status` and `git log` before changing anything.
3. Return to a clean default-branch base, then create your branch: `git checkout -b fm/guide-scout --`.
4. Carry over only the intended fix changes. Leave scratch commits, debug edits, and experiment files behind.
5. If you reproduced a bug, turn that reproduction into a regression test.
6. Treat the scout-time Firstmate spec and any unmarked legacy `# Task` text as investigation context, not captain intent or current ship-time instructions.
7. Everything else in your original instructions carries over unchanged: the status protocol; the instruction inbox and its acknowledgement; the escalation rules, including ask-user; and every safety rule, except where the current delivery contract below explicitly replaces scout-only delivery rules.


# Current delivery mode contract
This task is now kind=ship with mode=local-only.
This section supersedes every earlier brief instruction about delivery mode.
These current ship instructions supersede the scout delivery rules and report-based Definition of done.
Any earlier "Never push" or scout-only delivery language in this file is superseded.
The mode-specific Definition of done below is the current delivery contract.

# Current ship safety rule
1. Never push to any remote and never open a PR. Work only on your `fm/guide-scout` branch; firstmate handles the merge into local `main`.

# Coding guidelines
Adapted from https://github.com/multica-ai/andrej-karpathy-skills (MIT licensed); they reduce common LLM coding mistakes. They never override any other section of this brief, the captain's intent, or the project's own instructions and skills; where those mandate a gate, sweep, parity check, or style rule, follow them.
1. Think before coding. State your assumptions and surface tradeoffs. Proceed on a clear brief; when a genuine ambiguity would change the result, raise it with a needs-decision line instead of silently picking one reading.
2. Simplicity first. Write the minimum code that solves the task: no speculative features, no abstractions or configurability nobody asked for.
3. Surgical changes. Touch only what the task needs and match the existing conventions the project still endorses. Do not refactor or clean up unrelated code; remove only the imports, variables, and functions your own change made unused.
4. Goal-driven execution. Turn the task into verifiable success criteria (for a bug, a reproducing check first - a test where the project has a test runner) and loop until they are verified.

# Definition of done
Delivery contract: mode=local-only
Ship branch: fm/guide-scout
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch `fm/guide-scout`. Do NOT push, do NOT open a PR, do NOT merge.
A `done:` is accepted when the named head is on this project's shared local branch, not only on a detached copy; the check tests that head, not merely that a branch moved.
Keep your branch a clean fast-forward onto the current default branch - if `main` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append `done [at=<epoch>]: ready in branch fm/guide-scout` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local `main` through the guarded fast-forward path.
