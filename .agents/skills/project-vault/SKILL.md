---
name: project-vault
description: >-
  Agent-only convention for project knowledge vaults: tracked, file-cited `_vaults/<name>/wiki/` notes in the project's own repository and local-only `_vaults/<name>/raw/` working notes.
  Load before reading, creating, compiling, or updating a project's vault, and before deciding whether a project fact belongs in a project's vault or in a firstmate home's own notes.
user-invocable: false
metadata:
  internal: true
---

# project-vault

This skill is the single owner of the project-vault convention.
Ship and scout briefs point workers here, and the `stow` skill routes project facts here.

## Two kinds of knowledge

- **Agent knowledge** lives in the agent's own home and never in any repository: captain preferences, fleet and tool behaviour on this machine, and each home's `data/project-map.md`, which holds only a pointer to each project's vault index plus agent-only facts about working that project from this machine.
- **Project knowledge** - how a project is built, where its behaviour is decided, its domain, flows, patterns, and sharp edges - lives in that project's repository as a vault.

The firstmate repository itself is outside this convention: it keeps its knowledge in `AGENTS.md`, its skills, and `docs/` as it does today, and gets no vault.
A project's own vault rules and checks win whenever they exist, such as a wiki-sync skill, a `check:wiki` gate, or a taxonomy its root index already declares; this skill fills only what the project leaves unstated.

## Layout

- A monorepo keeps one vault per app, named for the app: `_vaults/<app>/`; add no workspace-level vault unless the project asks for one.
- A single-app repository keeps one vault named for the project: `_vaults/<project>/`.
- `_vaults/<name>/wiki/` is the only tracked subtree: compiled, file-cited knowledge.
- `_vaults/<name>/raw/` holds unstructured working notes - investigation notes, scratch, screenshots - that are git-ignored and live only locally, as does anything else in the vault outside `wiki/`.

The project's root `.gitignore` tracks only `wiki/`, one block per vault.
Git cannot re-include a path whose parent directory is excluded, so each level is opened and then re-narrowed:

```gitignore
# <name> knowledge vault: track only the compiled wiki subtree.
_vaults/*
!_vaults/<name>
_vaults/<name>/*
!_vaults/<name>/wiki
```

Write `_vaults/*` once; each further vault adds only its three lines.

A fork carries its vault on our side only: the vault ships only in PRs to our own fork.
A PR that targets another owner's upstream repository never includes `_vaults/` content or the vault `.gitignore` block, so its task skips vault writes; local raw notes are still allowed.

## The root index

`_vaults/<name>/wiki/index.md` is the vault's tracked entry point and constitution, read first by every session.
It carries, in the project's own words:

- frontmatter with `title`, `description`, and `date`;
- what the app is and where its source lives;
- the operating mode below;
- the authority order below, naming the project's concrete source paths;
- a taxonomy table of the vault's folders, each linking to its folder `index.md`;
- the note conventions: frontmatter, links, citations, and `UNVERIFIED` marking.

The model is the UIUX workspace's `_vaults/adc/wiki/index.md` in `Strongtie-COE/et-sstvn.org-uiux-workspace`; copy its mechanism, never its app-specific content.

## Operating mode

Wiki notes are compiled just in time, never preemptively: when a task needs a piece of knowledge, the worker reads the relevant raw notes and the live code, then writes one focused, file-cited note that answers it.
Cross-link related notes; a link to a note not yet written marks a gap for later.
Update an existing note rather than writing a parallel one, and mark the change `Updated YYYY-MM-DD` instead of silently overwriting.
Wiki notes never link into `raw/`, because raw notes are not tracked.

**Every note is registered.**
Every wiki folder keeps an `index.md`, and every new note adds its one-line entry to its folder index in the same change; an unlisted note is write-only memory that no session can route to.

## Authority order

When sources disagree, live code wins, then the in-vault reference material, then the wiki's summary notes, then session memory.
A summary note holds prose knowledge and pointers: volatile detail such as exact types, routes, or values lives by pointer to the source file or the in-vault reference, never copied where it will drift.

## Citations and UNVERIFIED

Every claim cites the file and line it rests on as `path:line`.
Make no guess: a fact not verified in code or reference is marked `UNVERIFIED`, and its open question goes into a raw investigation note.

## When a worker writes

- **The vault exists:** read the app's `wiki/index.md` before scanning the code and follow its routing.
- **The project has no vault for the app:** when work actually starts on it, compile the vault inside that task's own PR from the scan the worker has to do anyway to understand the repository: the `.gitignore` block, the root index, and the notes that scan established, each cited and registered.
  The scan stays the one the task needed; it never widens into a survey.
- **Otherwise:** add or update a wiki note only for what the task taught, inside that task's own PR.
  There are no separate documentation sweeps, and a task that taught nothing writes no note.
- **The PR targets another owner's upstream repository:** write no vault content and no vault `.gitignore` block in it, as the fork rule above says; keep only local raw notes.
- **A scout** opens no PR, so it compiles no wiki note: it reports what the vault lacked or had wrong as proposed notes with their citations, and a later ship task, including a promotion of that scout, compiles them in its PR.

A project's committed `AGENTS.md` at most points to the vault index; it never restates vault knowledge.
`bin/fm-ensure-agents-md.sh` still owns that file's shape and self-governance section.

## Raw notes

Raw notes live only in the home's long-lived clone of the project, at `<home>/projects/<repo>/_vaults/<name>/raw/`, never inside a disposable worker copy, which is discarded at cleanup.
Write each raw note as a new file named `YYYY-MM-DD-<task-id>-<topic>.md`, and never edit another worker's note, so concurrent workers never collide.
Before the first write, confirm the clone ignores the note with `git -C <clone> check-ignore -q <note-path>`.
When it does not yet, because the vault's `.gitignore` block has not landed in the clone, append `/_vaults/*/raw/` to the clone's repository-local exclude file, resolved with `git -C <clone> rev-parse --git-path info/exclude`, so the note never makes the clone dirty for fleet sync.
When the home has no clone of the project, keep no raw notes.

## Moving facts out of a home's notes

A project fact already in a home's `data/project-map.md` or other notes moves into the project's vault only when a task touches it, inside that task's PR, and the map entry then shrinks to the vault pointer.
There is no migration sweep.
