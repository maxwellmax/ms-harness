---
description: Read the project description, user stories, database schema, and any design specs, then cut the whole build into numbered vertical slices — one issue each, with blockers, demo criteria and binary acceptance criteria — at .spec/init/project-issues.md
argument-hint: "[optional focus area or extra context]"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, AskUserQuestion
---

# ms-harness:init:project-issues

**ultrathink.** This is a high-stakes planning task: the document you produce is fed to AI agents that build the whole project from it. Engage your maximum reasoning budget. Do not rush. Precision, completeness, and faithful coverage of every source document matter more than brevity.

You are helping a developer turn the project spec into a **complete, issue-driven build plan**. This document is the fourth artifact of the project spec. It builds on the first three (and any design specs) and becomes the ordered backlog the execution loop consumes.

This file is self-contained at run time. It never `@`-includes another file, because it executes inside the developer's project, where the plugin root is not reachable by an include.

**The unit of work is the issue.** Not a stage of the build, not a layer, not a milestone: one issue is one vertical slice a single agent session can grab, finish and demo on its own. This document is the executable input of the loop — `./scripts/loop.sh` reads it exactly the way it reads a feature's `ISSUES.md`, with no format adaptation whatsoever. That is why the output format below is not a style preference: it is the loop's input contract, and a deviation aborts the loop's preflight before a single token is spent.

Optional focus or extra context from the developer (may be empty):

```
$ARGUMENTS
```

## Your goal

Read the existing spec and produce a single document at **`.spec/init/project-issues.md`** that:

1. Cuts the entire build into **numbered vertical slices**, contiguous from 1, each one an independently grabbable issue.
2. Covers **every** requirement in the project description, user stories, and database schema — nothing implied by the spec is left unsliced.
3. Gives each slice its **blockers** (`- **Blocked by**:`), its **demo criterion** (`- **Demoável por**:`) and a full issue body with binary acceptance criteria.
4. Marks work **already implemented in the codebase** as `[x]`.
5. Orders the work **foundation-first**, expressed as dependencies between slices — never as a stage of a schedule.

## Process

### 1. Read the sources of truth first

Before asking anything, read the inputs in this order:

- **`.spec/init/project-description.md`** — scope, tech stack, core workflows.
- **`.spec/init/user-stories.md`** — the stories, acceptance criteria, priorities.
- **`.spec/init/database-schema.md`** — every table, lookup, pivot, relationship.
- **`.spec/init/design/`** — if this directory exists, it holds the **UI/design specs** (mockups, screen definitions, component references, images). Read it. Every slice that builds a screen or component **must** point at its design reference, and its implementation must be **faithful to the proposed design**. `.spec/init/design/` is always a **manual artifact**: the developer creates and populates it; no `ms-harness:init:*` command writes there. Its absence is never an error.

If any of the first three files is missing, stop and tell the developer to run the missing `/ms-harness:init:*` command first. Match the **language** of the project description for all prose.

Then verify the chain is internally fresh — line 3 of each generated artifact records the inputs it was built from:

```bash
# prints nothing when fresh; any output = an input changed after that artifact was generated
for doc in user-stories database-schema; do
  for pair in $(sed -n '3p' ".spec/init/$doc.md" | grep -oE '[a-z0-9.-]+\.md@sha256:[0-9a-f]{12}'); do
    [ "$(sha256sum ".spec/init/${pair%%@*}" | cut -c1-12)" = "${pair##*:}" ] \
      || echo "stale: $doc.md predates current ${pair%%@*}"
  done
done
```

Any output → warn the developer ("input changed after this artifact was generated — review before proceeding") and suggest re-running the flagged `/ms-harness:init:*` command first. Warn and proceed if the developer chooses; never block. A file without a line-3 stamp predates this mechanism — nothing to verify.

### If the target file already exists (re-run)

Re-running this command must **update** the existing document, never rebuild it from scratch — `.spec` belongs to the developer, and manual edits there are decisions, not noise.

