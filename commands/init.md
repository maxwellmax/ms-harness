---
description: Show the status of the init spec chain (.spec/init/*) — present, absent, or stale — and run the next init:* command in the chain. Writes nothing itself; all authoring lives in the invoked init:* commands.
allowed-tools: Read, Bash, Glob, Grep, SlashCommand
---

# ms-harness:init

You are the router for the init spec chain. You inspect the state of the artifacts, report it, and invoke the next command in the chain. You never write or edit any artifact yourself — all authoring lives in the `ms-harness:init:*` commands you invoke.

This file is self-contained at run time. It never `@`-includes another file, because it executes inside the developer's project, where the plugin root is not reachable by an include.

## The chain

| # | Artifact | Produced by | Inputs (stamped on line 3) |
|---|---|---|---|
| 1 | `.spec/init/project-description.md` | `/ms-harness:init:project-description` | — (head of chain, no stamp) |
| 2 | `.spec/init/user-stories.md` | `/ms-harness:init:user-stories` | project-description.md |
| 3 | `.spec/init/database-schema.md` | `/ms-harness:init:database-schema` | project-description.md, user-stories.md |
| 4 | `.spec/init/project-issues.md` | `/ms-harness:init:project-issues` | project-description.md, user-stories.md, database-schema.md |
| — | `.spec/init/design/` | developer (manual) | — |

`.spec/init/design/` is always a **manual artifact**: the developer creates and populates it; no `ms-harness:init:*` command writes there. Its absence is never an error. `/ms-harness:init:project-issues` reads it when present — screen and component work points at design refs inside it.

The fourth artifact is the chain's executable output: it is a vertical-slice issue document in the same format `ISSUES.md` uses, so the execution loop reads it with no adaptation.

## Flow

### 1 — Presence

```bash
for f in project-description user-stories database-schema project-issues; do
  test -f ".spec/init/$f.md" && echo "present: $f.md" || echo "absent: $f.md"
done
test -d .spec/init/design && echo "present: design/" || echo "absent: design/"
```

### 2 — Freshness

Line 3 of each generated downstream artifact records the inputs it was built from (`file@sha256:<12 chars>`). Recompute and compare:

```bash
# prints nothing when the whole chain is fresh; any output = an input changed after that artifact was generated
for doc in user-stories database-schema project-issues; do
  [ -f ".spec/init/$doc.md" ] || continue
  for pair in $(sed -n '3p' ".spec/init/$doc.md" | grep -oE '[a-z0-9.-]+\.md@sha256:[0-9a-f]{12}'); do
    [ "$(sha256sum ".spec/init/${pair%%@*}" | cut -c1-12)" = "${pair##*:}" ] \
      || echo "stale: $doc.md predates current ${pair%%@*}"
  done
done
```

A present file whose line 3 carries no stamp predates the staleness mechanism — freshness unknown, report it as such.

### 3 — Report

Emit one table:

| Artifact | Status |
|---|---|
| `.spec/init/project-description.md` | `present` / `absent` |
| `.spec/init/user-stories.md` | `present` / `absent` / `stale (<input> changed)` / `present (no stamp)` |
| `.spec/init/database-schema.md` | same |
| `.spec/init/project-issues.md` | same |
| `.spec/init/design/` | `present (manual)` / `absent (optional)` |

After the table, quote any `stale:` lines from step 2 verbatim.

### 4 — Next step

Pick exactly one action — first rule that matches wins — and **invoke it via the SlashCommand tool**, always plugin-namespaced as `/ms-harness:init:<name>`. State in one line which command you are invoking and why, then invoke it; the invoked command owns the interview and the artifact from there.

1. **An artifact is absent** → invoke the command of the first absent artifact in chain order (1 → 4). Earlier artifacts must exist before later ones make sense.
2. **An artifact is stale** → re-invoke the command of the first stale artifact in chain order. Re-runs are upsert-safe: the command interviews only about deltas and refreshes the stamp. Note that regenerating it may in turn mark artifacts downstream of it stale — re-check with `/ms-harness:init` afterwards.
3. **All present and fresh** → nothing to invoke; report `Chain complete and fresh — nothing to do.` If any artifact is `present (no stamp)`, add one line: its freshness can't be verified until its command is re-run once.

The four invocations available to this step, and no others:

- `/ms-harness:init:project-description`
- `/ms-harness:init:user-stories`
- `/ms-harness:init:database-schema`
- `/ms-harness:init:project-issues`

If the SlashCommand invocation fails (tool unavailable or command not found), fall back to recommending the command by name — never leave the developer without a next step.

## Rules

- **Writes nothing itself** — never Write or Edit; this command produces no artifact and changes no file. Authoring happens only inside the invoked `ms-harness:init:*` command, and every write of this chain is confined to `.spec/init/`.
- **One hop per run** — invoke at most one `ms-harness:init:*` command; never chain multiple in a single run. The developer re-runs `/ms-harness:init` to advance.
- **Never block, never nag** — staleness is a warning, not an error. The developer can always abort the invoked command's interview.
- **Thin router** — no template or interview content in this file; the `ms-harness:init:*` commands own all of it.
- **No git write command, ever** — nothing that stages, records, stashes, switches, resets, publishes, tags or names a ref. Read-only probes are fine.
