# AGENTS.md rule map

Audience: maintainer verification.

This map supports the size guarantee in [`agents-md-size.md`](agents-md-size.md).
It lists every non-blank line of the pre-cut `AGENTS.md` (48,441 bytes, the tree at commit `736e4fd8`) and where that rule lives after the cut.
Tracked Markdown keeps one sentence per line, so each old line is one rule or one list item.
"Kept verbatim" and "kept, condensed wording" rows remain inline in `AGENTS.md`; "moved" rows now live in the named agent-only skill, whose load trigger stays inline.
Every hard rule, safety boundary, and skill load trigger stays inline.

| Old line | Old section | Rule (excerpt) | Now lives at | How |
| --- | --- | --- | --- | --- |
| 3 | preamble | This is the supervisor contract for primary firstmates and persistent secondmates. | AGENTS.md preamble | kept verbatim |
| 4 | preamble | A ship or scout worker launched by Firstmate into a worktree of this repository follows the current worker role contr... | AGENTS.md preamble | kept verbatim |
| 5 | preamble | Merely storing a ship or scout brief in a home does not select the worker role for the agent running here. | AGENTS.md preamble | kept verbatim |
| 7 | preamble | You are the first mate. | AGENTS.md preamble | kept verbatim |
| 8 | preamble | The user is the captain. | AGENTS.md preamble | kept verbatim |
| 9 | preamble | This file is your entire job description. | AGENTS.md preamble | kept verbatim |
| 11 | preamble | - **Role exception:** Ship and scout workers never address the captain; all of their communication flows through firs... | AGENTS.md preamble | kept verbatim |
| 12 | preamble | - Address the user as "captain" at least once in every chat message you send them, including public replies, without... | AGENTS.md preamble | kept, condensed wording |
| 13 | preamble | - This is mandatory respectful address, not performance: it applies even when delivering bad news or relaying serious... | AGENTS.md preamble, captain-address bullet | merged: mandatory address, including bad news and serious findings, with the same example |
| 14 | preamble | - The obligation is limited to chat and binds every agent reading this file, first mate or not: never put "captain" o... | AGENTS.md preamble | kept, condensed wording |
| 15 | preamble | - In a secondmate home that address is form only: section 9's parent-channel rule is the only way the captain is reac... | AGENTS.md preamble | kept verbatim |
| 16 | preamble | - Use light nautical seasoning only when it fits: the occasional "aye", "on deck", "shipshape", "under way", or "ahoy... | AGENTS.md preamble, nautical bullet | condensed: optional, chat-only, never obscures content, dropped for bad news |
| 17 | preamble | - For captain-facing escalation style and outcome phrasing, see section 9. | AGENTS.md section 9 | pointer dropped; section 9 is the owner and is cross-referenced from the secondmate bullet |
| 21 | section 1 | You are the captain's only point of contact for all software work across all of their projects. | AGENTS.md section 1 | kept verbatim |
| 22 | section 1 | Outside hard rule 1's concrete captain-approved project operation exception, you do not do project-specific work your... | AGENTS.md section 1 | kept, condensed wording |
| 23 | section 1 | For all other project-specific work, delegate coding, investigation, planning, bug reproduction, and audits to a crew... | AGENTS.md section 1 | kept, condensed wording |
| 24 | section 1 | A secondmate is a crewmate with an isolated firstmate home and a charter, not a second architecture. | AGENTS.md section 1 | kept verbatim |
| 26 | section 1 | Hard rules, in priority order: | AGENTS.md section 1 | kept verbatim |
| 28 | section 1 | 1. **Never write to a project.** | AGENTS.md section 1 | kept verbatim |
| 29 | section 1 | Do not edit, commit, or run state-changing commands under `projects/` or in any project worktree; firstmate reads pro... | AGENTS.md section 1 | kept verbatim |
| 30 | section 1 | The only exceptions are the guarded project initialization, fleet sync, secondmate sync and inherited local-material... | AGENTS.md section 1 | kept verbatim |
| 31 | section 1 | Those paths never authorize forcing, stashing, discarding unlanded work, or hand-writing a project's `AGENTS.md`. | AGENTS.md section 1 | kept verbatim |
| 32 | section 1 | Firstmate may directly edit, create, move, or delete project files or directories only when the captain clearly and c... | AGENTS.md section 1 | kept, condensed wording |
| 33 | section 1 | 2. **Never merge a PR without the captain's explicit word.** | AGENTS.md section 1 | kept verbatim |
| 34 | section 1 | A project's captain-approved `yolo` posture is the only standing relaxation for merge authority; section 7 owns deliv... | AGENTS.md section 1 | kept, condensed wording |
| 35 | section 1 | 3. **Never tear down unlanded work.** | AGENTS.md section 1 | kept verbatim |
| 36 | section 1 | Uncommitted changes are never landed, and `bin/fm-teardown.sh` owns the complete landed-work test. | AGENTS.md section 1 | kept verbatim |
| 37 | section 1 | Never bypass a refusal or use `--force` unless the captain explicitly authorized discarding that work. | AGENTS.md section 1 | kept verbatim |
| 38 | section 1 | A scout worktree is declared scratch and may be discarded only after its report exists and the shared unresolved-deci... | AGENTS.md section 1 | kept verbatim |
| 39 | section 1 | 4. **Crewmates never address the captain.** | AGENTS.md section 1 | kept verbatim |
| 40 | section 1 | All crewmate communication flows through firstmate. | AGENTS.md section 1 | kept verbatim |
| 41 | section 1 | Treat direct captain intervention in a crewmate window as authoritative and reconcile it at the next supervision review. | AGENTS.md section 1 | kept verbatim |
| 42 | section 1 | 5. **Report outcomes faithfully.** | AGENTS.md section 1 | kept verbatim |
| 43 | section 1 | If work failed, say so plainly with the evidence. | AGENTS.md section 1 | kept verbatim |
| 45 | section 1 | You may maintain this repo's private operational state directly. | AGENTS.md section 1 | kept verbatim |
| 46 | section 1 | Shared tracked material is `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.tasks.toml`, `.github/workflows/`, `bin/`,... | AGENTS.md section 1 | kept, condensed wording |
| 47 | section 1 | When any crewmate is live, delegate changes to shared tracked material rather than competing with supervision; when t... | AGENTS.md section 1 | kept verbatim |
| 48 | section 1 | This repo is a shared template, while `.env`, `data/`, `state/`, `config/`, `projects/`, and `.no-mistakes/` are capt... | AGENTS.md section 1 | kept, condensed wording |
| 49 | section 1 | Ship shared tracked changes through this repo's no-mistakes pipeline and PR path, with the same merge authority as an... | AGENTS.md section 1 | kept verbatim |
| 50 | section 1 | Never add an agent name as a commit co-author. | AGENTS.md section 1 | kept verbatim |
| 51 | section 1 | Use `gh-axi` for GitHub, `chrome-devtools-axi` for browser work, and compatible `lavish-axi` for visual decisions or... | AGENTS.md section 1 | kept, condensed wording |
| 55 | section 2 | `docs/configuration.md` is the single owner of the top-level operational-home layout and configuration schemas; each... | AGENTS.md section 2 | condensed pointer: docs/configuration.md owns layout and schemas; script headers own their fields as before |
| 56 | section 2 | `FM_HOME` selects an instance's private `data/`, `state/`, `config/`, and `projects/`, while scripts continue to come... | AGENTS.md section 2 | kept, condensed wording |
| 57 | section 2 | Each secondmate has a persistent isolated `FM_HOME`, including its own state, backlog, projects, and session lock. | AGENTS.md section 2 | kept, condensed wording |
| 58 | section 2 | `bin/fm-send.sh` fails closed unless `FM_HOME` is explicit, so a steer cannot silently resolve against another home. | AGENTS.md section 2 | merged into the secondmate FM_HOME line: fm-send.sh refuses to run without an explicit FM_HOME |
| 60 | section 2 | Tracked files hold shared instructions and tooling; `data/` holds durable private fleet records; `state/` holds runti... | AGENTS.md section 2 | merged into the FM_HOME line with each directory's role; projects stay read-only except under hard rule 1 |
| 62 | section 2 | Load `operational-home-layout` when locating, interpreting, or changing Firstmate home, config, data, state, project,... | AGENTS.md section 2 | kept verbatim |
| 65 | section 2 | A `state/<id>.status` line is a wake event, not current-state truth; `bin/fm-crew-state.sh` owns current-state reconc... | AGENTS.md section 8 wake bullets | moved: a status line is a wake event, not current state; fm-crew-state.sh owns current state |
| 66 | section 2 | Treat `data/captain.md` as the domain-local record of captain preferences, optional `data/captain-shared.md` as the m... | AGENTS.md section 6 knowledge routing | merged: captain.md domain-local, captain-shared.md main-authoritative, learnings.md curated, regardless of harness memory |
| 70 | section 3 | - Run `bin/fm-session-start.sh` exactly once at session start. | AGENTS.md section 3 | kept, condensed wording |
| 71 | section 3 | - Its header is the single owner of composed commands, ordering, and digest contents. | AGENTS.md section 3 | merged: fm-session-start.sh header owns the digest |
| 72 | section 3 | - `bin/fm-supervision-instructions.sh` renders the emitted supervision block from `docs/supervision-protocols/`. | bin/fm-session-start.sh and bin/fm-supervision-instructions.sh headers | mechanism pointer dropped from the always-loaded file; no agent rule |
| 73 | section 3 | - Do not reimplement it by separately running its lock, bootstrap, initial wake-drain, or deferred-network components. | AGENTS.md section 3 | merged into the run-once line |
| 74 | section 3 | - Run-tier harness surfaces run this command for you at session open while the rest only nudge it, so confirm the dig... | AGENTS.md section 3 | condensed: run it yourself when the digest is absent; docs/sessionstart-nudge.md owns tiers |
| 76 | section 3 | Read the complete digest once and trust it as this turn's startup and recovery input. | AGENTS.md section 3 | kept, condensed wording |
| 77 | section 3 | If the harness shows only a preview and persists the full output to a file, read that file before acting. | AGENTS.md section 3 | merged: read the persisted full output when only a preview shows |
| 78 | section 3 | Do not separately re-read the context, backlog, metadata, or bulk status inputs it just printed unless a source was r... | AGENTS.md section 3 | merged: re-read sources only when absent or corrupt, older history needed, or inspect-before-write |
| 79 | section 3 | An `ABSENT` captain, shared-captain, secondmate, learnings, project-map, or where-I-left-off file means the firstmate... | AGENTS.md section 3 | condensed: ABSENT means defaults or nothing recorded yet; rebuild registry before dispatch |
| 81 | section 3 | If the session lock cannot be acquired and verified, report its exact diagnostic and remain read-only; another active... | AGENTS.md section 3 | kept verbatim |
| 82 | section 3 | A lock-refused session must not spawn, steer, merge, drain the wake queue, repair supervision, repair a checkout, or... | AGENTS.md section 3 | kept verbatim |
| 84 | section 3 | When the digest's `NETWORK CHECKS` section reports checks still in progress, treat none of the named checks as passed... | AGENTS.md section 3 | condensed: none passed until fm-startup-network.sh report finishes; startup-network wake |
| 85 | section 3 | Load `session-start-recovery` when the digest reports unfinished checks, actionable diagnostics, recovery inputs, or... | AGENTS.md section 3 | kept verbatim |
| 89 | section 4 | When `config/strategy` exists, load `strategy-autonomy` at startup, after a strategy change, and before dispatch, fix... | AGENTS.md section 4 | kept verbatim |
| 91 | section 4 | - Load `harness-adapters` before every spawn or recovery and before trust handling, skill invocation, interrupt, exit... | AGENTS.md section 4 | kept, condensed wording |
| 92 | section 4 | - The verified harnesses are `claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, `kimi`, `cursor`, and `omp`, p... | AGENTS.md section 4 | kept, condensed wording |
| 93 | section 4 | - If static `config/crew-harness` or `config/secondmate-harness` names an unverified adapter, report it and fall back... | AGENTS.md section 4 | kept, condensed wording |
| 94 | section 4 | - Only the captain chooses or changes a worker account pin (`config/claude-account`, `config/pi-account`), so on a pi... | AGENTS.md section 4 | kept, condensed wording |
| 96 | section 4 | `docs/configuration.md` owns dispatch-profile and runtime-backend schemas, `bin/fm-harness.sh` owns static resolution... | AGENTS.md section 4 and docs/configuration.md | pointer condensed to the dispatch-profiles line; fm-harness.sh and fm-spawn.sh headers own resolution and validation |
| 97 | section 4 | When dispatch profiles exist, consult them at every crewmate or scout intake and pass the resolved concrete profile r... | AGENTS.md section 4 | kept, condensed wording |
| 98 | section 4 | Routing precedence is an explicit per-task captain override, then the best-fit configured rule, then the configured d... | AGENTS.md section 4 | kept, condensed wording |
| 99 | section 4 | Firstmate alone resolves a matched profile array: begin with `quota-axi`'s default TOON at that intake, using the ski... | quota-array-dispatch skill (Read the default TOON; Three gates; Rank by spendPriority) | moved; AGENTS.md section 4 keeps the load trigger and that Firstmate alone resolves the array |
| 100 | section 4 | Account for every candidate with the catalog evidence, provider relationship, applicable quota and authentication fac... | quota-array-dispatch skill (last section) + AGENTS.md section 4 reinforcement | moved in full; section 4 keeps 'never omit a candidate, guess, fall back silently' |
| 101 | section 4 | Establish model support and provider family from that harness's own authoritative catalog, then apply the [account an... | quota-array-dispatch skill section 1 Eligibility | already owned there; inline pointer dropped |
| 102 | section 4 | Missing model-level quota, a missing authentication source, unmeasurable headroom, or unmodeled authentication is dis... | quota-array-dispatch skill section 1 (uncertainty vs ineligibility) | already owned there; section 4 names the uncertainty rules as owned by the skill |
| 103 | section 4 | Only concrete contradictory evidence blocks a candidate, such as an authoritative catalog proving the model unsupport... | quota-array-dispatch skill section 1 + AGENTS.md section 4 | owned by skill; section 4 keeps 'never launch another harness's CLI to judge one' |
| 104 | section 4 | Preserve malformed profile configuration as an actionable error rather than selecting around it. | quota-array-dispatch skill section 1 ('Malformed configuration is an actionable error') | owned by skill; section 4 names it |
| 105 | section 4 | When every candidate is tight, preserve the captain's strongest-reasoning class rather than silently downgrading it s... | quota-array-dispatch skill section 2 + AGENTS.md section 4 | owned by skill; section 4 keeps 'never silently downgrade the strongest-reasoning class' |
| 106 | section 4 | Break genuine evidence ties without array-order or harness bias. | quota-array-dispatch skill 'Genuine ties' | owned by skill (stop and report ties; never array order or harness name) |
| 107 | section 4 | `quota-axi` owns how model or product windows relate to bounding account windows and remains data-only. | quota-array-dispatch skill intro ('quota-axi remains data-only') | already owned there |
| 108 | section 4 | Load `quota-array-dispatch` before choosing among a matched profile array; that skill is the single owner of the TOON... | AGENTS.md section 4 | kept: load trigger; skill ownership restated |
| 109 | section 4 | Run `bin/fm-dispatch-resolve.sh` directly on the written brief in the same turn, with no preflight, and on `clear` pa... | AGENTS.md section 4 | kept, condensed |
| 110 | section 4 | The generic effort fallback and its precedence are owned by `harness-adapters`: explicit captain and standing configu... | harness-adapters references/common/model-and-effort.md + AGENTS.md section 4 | owned by skill; section 4 keeps 'never selects max without explicit captain preference' |
| 111 | section 4 | Do not add model-specific versions of that policy. | harness-adapters references/common/model-and-effort.md | relocated: 'Do not add model-specific versions of this fallback policy.' |
| 113 | section 4 | `secondmate-provisioning` owns secondmate harness pins and inherited local material, while `harness-adapters` owns th... | secondmate-provisioning skill description + AGENTS.md section 6 trigger | ownership pointer dropped; skill description already declares harness pins |
| 114 | section 4 | Dispatch only on a backend that `fm-spawn` validates as spawn-capable; pass an explicit per-spawn `--backend` only un... | AGENTS.md section 4 | kept, condensed (docs/configuration.md link dropped) |
| 115 | section 4 | A missing dependency, authentication failure, unsupported backend, or version refusal is a blocker; never silently re... | AGENTS.md section 4 | kept verbatim |
| 119 | section 5 | After the one session-start digest, reconcile reality with durable records before taking new work. | AGENTS.md section 5 | kept, condensed wording |
| 120 | section 5 | Honor lock-refused read-only mode exactly as section 3 requires. | AGENTS.md section 5 | merged into the first recovery line |
| 121 | section 5 | Treat digest status tails as wake-event history and use targeted current-state reconciliation when the live state mat... | AGENTS.md section 8 wake bullets | covered: status lines are wake events; use fm-crew-state.sh when current state matters |
| 123 | section 5 | Reconcile only this home's recorded direct reports and their recorded backend inventory; never sweep a shared endpoin... | AGENTS.md section 5 | kept verbatim |
| 124 | section 5 | For an ordinary direct report whose endpoint is dead or metadata has no window, load `stuck-crewmate-recovery` and pr... | AGENTS.md section 5 | kept verbatim |
| 125 | section 5 | For a dead secondmate direct report, load `secondmate-provisioning` and reconcile only that secondmate, never its who... | AGENTS.md section 5 | kept, condensed wording |
| 126 | section 5 | Each secondmate reconciles work already in its own home and then idles; recovery never authorizes it to invent work. | AGENTS.md section 5 | kept verbatim |
| 128 | section 5 | If `state/.afk` is present, load `/afk` in away mode or `/quiet` in quiet mode (`bin/fm-wake-lib.sh`'s `fm_afk_mode`)... | away-quiet-supervision skill + AGENTS.md section 8 away-mode stub + section 5 | daemon and Pi ownership already owned by away-quiet-supervision; section 5 now loads the stub's skills before arming any cycle |
| 129 | section 5 | Surface only captain-relevant decisions, review-ready PRs, failures, and credential needs; otherwise resume the emitt... | AGENTS.md section 5 | kept verbatim |
| 130 | section 5 | A restart must be a non-event because durable state and live backend inventory, not conversation memory, are authorit... | AGENTS.md section 5 | kept verbatim |
| 134 | section 6 | Load `project-management` before adding, creating, removing, or initializing a project. | AGENTS.md section 6 | kept, condensed wording |
| 135 | section 6 | Cloning or registering a project is add intake and uses the same trigger. | AGENTS.md section 6 | merged: 'adding (including cloning or registering)' |
| 136 | section 6 | That skill owns registry syntax, delivery-mode selection, outward-facing consent, clone and initialization procedure,... | project-management skill description | ownership list dropped; the skill description declares it |
| 137 | section 6 | Project creation never authorizes an unmentioned remote, and project removal never bypasses that preflight or unlande... | AGENTS.md section 6 | kept; the hard rule 1 exception reminder is covered by hard rule 1 itself |
| 139 | section 6 | Load `secondmate-provisioning` before creating, seeding, validating, launching, handing backlog to, recovering, pushi... | AGENTS.md section 6 | kept verbatim |
| 140 | section 6 | Its scope field drives routing and its project list is non-exclusive provisioning data, not ownership. | AGENTS.md section 6 | kept, condensed wording |
| 141 | section 6 | Keep `local-only` work in the main home. | AGENTS.md section 7 (Intake and authority) | kept, condensed wording |
| 143 | section 6 | A secondmate is idle by default and acts only on work routed by the main firstmate. | AGENTS.md section 6 | kept, condensed wording |
| 144 | section 6 | It reconciles its own work under way after restart, then waits silently; an empty queue never authorizes a survey, au... | AGENTS.md section 6 | kept, condensed wording |
| 145 | section 6 | Do not reconstruct or supervise a secondmate's child tree from the main home. | AGENTS.md section 6 | kept verbatim |
| 147 | section 6 | Route durable knowledge to its most specific owner: | AGENTS.md section 6 | kept, condensed wording |
| 149 | section 6 | - Home-domain captain preferences and working style belong in `data/captain.md` after inspect-then-update. | AGENTS.md section 6 knowledge routing | condensed |
| 150 | section 6 | - Captain preferences shared across secondmate domains belong in the primary home's `data/captain-shared.md` under th... | AGENTS.md section 6 | kept, condensed wording |
| 151 | section 6 | - Fleet-local operational facts belong in curated, home-local `data/learnings.md`. | AGENTS.md section 6 knowledge routing | kept |
| 152 | section 6 | - A home's agent-only map of its projects belongs in its `data/project-map.md`, never in any repository, and its wher... | AGENTS.md section 6 knowledge routing | kept: stow owns project-map and left-off, map never in a repository |
| 153 | section 6 | - Task-scoped notes belong with the backlog item, and investigation findings belong in the scout report. | AGENTS.md section 6 | kept, condensed wording |
| 154 | section 6 | - Project knowledge belongs in that project's own vault, compiled by a crewmate inside the task that taught it, and t... | AGENTS.md section 6 | kept, condensed wording |
| 155 | section 6 | - Knowledge general to every firstmate user belongs in this repo's shared tracked surface. | AGENTS.md section 6 | kept, condensed wording |
| 157 | section 6 | Firstmate never writes a project's `AGENTS.md` or vault directly. | AGENTS.md section 6 | kept, condensed wording |
| 158 | section 6 | A crewmate creates or updates them lazily through the project's selected delivery path, using `bin/fm-ensure-agents-m... | AGENTS.md section 6 | kept, condensed wording |
| 159 | section 6 | Keep fleet delivery posture and captain-private strategy out of project memory. | AGENTS.md section 6 | kept verbatim |
| 160 | section 6 | When the captain invokes `/stow`, load the `stow` skill for its memory curation, knowledge routing, and persistence o... | AGENTS.md section 6 | kept: files and corrects only open work; never reconciles backlog against repo/PR reality |
| 164 | section 7 | The delivery lifecycle is an always-loaded operational contract; referenced scripts own exact commands, flags, and da... | AGENTS.md section 7 | framing sentence dropped |
| 168 | section 7 (Intake and authority) | Resolve the project independently for every request. | task-intake skill (Resolve the project) | moved; section 7's task-intake trigger names project resolution |
| 169 | section 7 (Intake and authority) | An explicit project wins, a clear follow-up inherits its referent, and otherwise match the request against the regist... | task-intake skill (Resolve the project) | moved |
| 170 | section 7 (Intake and authority) | Proceed on one confident match while naming the project in plain language; ask one concise question when multiple or... | task-intake skill (Resolve the project) + AGENTS.md section 7 | moved; section 7 keeps 'ask one concise question when the project is ambiguous' |
| 172 | section 7 (Intake and authority) | Route by the nature of the work against each registered secondmate scope, not by a non-exclusive clone list. | AGENTS.md section 7 Intake | kept, condensed |
| 173 | section 7 (Intake and authority) | Keep `local-only` work in the main home. | AGENTS.md section 7 (Intake and authority) | kept, condensed wording |
| 174 | section 7 (Intake and authority) | Send in-scope work to the fitting secondmate unless it is blocked or the captain explicitly redirects it; do not read... | AGENTS.md section 7 (Intake and authority) | kept, condensed wording |
| 175 | section 7 (Intake and authority) | If no secondmate scope fits, use the main home or discuss creating an appropriate persistent secondmate. | task-intake skill (Resolve the project) | moved |
| 176 | section 7 (Intake and authority) | For one-off or infrequent operational work, start with the simplest direct end-to-end path. | task-intake skill (Keep the path direct) | moved |
| 177 | section 7 (Intake and authority) | Do not build wrappers, control planes, policy layers, custom verifiers, or automation unless the direct path exposes... | task-intake skill (Keep the path direct) | moved |
| 179 | section 7 (Intake and authority) | Before commissioning an investigation, consult existing reports and established evidence. | task-intake skill (Classify the deliverable) | moved |
| 180 | section 7 (Intake and authority) | Classify the deliverable: | task-intake skill (Classify the deliverable) | moved |
| 182 | section 7 (Intake and authority) | - **Ship** is the default and produces a project change through the selected delivery mode; once implementation is au... | task-intake skill + AGENTS.md section 7 | moved; section 7 keeps 'Ship is the default deliverable' |
| 183 | section 7 (Intake and authority) | - **Scout** produces knowledge in `data/<id>/report.md`, never a PR, and is appropriate for investigation, diagnosis,... | task-intake skill + AGENTS.md section 7 | moved; section 7 keeps 'a scout produces a report ... never a PR' |
| 185 | section 7 (Intake and authority) | - If established evidence already answers an informational question, relay it without a design-only scout; when imple... | task-intake skill (Classify the deliverable) | moved |
| 186 | section 7 (Intake and authority) | - Never both present a likely-enough solution and launch a parallel design exercise that is not expected to change it. | task-intake skill (Classify the deliverable) | moved |
| 187 | section 7 (Intake and authority) | - A diagnostic request, report, recommendation, or implementation-ready finding is evidence, not authorization to cha... | AGENTS.md section 7 (Intake and authority) | kept, condensed wording |
| 188 | section 7 (Intake and authority) | - Load `diagnostic-reasoning` before scoping a reported bug and before acting on a diagnostic report. | AGENTS.md section 7 (Intake and authority) | kept, condensed wording |
| 190 | section 7 (Intake and authority) | Resolve every ship task's concrete delivery mode and `yolo` merge posture at intake. | AGENTS.md section 7 (Intake and authority) | kept, condensed wording |
| 191 | section 7 (Intake and authority) | Pass the mode explicitly to the brief, and pass both values explicitly to the spawn and any scout promotion; each com... | AGENTS.md section 7 Intake | merged into the mode-and-yolo line |
| 192 | section 7 (Intake and authority) | A current explicit captain instruction wins; otherwise the project's registry entry is the captain's standing posture... | AGENTS.md section 7 (Intake and authority) | kept verbatim |
| 193 | section 7 (Intake and authority) | Resolve the project's registered ship-branch prefix the same way, via `bin/fm-project-mode.sh --branch-prefix <projec... | task-intake skill (Delivery details) | moved |
| 194 | section 7 (Intake and authority) | On a `no-mistakes-prod-only` project, classify the task's surface: internal-only tooling, automation, contributor or... | task-intake skill (Delivery details) | moved; section 7's task-intake trigger names the surface classification |
| 195 | section 7 (Intake and authority) | An unregistered project or absent registry resolves to `no-mistakes` with yolo off, and the registration gap goes to... | AGENTS.md section 7 (Intake and authority) | kept verbatim |
| 196 | section 7 (Intake and authority) | Record the resulting mode, `yolo` merge posture, and the one-line reason for any deviation in the backlog item note. | task-intake skill (Delivery details) | moved |
| 198 | section 7 (Intake and authority) | Treat file or subsystem overlap as a risk signal rather than an automatic reason to wait, and dispatch isolated work... | task-intake skill (Concurrency) | moved; section 7's trigger names concurrency |
| 199 | section 7 (Intake and authority) | Serialize only for a true semantic dependency, shared mutable external state, incompatible concurrent migration, or a... | task-intake skill (Concurrency) | moved |
| 200 | section 7 (Intake and authority) | Write the task-specific brief under section 11 before spawning. | AGENTS.md section 11 | kept: write the brief from the scaffold before spawning |
| 201 | section 7 (Intake and authority) | Fill the task subsections according to section 11. | AGENTS.md section 11 + task-intake skill (Write the brief) | moved |
| 205 | section 7 (Dispatch and supervision handoff) | Spawn only through `bin/fm-spawn.sh` after the profile and backend checks in section 4. | AGENTS.md section 7 (Dispatch and supervision handoff) | kept, condensed wording |
| 206 | section 7 (Dispatch and supervision handoff) | The spawn must resolve a genuine isolated task worktree distinct from the primary checkout; a failed isolation assert... | AGENTS.md section 7 (Dispatch and supervision handoff) | kept, condensed wording |
| 207 | section 7 (Dispatch and supervision handoff) | When the configured tasks-axi backlog gate applies, the spawn itself moves the work item to In flight and refuses rat... | AGENTS.md section 10 | merged: fm-spawn.sh/fm-teardown.sh move items and refuse dispatch without an item |
| 208 | section 7 (Dispatch and supervision handoff) | After spawning, confirm the worker is processing the brief and handle any trust dialog through `harness-adapters`. | AGENTS.md section 7 (Dispatch and supervision handoff) | kept verbatim |
| 209 | section 7 (Dispatch and supervision handoff) | A persistent secondmate is recorded in the secondmate registry and runtime state, never as a backlog work item. | AGENTS.md section 10 + secondmate-provisioning | covered: secondmates never appear in the backlog |
| 211 | section 7 (Dispatch and supervision handoff) | Steer a worker with ordinary text through fail-closed `fm-send`: the message becomes a durable record in the task's s... | AGENTS.md section 7 Dispatch | condensed; fm-send.sh header and fm-task-inbox-lib.sh own delivery, re-ring, escalation |
| 212 | section 7 (Dispatch and supervision handoff) | A remote secondmate steer rides the same durable-inbox model through the remote transport; after an unconfirmed deliv... | AGENTS.md section 7 Dispatch | kept: only the printed FM_PENDING_REPLY_EXISTING_CORR resend is safe |
| 213 | section 7 (Dispatch and supervision handoff) | When a steer answers an open keyed decision or blocker, pass `fm-send`'s `--resolve-key` so the answer itself closes... | AGENTS.md section 7 Dispatch | kept: pass --resolve-key when answering an open keyed decision |
| 214 | section 7 (Dispatch and supervision handoff) | `fm-send` is the data plane for text the worker should read; never use its key or text paths for interrupt, exit, or... | AGENTS.md section 7 Dispatch | kept: never use fm-send for lifecycle control |
| 215 | section 7 (Dispatch and supervision handoff) | Drive a worker's lifecycle through `bin/fm-control.sh <task-id> interrupt\|exit\|relaunch`, which owns the per-runtime... | AGENTS.md section 7 Dispatch | kept |
| 216 | section 7 (Dispatch and supervision handoff) | A secondmate's routed reply returns through status or a document pointer, not by firstmate peeking into its chat. | AGENTS.md section 7 Intake | merged: never read a secondmate's chat; replies return via status or a referenced document |
| 217 | section 7 (Dispatch and supervision handoff) | For the parent-owned correlation, recovery, and escalation contract on marked secondmate requests, see `bin/fm-pendin... | AGENTS.md section 7 Dispatch | kept |
| 218 | section 7 (Dispatch and supervision handoff) | When the captain adds or changes an ask mid-task, append the captain's words without added speaker labels or direct a... | AGENTS.md section 7 (Dispatch and supervision handoff) | kept, condensed wording |
| 219 | section 7 (Dispatch and supervision handoff) | Supervise all live work under section 8. | AGENTS.md section 8 | covered by its first rule (one live cycle whenever work is under way) |
| 223 | section 7 (Selected delivery path and merge authority) | The selected delivery path owns its own rigor. | AGENTS.md section 7 (Selected delivery path and merge authority) | kept, condensed wording |
| 224 | section 7 (Selected delivery path and merge authority) | When no-mistakes is selected, no-mistakes alone owns review, fixes, tests, documentation, push, PR, and CI; otherwise... | AGENTS.md section 7 (Selected delivery path and merge authority) | kept, condensed wording |
| 225 | section 7 (Selected delivery path and merge authority) | Never hold work outside no-mistakes for a manual clean verdict, stack serial manual reviews, or infer authority for o... | AGENTS.md section 7 (Selected delivery path and merge authority) | kept verbatim |
| 226 | section 7 (Selected delivery path and merge authority) | A separate review or audit is allowed only when the captain explicitly requests that deliverable or the authorized ta... | AGENTS.md section 7 Merge | kept, condensed |
| 227 | section 7 (Selected delivery path and merge authority) | If fast-path risk needs more rigor, escalate whether to use no-mistakes instead of inventing a manual gate. | AGENTS.md section 7 (Selected delivery path and merge authority) | kept, condensed wording |
| 228 | section 7 (Selected delivery path and merge authority) | The path's worker, automated gates, and captain approval remain authoritative: | AGENTS.md section 7 Merge | lead-in dropped; the three mode bullets and merge rules remain |
| 230 | section 7 (Selected delivery path and merge authority) | - **no-mistakes** runs the full pipeline through a PR, then waits for the configured merge authority. | AGENTS.md section 7 Merge bullets | condensed into one bullet plus 'Every mode then waits for the configured merge authority' |
| 231 | section 7 (Selected delivery path and merge authority) | - **direct-PR** has the worker push and open a PR without the no-mistakes pipeline, then waits for the configured mer... | AGENTS.md section 7 Merge bullets | condensed (same) |
| 232 | section 7 (Selected delivery path and merge authority) | - **local-only** has the worker stop with a clean ready branch, then waits for the configured merge authority before... | AGENTS.md section 7 Merge bullets | condensed (same) |
| 234 | section 7 (Selected delivery path and merge authority) | Delivery mode and `yolo` are orthogonal. | AGENTS.md section 7 (Selected delivery path and merge authority) | kept |
| 235 | section 7 (Selected delivery path and merge authority) | `yolo` governs merge authority only: with it off, the captain approves every PR merge and every local-only landing; w... | AGENTS.md section 7 (Selected delivery path and merge authority) | kept, condensed wording |
| 236 | section 7 (Selected delivery path and merge authority) | Never merge a red PR, or one with a required check that has not reported, under either setting unless a current expli... | AGENTS.md section 7 (Selected delivery path and merge authority) | kept, condensed wording |
| 237 | section 7 (Selected delivery path and merge authority) | Destructive, irreversible, and security-sensitive merges still escalate. | AGENTS.md section 7 (Selected delivery path and merge authority) | kept verbatim |
| 238 | section 7 (Selected delivery path and merge authority) | Without a current explicit captain instruction that states the concrete merge, the green default stands, and standing... | AGENTS.md section 7 Merge + hard rule 2 + Captain instruction precedence | merged: standing yolo never authorizes a red merge; precedence section owns overrides |
| 239 | section 7 (Selected delivery path and merge authority) | Load `ask-user-authority` and `validation-supervision` before deciding or answering any ask-user finding; the impleme... | AGENTS.md section 7 (Selected delivery path and merge authority) | kept verbatim |
| 240 | section 7 (Selected delivery path and merge authority) | Use `bin/fm-pr-merge.sh` for every task PR merge so merge metadata is recorded and an unproved merge is refused inste... | AGENTS.md section 7 Merge | kept; fm-pr-merge.sh header owns metadata recording and unproved-merge refusal |
| 241 | section 7 (Selected delivery path and merge authority) | After an autonomous merge, give the captain a one-line full-URL or local-main outcome. | AGENTS.md section 7 (Selected delivery path and merge authority) | kept verbatim |
| 245 | section 7 (Validate) | Load `validation-supervision` when a ship starts or already has an active no-mistakes validation run, including a mid... | AGENTS.md section 7 (Validate) | kept verbatim |
| 249 | section 7 (PR ready, landing, and teardown) | Load `ship-landing` when a ship reports a PR or ready branch, when deciding or monitoring landing, and before task cl... | AGENTS.md section 7 (PR ready, landing, and teardown) | kept verbatim |
| 253 | section 7 (Scout outcome and promotion) | Load `scout-completion` when a scout reports completion, presents a visual artifact for iteration, or is being consid... | AGENTS.md section 7 (Scout outcome and promotion) | kept verbatim |
| 257 | section 8 | Fleet supervision is an always-loaded operational contract; `docs/architecture.md`, `docs/turnend-guard.md`, the emit... | AGENTS.md section 8 | framing pointer dropped |
| 259 | section 8 | Whenever work is under way, keep exactly one live supervision cycle using the emitted protocol for this primary harness. | AGENTS.md section 8 | kept, condensed wording |
| 260 | section 8 | Relay may require that same live cycle with no fleet work. | AGENTS.md section 8 | kept, condensed wording |
| 261 | section 8 | Do not substitute another harness's wait shape, use shell `&`, or create a second cycle when a healthy one already ex... | AGENTS.md section 8 | kept |
| 262 | section 8 | For every actionable wake, follow the ordinary-wake continuation in the emitted protocol; use its repair action only... | AGENTS.md section 8 | kept, condensed wording |
| 263 | section 8 | No turn ends blind while work is under way, including turns described as holding or waiting. | AGENTS.md section 8 | kept verbatim |
| 265 | section 8 | - At the start of every wake-handling turn, drain the durable wake queue before peeking, reading beyond the reason li... | AGENTS.md section 8 | kept, condensed wording |
| 266 | section 8 | - Session start is the only exception because its one-shot digest already presented the queue while locked or deliber... | AGENTS.md section 8 wake bullets | merged: 'except session start' |
| 267 | section 8 | - Treat any `OPEN DECISIONS` section from the drain as actionable reconciliation input even when no wake record was q... | AGENTS.md section 8 wake bullets | kept |
| 268 | section 8 | - Treat any `UNREAD STATUS` section as newly surfaced status that must be read this turn; those lines are not re-prin... | AGENTS.md section 8 wake bullets | kept |
| 269 | section 8 | - Treat any `RECORD DIVERGENCE` section as a contradiction between two records of one captain call, never as proof th... | AGENTS.md section 8 wake bullets | kept |
| 270 | section 8 | - After handling all emitted wakes and reconciling the OPEN DECISIONS and UNREAD STATUS sections, run the exact gener... | AGENTS.md section 8 wake bullets | kept |
| 271 | section 8 | - After any supervision-branch acknowledgement succeeds or reports that a sequence is already processed, never acknow... | AGENTS.md section 8 | kept, condensed wording |
| 272 | section 8 | - A status line is a wake event, not current state; use `bin/fm-crew-state.sh` when current state matters, especially... | AGENTS.md section 8 | kept, condensed wording |
| 273 | section 8 | - `bin/fm-classify-lib.sh` owns the distinction between declared `paused:` waits and `blocked:` events needing firstm... | AGENTS.md section 8 wake bullets + task-intake skill | kept as a pointer; fm-brief.sh worker declaration pointer moved to task-intake |
| 275 | section 8 | Handle actionable wakes as follows: | AGENTS.md section 8 | kept verbatim |
| 277 | section 8 | 1. For `signal:`, read the listed event lines first, then reconcile current state only where action depends on it. | AGENTS.md section 8 | kept, condensed wording |
| 278 | section 8 | 2. For `stale:`, inspect the recorded endpoint and load `stuck-crewmate-recovery` for a stopped, looping, confused, o... | AGENTS.md section 8 | kept, condensed wording |
| 279 | section 8 | 3. For `check:`, act on the named poll result, including merges, contribution signals, Relay events, process-to-event... | AGENTS.md section 8 wake list | kept |
| 280 | section 8 | A `check: secondmate <id> auto-relaunched` wake records a recovery that already completed - reconcile the mate's curr... | AGENTS.md section 8 wake list | kept |
| 281 | section 8 | When the note needs a durable answer the submitter can read, publish it with `bin/fm-inbox.sh reply <id>` (the script... | AGENTS.md section 8 wake list | kept |
| 282 | section 8 | A `fresh start due` check names the exact command to run in the background, with no captain message; a `fresh-start s... | AGENTS.md section 8 wake list | kept; the wake text itself names the command, and fm-fresh-start.sh owns both |
| 283 | section 8 | 4. For `heartbeat:`, review the whole fleet from the structured fleet view, reconcile suspicious tasks and PR state,... | AGENTS.md section 8 | kept, condensed wording |
| 285 | section 8 | Load `bearings` on a contributions check wake or when filing work linked to an upstream issue; its contribution-follo... | AGENTS.md section 8 + bearings skill description | kept trigger; contribution-follow-up ownership is in the skill |
| 287 | section 8 | When any wake reports a merged PR for a project cloned in this home, refresh that clone through the guarded fleet-syn... | AGENTS.md section 8 | kept verbatim |
| 288 | section 8 | When Relay-linked work reaches a milestone or terminal state, load `fmx-respond`; before terminal teardown, use its p... | AGENTS.md section 8 + fmx-respond skill description | trigger kept; promised-final versus --final choice owned by fmx-respond |
| 290 | section 8 | A secondmate's idle endpoint is healthy, and parent supervision relies on its routed status rather than treating a qu... | AGENTS.md section 8 | kept, condensed wording |
| 291 | section 8 | Waiting on a healthy supervision cycle is silent; empty polls, elapsed time, and no-change updates are not captain-fa... | AGENTS.md section 8 | kept verbatim |
| 292 | section 8 | Never broadly kill watchers, especially never `pkill -f bin/fm-watch.sh`, because that can kill sibling firstmate homes. | AGENTS.md section 8 | kept |
| 293 | section 8 | A forced repair must use the home-scoped owner path emitted by supervision instructions. | AGENTS.md section 8 | merged into the watcher line |
| 295 | section 8 | Guard warnings do not replace the contract. | AGENTS.md section 8 | kept, condensed wording |
| 296 | section 8 | Queued wakes must be presented before other action and acknowledged only after handling, stale liveness must be repai... | AGENTS.md section 8 | kept: tangle and stale repair; queue order and ack-after-handling are the wake bullets |
| 297 | section 8 | The spawn assertion and generated ship brief must both enforce that project work starts in an isolated disposable wor... | AGENTS.md section 7 Dispatch + section 11 | covered: spawn isolation assertion and every ship brief's isolation assertion |
| 298 | section 8 | Harness-aware turn-end guards are structural backstops, not permission to omit the live cycle. | AGENTS.md section 8 | kept verbatim |
| 302 | section 8 (Away-mode and quiet-mode stub) | Invoke the `/afk` skill when the captain says `/afk`, says they are going afk, `state/.afk-contract` or `state/.afk`... | AGENTS.md section 8 (Away-mode and quiet-mode stub) | kept verbatim |
| 303 | section 8 (Away-mode and quiet-mode stub) | Invoke the `/quiet` skill instead when the captain says `/quiet` or asks for quiet mode, or `state/.afk` already exis... | AGENTS.md section 8 (Away-mode and quiet-mode stub) | kept verbatim |
| 304 | section 8 (Away-mode and quiet-mode stub) | Load `away-quiet-supervision` whenever either mode is invoked, either record exists, or a marked away-supervisor mess... | AGENTS.md section 8 (Away-mode and quiet-mode stub) | kept verbatim |
| 308 | section 8 (Stuck-worker trigger) | For the full `stuck-crewmate-recovery` trigger, including a live worker claiming its no-mistakes pipeline is dead, un... | AGENTS.md section 8 (Stuck-worker trigger) | kept, condensed wording |
| 312 | section 9 | - **Talk in outcomes, not mechanics.** | AGENTS.md section 9 | kept |
| 313 | section 9 | - Every captain-facing message must translate internal state into the project outcome, consequence, and next decision. | AGENTS.md section 9 | kept, condensed wording |
| 314 | section 9 | - On every harness, whenever a turn calls for a captain-facing reply, its **final response message** must stand alone... | AGENTS.md section 9 | condensed |
| 315 | section 9 | - The captain may see only the final message; repeat the essentials there, not the full transcript or anchor. | AGENTS.md section 9 | merged: 'because the captain may see only that message' |
| 316 | section 9 | - This final-message rule is a visibility recap: it may list all outstanding decisions and their URLs, but it does no... | AGENTS.md section 9 | kept: recap never replaces or combines per-decision asks |
| 317 | section 9 | - Protocol regression example: reporting a completed fix and its recorded PR URL mid-turn, then using tools and endin... | AGENTS.md section 9 | kept, condensed wording |
| 318 | section 9 | - Use the captain's nouns: the investigation, the scout, the fix, the PR, the review, the decision, the blocker, the... | AGENTS.md section 9 | kept, condensed wording |
| 319 | section 9 | - Do not expose internal terms such as startup machinery, locks, watchers, polling, crewmates, task ids, briefs, work... | AGENTS.md section 9 | kept, condensed wording |
| 320 | section 9 | - Scout and second mate are accepted Firstmate nautical house vocabulary and do not need translation when they natura... | AGENTS.md section 9 | merged into the captain's-nouns line |
| 321 | section 9 | - When evidence uses an internal label, rewrite it before sending: | AGENTS.md section 9 | kept as the rewrite line |
| 323 | section 9 | - worktree, checkout, primary checkout, or local-main -> local copy, isolated copy, or local branch, only if the loca... | AGENTS.md section 9 rewrite line | condensed |
| 324 | section 9 | - teardown -> cleanup. | AGENTS.md section 9 rewrite line | kept |
| 325 | section 9 | - wake, watcher, heartbeat, stale, signal, or check -> notification, monitoring, waiting too long, or stopped respond... | AGENTS.md section 9 | kept, condensed wording |
| 326 | section 9 | - hold, gate, ask-user, needs-decision, blocked, or paused -> the concrete decision, wait, approval, blocker, or exte... | AGENTS.md section 9 rewrite line | kept |
| 327 | section 9 | - done, failed, fix-review, checks-passed, cancelled, validation step, or pipeline state -> the concrete result, revi... | AGENTS.md section 9 rewrite line | condensed |
| 328 | section 9 | - brief -> instructions. | AGENTS.md section 9 rewrite line | kept |
| 329 | section 9 | - crewmate -> worker, only when naming the helper matters. | AGENTS.md section 9 rewrite line | kept |
| 330 | section 9 | - harness, backend, runtime, or adapter -> worker runtime or tool, only when the tool choice itself blocks work. | AGENTS.md section 9 rewrite line | kept |
| 331 | section 9 | - status file, metadata, state, task id, or raw path -> durable record, local record, or omit it unless the captain n... | AGENTS.md section 9 rewrite line | kept |
| 332 | section 9 | - fail-closed, fails closed, fail loudly, or refuses loudly -> stops safely when something goes wrong, refuses rather... | AGENTS.md section 9 rewrite line + internal-terms list | kept |
| 333 | section 9 | - fail-open, fails open, passive fail-open, or degraded-open -> steps aside and lets work continue when the check can... | AGENTS.md section 9 rewrite line | kept |
| 335 | section 9 | Never relay worker reports, status lines, tool output, validation-state labels, or decision records verbatim into cap... | AGENTS.md section 9 | kept, condensed wording |
| 336 | section 9 | Read them as evidence, then send the plain-English outcome and consequence. | AGENTS.md section 9 | merged into the never-relay-verbatim line |
| 337 | section 9 | Private evidence reports may retain exact identifiers, paths, status lines, validation labels, and internal terms whe... | AGENTS.md section 9 | merged into the never-relay-verbatim line |
| 339 | section 9 | Every escalation must stand alone and remain concise. | AGENTS.md section 9 | kept |
| 340 | section 9 | Lead directly with concrete evidence, then the consequence, options when applicable, and a recommendation. | AGENTS.md section 9 | kept |
| 341 | section 9 | Use the same evidence-first form for objections or clarifying challenges rather than unsupported deference. | AGENTS.md section 9 | kept, condensed wording |
| 343 | section 9 | Reach the captain immediately for: | AGENTS.md section 9 | kept verbatim |
| 345 | section 9 | - Work ready for their review, with the PR's recorded URL. | AGENTS.md section 9 | kept verbatim |
| 346 | section 9 | - Finished investigation findings, relayed as findings rather than only a completion notice. | AGENTS.md section 9 | kept verbatim |
| 347 | section 9 | - Gate findings that `ask-user-authority` escalates. | AGENTS.md section 9 | kept verbatim |
| 348 | section 9 | - A real blocker or failure after the relevant playbook is exhausted. | AGENTS.md section 9 | kept verbatim |
| 349 | section 9 | - Anything destructive, irreversible, or security-sensitive. | AGENTS.md section 9 | kept verbatim |
| 350 | section 9 | - A needed credential or login. | AGENTS.md section 9 | kept verbatim |
| 352 | section 9 | - In a secondmate home, reaching the captain means appending the outcome to the parent channel your charter names; a... | AGENTS.md section 9 | kept, condensed wording |
| 353 | section 9 | - Do not surface automatic fixes, retries, routine progress, or internal supervision mechanics. | AGENTS.md section 9 | kept, condensed wording |
| 354 | section 9 | - Reply exactly `Captain, shipshape.` only for a true no-op that still needs an answer - an idle re-read, an empty he... | AGENTS.md section 9 | kept, condensed wording |
| 355 | section 9 | - For a captain-requested completion, or any wake that needs the captain's review, approval, merge, or design pick, g... | AGENTS.md section 9 | kept |
| 356 | section 9 | - Ask for the captain's word only when the next step requires a review, approval, merge, or design pick. | AGENTS.md section 9 | kept, condensed wording |
| 357 | section 9 | - Batch non-urgent updates into the next natural reply. | AGENTS.md section 9 | kept, condensed wording |
| 358 | section 9 | - Use plain chat for a yes-or-no decision and `lavish-axi` only when several options or a structured report benefit f... | AGENTS.md section 9 | kept, condensed wording |
| 359 | section 9 | - Whenever a PR is mentioned, and for any review or merge ask, include the PR's full `https://...` URL in MAIN's fina... | AGENTS.md section 9 | kept, condensed wording |
| 360 | section 9 | - Mention cost as a courtesy when unusually much work is running, but never block on it. | AGENTS.md section 9 | kept, condensed wording |
| 364 | section 10 | The configured `tasks-axi` backend is the durable queue; the tracked default is `data/backlog.md`. | AGENTS.md section 10 | kept, condensed wording |
| 365 | section 10 | It tracks work items only, never agents; persistent secondmates never appear as backlog items. | AGENTS.md section 10 | kept |
| 366 | section 10 | Work routed to a secondmate is recorded in that secondmate home's own backlog, not the main backlog. | AGENTS.md section 10 | kept, condensed wording |
| 367 | section 10 | A decision is simply a task held for the captain: create the task with `bin/fm-tasks-axi.sh add` when needed, then al... | AGENTS.md section 10 | kept, condensed wording |
| 368 | section 10 | When a main-side thread such as a pending captain decision or relay reminder is worth durable tracking, file it as it... | AGENTS.md section 10 | merged into the captain-hold line |
| 369 | section 10 | Captain calls discovered by investigations or visual reviews follow `captain-hold-lifecycle`, which owns their comple... | AGENTS.md section 10 | kept |
| 370 | section 10 | When the automatic transition gate applies, dispatch and completion move the item themselves - `bin/fm-spawn.sh` and... | AGENTS.md section 10 | kept |
| 371 | section 10 | Re-evaluate queued work after every teardown and heartbeat, dispatching items only when dependencies and time gates h... | AGENTS.md section 10 | kept verbatim |
| 373 | section 10 | `.tasks.toml`, `docs/configuration.md`, and current `tasks-axi --help` own the backlog schema, compatibility, retenti... | AGENTS.md section 10 | kept |
| 374 | section 10 | Use compatible `tasks-axi` when the configured backend selects it, always through `bin/fm-tasks-axi.sh` so the call r... | AGENTS.md section 10 | kept: fm-tasks-axi.sh when configured, manual path otherwise, keep only configured recent Done entries |
| 375 | section 10 | `secondmate-provisioning` and `bin/fm-backlog-handoff.sh` own cross-home handoff safety. | AGENTS.md section 10 + section 6 secondmate-provisioning trigger | kept: fm-backlog-handoff.sh owns handoff; secondmate-provisioning triggers on handing backlog |
| 377 | section 10 | Keep free-form notes free of temporary paths, moving versions, ephemeral identifiers, and copied state that will rot. | AGENTS.md section 10 | kept, condensed wording |
| 378 | section 10 | Inspect the current task note before replacing its considered body, and archive the superseded body when recoverabili... | AGENTS.md section 10 | kept |
| 379 | section 10 | Verify volatile details against their authoritative config, live system, or API before acting, and correct or delete... | AGENTS.md section 10 | kept, condensed wording |
| 380 | section 10 | Preserve durable structured identifiers, dependencies, and completion artifact links, and route reusable knowledge to... | AGENTS.md section 10 | kept |
| 384 | section 11 | `bin/fm-brief.sh` and its help own scaffold syntax, generated variants, status protocol, delivery-mode definitions of... | AGENTS.md section 11 + task-intake skill (Write the brief) | section 11 keeps the scaffold as a safety contract; ownership pointers moved |
| 385 | section 11 | Use its scaffold as the contract, then fill `## Captain's intent` (`{TASK}`) with the captain's own ask and any bound... | task-intake skill (Write the brief) | moved |
| 386 | section 11 | Fill `## Firstmate spec` (`{FIRSTMATE_SPEC}`) with only the build instructions that ask requires, naming what stays o... | task-intake skill (Write the brief) | moved |
| 387 | section 11 | `bin/fm-dod-lib.sh` owns intent authoring without added speaker labels or direct address, its provenance markers, wha... | task-intake skill (Write the brief) | moved |
| 388 | section 11 | Keep additions task-specific rather than repeating lifecycle instructions, and alter generated sections only when the... | task-intake skill (Write the brief) | moved |
| 390 | section 11 | Every ship brief must retain the worktree-isolation assertion and stop if launched in the primary checkout. | AGENTS.md section 11 | kept, condensed wording |
| 391 | section 11 | If a ship task touches firstmate's shared tracked material, explicitly require `firstmate-coding-guidelines` before e... | AGENTS.md section 11 | kept verbatim |
| 392 | section 11 | If a task will drive Herdr lifecycle behavior, scaffold with `--herdr-lab`; if that need appears after an unguarded s... | AGENTS.md section 11 | kept, condensed wording |
| 393 | section 11 | The generated Herdr contract must use a named non-`default` isolated lab and its guarded helper for every lifecycle a... | AGENTS.md section 11 | kept |
| 395 | section 11 | Load `secondmate-provisioning` before creating or using a charter brief and preserve its idle-by-default and marked-r... | AGENTS.md section 11 | kept |
| 396 | section 11 | Status appends are sparse supervisor-actionable events, not routine progress; `bin/fm-classify-lib.sh` owns keyed ope... | task-intake skill (Write the brief) | moved; fm-classify-lib.sh still owns keyed semantics |
| 397 | section 11 | The scaffold is a safety contract, not a suggestion. | AGENTS.md section 11 | kept, condensed wording |
| 401 | section 12 | Firstmate's shared instruction surface reaches running homes only after it lands on the default branch and those home... | AGENTS.md section 12 | kept |
| 402 | section 12 | Only `AGENTS.md`, `bin/`, and `.agents/skills/` are loaded by a running firstmate; public `skills/` is an installer-f... | AGENTS.md section 12 | kept |
| 403 | section 12 | When the captain invokes `/updatefirstmate` or asks to update firstmate, load the `/updatefirstmate` skill. | AGENTS.md section 12 | kept, condensed wording |
| 404 | section 12 | The skill owns the guarded fleet update and restart procedure; it never touches anything under `projects/`. | AGENTS.md section 12 + updatefirstmate skill | kept: never touches projects/; procedure owned by the skill |
| 408 | section 13 | Skill descriptions are the always-loaded trigger index; load each agent-only skill only at its stated trigger. | AGENTS.md section 13 | kept, condensed wording |
| 409 | section 13 | Load `agent-skill-trigger-index` only when auditing or maintaining the complete trigger index. | AGENTS.md section 13 | kept, condensed wording |
| 413 | section 14 | When Relay is enabled, load `fmx-respond` for its activation, authority, mention, follow-up, and public-loop contract. | AGENTS.md section 14 | kept verbatim |
| 417 | Captain instruction precedence | A current, explicit, concrete captain instruction overrides any conflicting standing rule written above. | AGENTS.md Captain instruction precedence | kept verbatim |
| 418 | Captain instruction precedence | The instruction must be specific and recent: it must identify the concrete action, object, or bounded set it governs. | AGENTS.md Captain instruction precedence | kept, condensed wording |
| 419 | Captain instruction precedence | Never infer an override, broaden its scope, apply it by analogy, carry it to another object or action, or convert one... | AGENTS.md Captain instruction precedence | kept, condensed wording |
| 420 | Captain instruction precedence | Ambiguous scope or conflict still requires one concise clarification before action. | AGENTS.md Captain instruction precedence | merged |
| 421 | Captain instruction precedence | Destructive, irreversible, security-sensitive, discard, and merge actions still require the captain to state that con... | AGENTS.md Captain instruction precedence | kept, condensed wording |
| 422 | Captain instruction precedence | Standing `yolo` merge authority is not a substitute for a current explicit captain instruction where an explicit acti... | AGENTS.md Captain instruction precedence | kept, condensed wording |
| 426 | Maintaining this file | Keep this file for knowledge useful to almost every future agent session in this project. | AGENTS.md Maintaining this file | kept verbatim |
| 427 | Maintaining this file | Do not repeat what the codebase already shows; point to the authoritative file, skill, command, or doc. | AGENTS.md Maintaining this file | kept verbatim |
| 428 | Maintaining this file | Prefer rewriting or pruning existing entries over appending new ones. | AGENTS.md Maintaining this file | kept verbatim |
| 429 | Maintaining this file | When updating this file, preserve every safety boundary and keep the always-loaded contract concise. | AGENTS.md Maintaining this file | kept, plus the 32 KiB bound |
