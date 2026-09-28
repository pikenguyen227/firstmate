---
name: strategy-autonomy
description: >-
  Apply the selected home strategy at session start, after a strategy change,
  and before dispatch, automatic fix rounds, second-mate creation, or fleet reviews.
user-invocable: false
metadata:
  internal: true
---

# Strategy autonomy

Read this home's `config/strategy` and run `bin/fm-strategy.sh status` after startup or a selection change.
`docs/configuration.md` ("Token strategies") owns the settings and mode table; this skill owns the coordinator's decisions and session application.
No selection, or a legacy selection without `autonomy=`, preserves existing supervision behavior until the captain applies a strategy.
A present autonomy value must be `full`, `balanced`, or `lean` and match `mode=`; report an invalid or mismatched value and ask before starting new discretionary work until it is corrected.
Use the recorded autonomy level, not inferred model strength, provider availability, or a drifted fresh-start setting, for decisions below.
These rules apply to the coordinator handling the work, including its supervision branch; they never authorize another actor to bypass a required approval.

## Apply the session policy

A confirmed strategy selection is consent to its present-session notification posture.
For balanced or lean, load `quiet` and enter through its existing lifecycle when the captain is present; never write its flag, launch a parallel monitor, or change notification classification yourself.
For full, use normal supervision; if quiet is active, load `quiet` and use its ordinary exit procedure before resuming normal supervision.
An explicit later `/quiet` or `/quiet off` overrides that posture for this session; do not immediately undo it at the next dispatch or notification.
A strategy change during away mode updates config but does not end or replace the away contract; reconcile the selected posture after the ordinary return catch-up.
On Pi and pi-signed, keep the existing supervision branch and follow quiet's referenced Pi procedure, not a daemon launch.
If the existing quiet lifecycle is unavailable on the current runtime, report the limitation and keep normal, safe supervision until it can be applied; do not claim routine turns have been suppressed.
The script reconciles fresh-start checks through their existing owner; follow a reported application failure before claiming the mode fully active.
Fresh starts retain that owner's supported-reader, idle, persist, and cooldown restrictions; the primary receives a suggestion, never an automatic restart.

## Decide when to dispatch

Apply the level before starting a new ship, scout, promotion to implementation, or routing new work to a second mate, including queued work whose dependency just cleared.
When routing to a second mate, include the request's autonomy level, approval already obtained, and fix-round count, and require it to carry those constraints into its own dispatch and worker instructions.
Classification uses the existing light/standard/hard tier descriptions even when a requested-model rule or custom rule wins routing.
Full permits automatic dispatch of authorized work, including unblocked queued work.
Balanced permits light and standard dispatch automatically; before hard or unusually expensive work, present the bounded plan and rough cost and obtain the captain's word.
Estimate scope, likely worker/validation rounds and quota impact; state uncertainty and never invent a dollar amount when pricing or usage is unavailable.
Lean requires a bounded plan and confirmation for every dispatch before the build begins.
An explicit approval already given for that concrete plan satisfies the confirmation; do not ask again and do not turn a generic queue entry into dispatch approval.
A mode does not invent tasks or expand authorization.
Keep pending dispatch decisions durable through `captain-hold-lifecycle`.

## Bound automatic fix rounds

Full allows automatic fix rounds within the selected delivery path's existing limits.
Balanced allows one automatic fix round per task, then asks before another; lean asks before the first fix round or retry.
A round is one requested corrective execution after a failed implementation or validation result, including an explicit pipeline fix response or rerunning a failed job; reattaching to a still-running operation and ordinary monitoring are not retries.
Record rounds used and any concrete additional approval in the existing task note, so restarting the coordinator does not reset the allowance.
Include the allowance and used count in the task's Firstmate specification and any validation instruction, never in captain intent.
Require the worker to return a keyed decision before exceeding it; the worker retains ownership of every pipeline response and fix.
A later strategy change applies at the next safe gate: steer active workers with the new allowance and existing count, without interrupting an in-progress round or cancelling validation.
Where a tool bundles internal attempts into one indivisible execution, disclose that boundary before authorizing the execution; do not claim to cap internal rounds the tool cannot pause.
Approval to spend another round never settles an ask-user finding: continue to apply `ask-user-authority` separately.
At a limit, wait for approval with validation still required; never skip a check, approve an unresolved finding, weaken validation, use `--yes`, or ship incomplete work to meet a token budget.

## Second mates and fleet reviews

Use the existing second-mate model pin; full permits second mates, balanced makes them optional when the benefit justifies the standing cost, and lean creates none without a concrete captain override.
Selecting lean does not retire running second mates or abandon their tasks; report that the one-coordinator target requires their ordinary approved retirement after work finishes.
Full permits proactive fleet reviews of authorized work and re-evaluation of queued work.
Balanced and lean do not start extra discretionary fleet audits or review sweeps; required heartbeat reconciliation, stale-worker recovery, safety scans, and queue bookkeeping still run through their existing owners.
Quiet's cheap scans and escalation backstop must remain active in every mode.

## Safety floor

No level changes delivery mode, validation rigor, merge authority, yolo, ask-user authority, escalation, or any AGENTS.md safety boundary.
Review-ready work, findings, decisions, failures, credentials, and every other captain-relevant event still reach the coordinator through the existing routing; balanced batching and lean's reduced routine turns both use quiet's bounded batching, never a new event filter.
Drain before handling and acknowledge only after handling exactly as the supervision contract requires.
An approval wait is never permission to abandon monitoring, hide a result, or discard work.
Do not change model strength automatically; model step-up is a separate decision outside this policy.