- Read the existing `.spec/init/project-issues.md` **before** interviewing. Every decision recorded in it (slice cuts, ordering, blockers, criteria) is source of truth.
- Interview only about **deltas**: stories or tables added upstream since the last run, new gaps, contradictions. Never re-ask what the document already answers.
- Update via **Edit**, not a full rewrite. **Preserve every existing slice number**: a new slice takes the next number at the end and declares its blockers; never renumber, because the loop's progress record is keyed on the slice number plus the hash of that slice's body, and renumbering silently discards the progress already recorded for the renumbered slices.
- Editing the body of a slice invalidates **that slice's** progress entry on the next run, which is exactly the intent: the work changed, so it runs again. Editing a different slice invalidates nothing.
- Never flip a criterion the developer marked `[x]` back to `[ ]` without explicit confirmation. Codebase re-inspection (step 2) may add new `[x]` marks as usual.
- A slice or section the developer deleted stays deleted — restore it only if the developer explicitly confirms.

Line 3 of the existing file is its **input stamp** (see step 4). Verify it before interviewing:

```bash
# prints nothing when fresh; any output = that input changed after this document was generated
for pair in $(sed -n '3p' .spec/init/project-issues.md | grep -oE '[a-z0-9.-]+\.md@sha256:[0-9a-f]{12}'); do
  [ "$(sha256sum ".spec/init/${pair%%@*}" | cut -c1-12)" = "${pair##*:}" ] \
    || echo "stale: ${pair%%@*} changed after this document was generated"
done
```

Any output → warn the developer ("input changed after this artifact was generated — review before proceeding") and focus the delta interview on what changed in that input. Warn and proceed; never block. A file without a line-3 stamp predates this mechanism — nothing to verify.

### 2. Inspect the codebase to detect what is already done

Scan the project so you can mark completed work. Assume no language and no framework before you look — read the manifests, then the directories they imply: migrations and schema files, models and entities, screens and components, routes, tests, handlers, services.

For each acceptance criterion you write, check whether the code already satisfies it. If it does, mark it `[x]`; otherwise `[ ]`. A slice whose criteria are **all** `[x]` is still a slice: the loop runs it, finds the work already in HEAD, records it done and creates no commit. Never delete a slice because it looks finished.

### 3. Interview to close gaps

Derive as much of the cut as you can directly from the docs, then ask the developer only about gaps that change the **shape, ordering, or sizing** of the slices — do not interrogate on things the docs already answer. Focus on:

- **Slice granularity** — too coarse (more than one demoable behaviour) or too fine (not demoable alone).
- **Dependencies** — which slice truly blocks which; a blocker that is not real serialises the build for nothing.
- **MVP cut line** — which slices are in the first release vs deferred.
- **Ambiguous scope** — flows implied but not fully specified in the stories.
- **Design coverage** — screens with no design reference: build to a sensible default, or wait for design?

Use `AskUserQuestion` for discrete decisions with clear options. Ask real open questions in plain text when the answer is not a menu. Batch related questions; don't drip one at a time. When something stays undecided, mark it as an open question rather than inventing scope.

## Rules for slicing

### Every slice is a vertical tracer bullet

- A slice is a thin but **COMPLETE** path through every layer it needs (schema → API → UI → tests), not a horizontal cut of one layer.
- A completed slice is **demoable or verifiable on its own**. If the only way to check it is "wait for the next one", it is not a slice — merge it. That is what `- **Demoável por**:` records, and it is never empty.
- Single-layer slices are legitimate **only** as `[prefactor]`, `[test]` (test infrastructure), `[obs]` (metric, log, alert) or `[chore]` (CI, config). A single-layer `[slice]` is a mis-cut — merge or re-cut it.
- Size: one demoable behaviour. Bigger than one agent session → split. Smaller than a demoable behaviour → merge.
- Titles carry a prefix first: `[prefactor]`, `[slice]`, `[test]`, `[obs]`, `[chore]`, `[perf]`, `[tech-debt]`, `[bug]`. The prefix is not decoration — the consuming implementation skill reads it to pick the TDD variant, so it must match what the slice actually is.

