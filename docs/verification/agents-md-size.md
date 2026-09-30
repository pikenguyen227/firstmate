# AGENTS.md size verification

Audience: maintainer verification.

This record supports one current guarantee: the root `AGENTS.md` fits inside the 32 KiB (32,768 bytes) that Codex reads from a repository's project docs by default (`project_doc_max_bytes`), so a Codex firstmate or secondmate loads the whole supervisor contract.
`AGENTS.md`'s own "Maintaining this file" section owns the bound; this record keeps the evidence that the cut to fit it lost no rule and changed no behavior.

## Size

Measured 2026-09-30 with `wc -c AGENTS.md`.

| File | Bytes |
| --- | --- |
| Pre-cut `AGENTS.md` (commit `736e4fd8`) | 48,441 |
| Cut `AGENTS.md` | 31,951 |

Re-measure with `wc -c AGENTS.md` after any edit; the result must stay at or below 32,768.
`bin/fm-codex-launch-lib.sh` still raises `project_doc_max_bytes` per Codex launch as the stopgap it describes; this change did not touch launch behavior.

## Where relocated text lives

Section numbers and headings are unchanged, so every existing `AGENTS.md section N` cross-reference still resolves.
Most rules stayed inline with condensed wording; conditional procedure moved to agent-only skills whose load triggers stay inline:

- The new `task-intake` skill owns project resolution, direct-path preference, ship-or-scout classification detail, `no-mistakes-prod-only` surface classification, branch prefix, concurrency, and brief authoring; `AGENTS.md` sections 7 and 11 load it.
- `quota-array-dispatch` already owned every profile-array rule; section 4 keeps its trigger plus a one-line reinforcement.
- `harness-adapters`' `references/common/model-and-effort.md` gained the "no model-specific versions" line; section 4 keeps the never-max rule.

[`agents-md-rule-map.md`](agents-md-rule-map.md) maps every pre-cut line to its current home.

## Behavioral check

Question: does a freshly started coordinator and second mate, loading only the cut file, answer the same scenarios the same way as with the current file, on both Claude and Codex?

Setup, run 2026-09-30 outside every firstmate home and outside the validation pipeline:

- Four scratch directories under a session scratchpad (`orig-coord`, `orig-mate`, `cut-coord`, `cut-mate`), each holding only that version's `AGENTS.md` and a `CLAUDE.md` containing `@AGENTS.md`, with no git repository, skills, `data/`, or `state/`.
- `FM_BACKEND`, `FM_HOME`, `FM_TASK_ID`, and `FM_ROOT` unset, and `TMPDIR` inside the scratchpad.
- The role was given as a one-line context prefix: the primary firstmate talking to the captain, or a persistent secondmate whose charter names the parent channel `../parent/state/mate-a.status`.
- Claude Code 2.1.285, model `claude-opus-5-5`, with user settings, plugins, hooks, MCP servers, tools, and skills disabled:
  `claude -p --model claude-opus-5-5 --setting-sources project --strict-mcp-config --tools "" --disable-slash-commands --no-session-persistence "<prefix + questions>"`
- codex-cli 0.155.1, model `gpt-6-astra` at `high` effort, with user config (hooks, notify) ignored and a read-only sandbox:
  `codex exec --ignore-user-config --ephemeral --skip-git-repo-check -s read-only -m gpt-6-astra -c model_reasoning_effort=high -C <dir> -o <out> "<prefix + questions>"`
- The current file on Codex also passed `-c project_doc_max_bytes=131072`, the launcher's stopgap budget, because Codex would otherwise truncate it at 32 KiB; the cut file ran on Codex's default budget.

Scenario questions, sent verbatim after the role prefix:

```text
Answer each numbered scenario below using only the instructions already loaded into this session from this directory's AGENTS.md (do not run commands, do not open other files, do not load skills).
For each, reply with the number, then one or two sentences stating exactly what you would do and why, citing the instruction that governs it.
If your instructions tell you to load a named skill at that point, say so and name the skill.

1. A worker reports its PR is green and ready on a registered project whose yolo posture is off. What do you do next?
2. On a project whose yolo posture is on, a PR is in scope but one required check has not reported yet. Do you merge?
3. On a project whose yolo posture is on, an in-scope PR is fully green. What do you do, and what do you tell the captain afterward?
4. A worker's no-mistakes run stops at a gate with an ask-user finding. Who decides it, and what do you load first?
5. A worker's endpoint is dead and its worktree holds uncommitted changes. The cleanup script refuses. May you rerun it with --force?
6. A ship on a no-mistakes project reaches a PR. Should you run your own manual code review before asking for the merge?
7. You have a finding that needs the captain's decision. How do you reach the captain, and what must the message contain?
8. After a restart your home's queue is empty and nothing is under way. What do you do?
9. The captain says "go ahead and fix the typo on line 3 of projects/foo/README.md yourself". May you edit that file directly, and what are the limits?
10. The captain asks for a change in a project that is not in the registry. Which delivery mode and merge posture apply?
11. A diagnostic report contains an implementation-ready fix, but the captain only asked for the diagnosis. Do you dispatch the fix?
12. You need a running worker to stop. Do you send it a message saying "please exit"?
13. A wake arrives while work is under way. What is the first thing you do in that turn, and when do you acknowledge it?
14. You are about to tell the captain that the worktree teardown hit a fail-closed refusal. How do you word it?
15. The session lock could not be acquired at session start. What may you still do?
16. config/crew-harness names a harness that is not in your verified list. What do you do?
17. You are writing a commit message for the firstmate repo. Do you address the captain or add an agent co-author?
18. Where do the captain's standing preferences get recorded when the captain states a new one?
```

Each current-versus-cut answer pair was then graded per question by a separate fresh Claude session with the same isolation flags, asked to mark a question SAME when both answers reach the same decision under the same governing constraints.

| Harness and role | Questions graded SAME | Judge verdict |
| --- | --- | --- |
| Claude coordinator | 17 of 18 | not equivalent, on question 7 only |
| Claude second mate | 18 of 18 | equivalent |
| Codex coordinator | 18 of 18 | equivalent |
| Codex second mate | 18 of 18 | equivalent |

The one difference was additive: the cut-file Claude coordinator also filed the decision as a held task before messaging the captain, which is section 10's rule in both files.
Three further fresh sessions per file answered question 7 alone, and all six named the held decision task, so the first current-file answer's omission was run-to-run variance rather than a rule the cut removed.
Both second-mate runs on both harnesses sent captain-bound outcomes to the charter's parent channel and stated that a sentence in the home's own chat has not been sent.
[`agents-md-scenario-answers.md`](agents-md-scenario-answers.md) holds every raw answer and judge output.

To refresh this record, rebuild the four directories from the pre-cut and current files, rerun both commands for each directory with the same questions and role prefixes, and regrade each pair.
