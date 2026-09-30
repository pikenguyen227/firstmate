---
name: task-intake
description: Load before resolving, routing, classifying, briefing, or dispatching a captain request for project work, and before filling or amending any crewmate or scout brief.
user-invocable: false
metadata:
  internal: true
---

# Task intake and briefs

`AGENTS.md` section 7 keeps the always-loaded intake boundary: secondmate routing, the evidence-not-authorization rule, per-task delivery mode and `yolo` resolution, the unregistered-project default, and merge authority.
`AGENTS.md` section 4 keeps dispatch-profile precedence and the typed-resolution outcomes, and section 11 keeps the brief safety rules.
This skill owns the intake and brief-authoring procedure between those boundaries.

## Resolve the project

Resolve the project independently for every request.
An explicit project wins, a clear follow-up inherits its referent, and otherwise match the request against the registry, work under way, and project code or README.
Proceed on one confident match while naming the project in plain language; ask one concise question when multiple or no projects plausibly match.
If no secondmate scope fits, use the main home or discuss creating an appropriate persistent secondmate.

## Keep the path direct

For one-off or infrequent operational work, start with the simplest direct end-to-end path.
Do not build wrappers, control planes, policy layers, custom verifiers, or automation unless the direct path exposes a concrete blocker or repeated need that justifies the added machinery.

## Classify the deliverable

Before commissioning an investigation, consult existing reports and established evidence.

- **Ship** is the default and produces a project change through the selected delivery mode; once implementation is authorized, dispatch a ship and keep any remaining bounded research inside it unless unresolved uncertainty could materially change whether or what to build.
- **Scout** produces knowledge in `data/<id>/report.md`, never a PR, and is appropriate for investigation, diagnosis, planning, reproduction, or audit work when the captain explicitly requests a separate knowledge or design deliverable or unresolved uncertainty could materially change whether or what to build.
- If established evidence already answers an informational question, relay it without a design-only scout; when implementation intent is unclear, answer and ask one concise implementation question when useful rather than dispatching speculative design work.
- Never both present a likely-enough solution and launch a parallel design exercise that is not expected to change it.

## Delivery details

On a `no-mistakes-prod-only` project, classify the task's surface: internal-only tooling, automation, contributor or operator process, and release or submission work ships `direct-PR`, while product-facing, mixed, and uncertain work ships `no-mistakes`; never infer internal-only from file location or project name.
Resolve the project's registered ship-branch prefix with `bin/fm-project-mode.sh --branch-prefix <project>` and pass it explicitly to the brief, ship spawn, and scout promotion as `--branch-prefix` (default `fm/` needs no flag).
Record the resulting mode, `yolo` merge posture, and the one-line reason for any deviation in the backlog item note.

## Concurrency

Treat file or subsystem overlap as a risk signal rather than an automatic reason to wait, and dispatch isolated work immediately with no concurrency cap when each change can be independently implemented and validated and the selected delivery path can reconcile ordinary rebases or conflicts.
Serialize only for a true semantic dependency, shared mutable external state, incompatible concurrent migration, or another concrete condition that makes independent progress or reconciliation unsafe; same-file editing alone is insufficient, and genuine blockers remain durable.

## Write the brief

`bin/fm-brief.sh` and its help own scaffold syntax, generated variants, status protocol, delivery-mode definitions of done, and exact safety mechanics.
Use its scaffold as the contract, then fill `## Captain's intent` (`{TASK}`) with the captain's own ask and any boundary the captain stated, plus the context needed to read it, including the substance of any report, decision, or PR the ask refers to.
Never widen the ask there into a general goal or an enumerated coverage list, because the reviewer treats that subsection as acceptance criteria.
Fill `## Firstmate spec` (`{FIRSTMATE_SPEC}`) with only the build instructions that ask requires, naming what stays out of scope when the ask is narrow; a generalization, consistency sweep, or extra hardening the captain did not ask for is follow-up work to note, not scope to add.
`bin/fm-dod-lib.sh` owns intent authoring without added speaker labels or direct address, its provenance markers, what a no-mistakes worker may pass as `--intent`, and the string's self-sufficiency rule.
Keep additions task-specific rather than repeating lifecycle instructions, and alter generated sections only when the task genuinely differs from the standard shape.
Status appends are sparse supervisor-actionable events, not routine progress; `bin/fm-classify-lib.sh` owns keyed open and resolved semantics, and `bin/fm-brief.sh` owns worker declaration instructions.