### Foundation first, expressed as dependencies

Foundation work comes first because the slices that need it **declare it as a blocker**, not because it sits earlier in a schedule. The loop resolves the order from `- **Blocked by**:` alone.

1. **Data foundation** — the migrations and lookup seeders the schema requires, as one or more `[prefactor]` slices.
2. **Model foundation** — the models/entities, **relationship-complete up front** (every association, cast, fillable, soft delete). Do not defer relationships into later feature slices.
3. **UI foundation** — the base design-system components, layout and shared components the design specs reference, as a `[prefactor]` or `[chore]` slice.

Only after those exist do the feature slices land, each one declaring the foundation slices it depends on.

### The dependency field is a contract

- `- **Blocked by**:` accepts exactly `nenhum`, or a comma-separated list of `Slice <N>` and/or `#<n>` items. Anything else aborts the loop's preflight quoting the offending line.
- The graph must be **acyclic** and **transitively minimal**: never list a blocker that another listed blocker already implies. The mechanical way to guarantee acyclicity here is to only ever block on a **lower-numbered** slice; the self-check in step 5 enforces exactly that.
- `- **Blocked by**:` is the **only** parsed source of the dependency graph. The `## Bloqueado por` heading inside an issue body is prose for the developer and for the implementation skill, and is never parsed; a divergence between the two is not a format error, but write them consistently anyway.
- A `#<n>` item that matches no slice of this document is an **external blocker**: the loop reports that slice as `blocked-external`, never executes it, and the run still exits 0. Use it only for work genuinely outside this document.

### Traceability

Keep every slice traceable to a user story (`US-x.y`), a schema table, a core workflow, or a design artifact. No invented scope. Every story and every table must land in at least one slice — that is what step 5's coverage loops enforce.

### 4. Write the document

Write to `.spec/init/project-issues.md` (create the `.spec/init/` directories if missing). Use **exactly** this structure — it is the loop's input contract, not a suggestion:

````markdown
# Issues: <project-slug>

<!-- inputs: project-description.md@sha256:<first 12 chars> user-stories.md@sha256:<first 12 chars> database-schema.md@sha256:<first 12 chars> -->

<1–2 paragraphs: the build strategy at a glance — foundation slices first, then the feature slices that depend on them. Note the slice count and the MVP cut line.>

- **Épico**: `não aplicável`
- **Fatias**: <n>
- **Mapa de histórias**: US-1.1 → Slice 1 · US-1.2 → Slice 2 · US-2.1 → Slice 3
- **Já implementado**: Slice 1 · Slice 2   (or `nenhuma`)
- **Publicado em**: `não publicado`

---

## Slice 1: [prefactor] <título da fatia>

- **Issue**: `não publicada`
- **Tasks**: US-1.1, US-1.2
- **Cobre**: tabelas `users`, `statuses` · workflow 1
- **Blocked by**: nenhum
- **Demoável por**: <how this slice alone is verified — a command to run, a screen to open, a query to inspect>

### Corpo

## Contexto

- `.spec/init/project-description.md` — escopo e stack
- `.spec/init/user-stories.md` — histórias cobertas: US-1.1, US-1.2
- `.spec/init/database-schema.md` — tabelas cobertas: `users`, `statuses`
- `.spec/init/design/<arquivo>` — referência de design *(apenas para fatias de tela ou componente)*

## O que construir

<Descrição do comportamento ponta a ponta desta fatia, em 3–8 linhas. O que o usuário ou o sistema passa a poder fazer, não a lista de camadas. Quando parte já existe no código, diga o que já existe e o que falta.>

## Critérios de aceite

- [ ] <critério binário, verificável contra o código>
- [x] <critério já satisfeito pelo código existente>

## Bloqueado por

Nenhum — pode começar imediatamente.

---

## Slice 2: [slice] <título da fatia>

- **Issue**: `não publicada`
- **Tasks**: US-2.1
- **Cobre**: tabela `projects` · workflow 2
- **Blocked by**: Slice 1
- **Demoável por**: <how this slice alone is verified>

### Corpo

## Contexto

- `.spec/init/user-stories.md` — histórias cobertas: US-2.1

## O que construir

<...>

## Critérios de aceite

- [ ] <critério binário>

## Bloqueado por

- Slice 1 — <título da fatia bloqueante>

---

## Open Questions

<Only if gaps remain — bullets of undecided scope or ordering. Otherwise omit this section, along with the `---` above it.>
````

Rules for the document:

- **First line** is `# Issues: <project-slug>`, the slug being the project name in kebab-case.
- **Line 3** is the machine-owned **input stamp**: `<!-- inputs: project-description.md@sha256:<12 chars> user-stories.md@sha256:<12 chars> database-schema.md@sha256:<12 chars> -->`, each checksum being `sha256sum <file> | cut -c1-12` over the files as read in step 1. Refresh it on **every** run, including re-run Edits — the chain status uses it to detect drift. Never preserve a stale stamp as a "developer edit".
- Slice headings are exactly `## Slice <N>: [<prefixo>] <título>` — one space after `##`, a colon after the number, numbering **contiguous from 1**. A heading that deviates aborts the loop's preflight.
- The five slice fields come **before** `### Corpo`, in this order: `- **Issue**:`, `- **Tasks**:`, `- **Cobre**:`, `- **Blocked by**:`, `- **Demoável por**:`.
- `- **Issue**:` stays `não publicada` here. This chain never publishes to a tracker; a real `#<n>` only ever appears if the developer publishes the slices later.
- Inside `### Corpo`, the issue body uses **level-2 headings in PT-BR**, in this order: `## Issue pai` (omitted entirely when there is none), `## Contexto`, `## O que construir`, `## Critérios de aceite`, `## Bloqueado por`. Those exact strings, with those accents, at that level — the implementation skill and the verifier both look for them literally.
- The level-2 headings of an issue body are **not** slice boundaries; the loop knows the difference. But a `---` thematic break followed by a level-2 heading **does** close the slice. So use `---` only immediately before the next `## Slice <N>:` heading, and before `## Open Questions` at the very end.
- Every slice carries at least one `- [ ]` or `- [x]` checkbox under `## Critérios de aceite`. A slice with no checkbox gives the verifier nothing to judge and silently loses a gate.
- Acceptance criteria are **binary and checkable against the code** — a state, a limit, a failure path, a command whose output can be read. Never vague intent: an independent verifier judges each checkbox one by one with `file:line` evidence or the real output of a command.
- Cover **everything** in the description, stories, and schema. Completeness beats brevity.

### 5. Self-checks (run until green)

After writing, run these checks. Any failure → fix the document via Edit and re-run until all pass. Never report completion with a failing check.

```bash
F=.spec/init/project-issues.md
test -f "$F"
head -1 "$F" | grep -qE '^# Issues: '
# line 3 input stamp present and fresh
[ "$(sed -n '3p' "$F")" = "<!-- inputs: project-description.md@sha256:$(sha256sum .spec/init/project-description.md | cut -c1-12) user-stories.md@sha256:$(sha256sum .spec/init/user-stories.md | cut -c1-12) database-schema.md@sha256:$(sha256sum .spec/init/database-schema.md | cut -c1-12) -->" ]

# the loop's input contract, asserted field by field
SLICES=$(grep -cE '^## Slice [0-9]+: ' "$F"); [ "$SLICES" -ge 1 ]
[ "$SLICES" -eq "$(grep -c '^- \*\*Issue\*\*:' "$F")" ]
[ "$SLICES" -eq "$(grep -c '^- \*\*Tasks\*\*:' "$F")" ]
[ "$SLICES" -eq "$(grep -c '^- \*\*Cobre\*\*:' "$F")" ]
[ "$SLICES" -eq "$(grep -c '^- \*\*Blocked by\*\*:' "$F")" ]
[ "$SLICES" -eq "$(grep -c '^- \*\*Demoável por\*\*:' "$F")" ]
[ "$SLICES" -eq "$(grep -c '^### Corpo$' "$F")" ]
[ "$SLICES" -eq "$(grep -c '^## Critérios de aceite$' "$F")" ]
[ "$SLICES" -eq "$(sed -n 's/^- \*\*Fatias\*\*: *//p' "$F")" ]

# slice heading format — a deviation aborts the loop's preflight (must print nothing)
grep -E '^##[[:space:]]+Slice' "$F" | grep -vE '^## Slice [0-9]+: .' || true

# numbering contiguous from 1
diff <(grep -oE '^## Slice [0-9]+' "$F" | grep -oE '[0-9]+$') <(seq 1 "$SLICES")

# every `- **Blocked by**:` inside the grammar (must print nothing)
grep '^- \*\*Blocked by\*\*:' "$F" | sed 's/^- \*\*Blocked by\*\*:[[:space:]]*//' \
  | grep -vE '^(nenhum|(Slice [0-9]+|#[0-9]+)([[:space:]]*,[[:space:]]*(Slice [0-9]+|#[0-9]+))*)$' || true

# acyclic by construction: a blocker slice number is always lower (must print nothing)
awk -F': ' '
  /^## Slice [0-9]+: / { split($0, h, " "); cur = h[3]; sub(/:$/, "", cur) }
  /^- \*\*Blocked by\*\*:/ {
    n = split($2, items, /[[:space:]]*,[[:space:]]*/)
    for (i = 1; i <= n; i++)
      if (items[i] ~ /^Slice [0-9]+$/) {
        split(items[i], b, " ")
        if (b[2] + 0 >= cur + 0) print "forward or self blocker: Slice " cur " blocked by " items[i]
      }
  }
' "$F"

# every acceptance criterion is a checkbox
[ "$(grep -cE '^- \[[ xX]\] ' "$F")" -ge "$SLICES" ]

# coverage: every story ID in the user-stories appendix lands in >=1 slice
# (loop must print nothing; the ([^0-9]|$) guard keeps US-1.1 from matching US-1.10)
for id in $(grep -oE '^\| US-[0-9]+\.[0-9]+ ' .spec/init/user-stories.md | grep -oE 'US-[0-9]+\.[0-9]+' | sort -u); do
  grep -qE "${id//./\\.}([^0-9]|$)" "$F" || echo "story not sliced: $id"
done

# coverage: every table declared in the schema lands in >=1 slice (loop must print nothing)
for t in $(grep -E '^Table [a-z0-9_]+ \{' .spec/init/database-schema.md | awk '{print $2}' | sort -u); do
  grep -qw "$t" "$F" || echo "table not covered: $t"
done
```

The two coverage loops are the enforcement of "cover everything": a story or a schema table mentioned nowhere in the document means work was left unplanned. Fix by adding the missing slices (or asking the developer) — never by deleting the story or the table from the upstream docs to silence the check.

### 6. Close out

After writing, report:

- The path written.
- Slice count, how many are unblocked (`- **Blocked by**: nenhum`), and how many have every criterion already `[x]`.
- Coverage: confirm every story ID and every schema table passed the mechanical coverage loops (green), or list what was added to close the gaps.
- The MVP cut line (which slice completes the first release).
- Self-checks: all green — list any check that initially failed and how it was fixed (Red → Green).
- The execution handoff, since this document is the loop's input:

  ```
  ./scripts/loop.sh .spec/init/project-issues.md
  ```

- Any open questions still needing the developer's decision.

## Constraints

- Writes go only under `.spec/init/` — the single declared write exception of this harness. Never touch application code.
- **No git write command, ever** — nothing that stages, records, stashes, switches, resets, publishes, tags or names a ref. The developer records history manually.
- **No tracker call** — this document is produced without a single `gh` invocation; publication, if the developer ever wants it, is a separate and optional step.
- Never read `.env` or any equivalent secret store, and never paste a secret, token or connection string into the document.
