# ms-harness

An issue-driven, stack-agnostic harness for Claude Code. It plans work as vertical
slices, keeps an AGENTS context tree in sync with the implemented code, walks a
project spec chain, and executes the resulting backlog one issue per fresh session.

The unit of work is the **issue** — never a phase. Every command below produces or
consumes issues, and nothing in the harness is bound to a language, framework,
runtime or package manager.

> **Origin.** ms-harness is an adaptation of the
> [Beer and Code Harness (`bc-harness`)](https://github.com/beerandcodeteam/beer-and-code-harness)
> 0.2.0, MIT-licensed, © Beer and Code. It mirrors that harness's command surface
> and rewrites its unit of work from the phase to the issue — see
> [Delta from the mirrored harness](#delta-from-the-mirrored-harness). Both
> copyright notices are kept in [LICENSE](LICENSE).

## Requirements

| Dependency | Status | If missing |
|---|---|---|
| `bash` + coreutils | required | — |
| `git` | **required** | the loop aborts with a named precondition error; it never degrades |
| the engine CLI (`codex` or `claude`) | required by the loop | the loop cannot run a session |
| `gh` | optional | GitHub publication is skipped with a warning; everything else is unaffected |
| `jq` | optional | nothing in the harness needs it at run time; only `scripts/check-conformance.sh`, a CI check, uses it |

**Supported hosts: Linux and macOS as they ship.** The scripts run on the `bash`
each one comes with, including the macOS factory `bash` 3.2, so they use no
bash-4 construct (no associative array, no `mapfile`/`readarray`, no
`${var,,}`/`${var^^}`) and no GNU-only utility flag. Hashing goes through a
portable helper that accepts either `sha256sum` or `shasum -a 256`.
`scripts/check-shell.sh` audits all of it.

## Installation

Add the marketplace and install the plugin:

```
/plugin marketplace add <owner>/ms-harness
/plugin install ms-harness
```

Both manifests live under `.claude-plugin/` — `marketplace.json` lists the plugin,
`plugin.json` declares it. Installing from a local checkout works the same way by
pointing the marketplace at the checkout path.

All commands are plugin-namespaced: they resolve as `/ms-harness:<name>`.

Installation is configuration-free: after installing, `/ms-harness:spec` runs in a
consumer project without a single pre-existing file having to be created or edited
first. Installing the plugin also changes the semantics of no Claude Code tool —
the harness acts only when an `ms-harness:` command or the loop script is invoked
explicitly. It ships no hook.

## Command surface

The plugin ships exactly these commands. There is no unlisted embedded command.

| Command | What it does | Writes |
|---|---|---|
| `/ms-harness:spec` | Planning pipeline for one feature | `.spec/features/<slug>/` |
| `/ms-harness:context-map` | Generates or refreshes the AGENTS context tree | `AGENTS.md`, `CLAUDE.md`, `docs/agents/*.md` |
| `/ms-harness:init` | Reports the state of the init spec chain and runs its next step | nothing (router) |
| `/ms-harness:init:project-description` | Interviews the developer into a project description | `.spec/init/project-description.md` |
| `/ms-harness:init:user-stories` | Derives testable user stories | `.spec/init/user-stories.md` |
| `/ms-harness:init:database-schema` | Derives a suggested schema in DBML | `.spec/init/database-schema.md` |
| `/ms-harness:init:project-issues` | Cuts the whole build into numbered vertical slices | `.spec/init/project-issues.md` |

### `/ms-harness:spec`

```
/ms-harness:spec <description | path-to-description-file>
```

A thin router over four agents. It normalizes the input, checks preconditions,
and delegates: `ms-harness:specifier` writes `SPEC.md` (GEARS syntax, RIGID and
FLEXIBLE sections), `ms-harness:clarifier` resolves ambiguities against the
developer's answers, `ms-harness:planner` produces `PLAN.md` and any formal
contracts, and `ms-harness:issuer` emits `ISSUES.md` — the vertical-slice issue
document the execution loop consumes — plus one body file per slice under
`.handoff/`.

Invoked in a project with no `.spec/` and no AGENTS tree, the router does not
plan around the gap in silence: it presents the two options — bootstrap `.spec/`
and continue with `architecture_reference_status: missing`, or stop and run the
init chain first — and proceeds only after an explicit decision.

The router never writes application code and never runs a git write command. It
writes only under `.spec/features/<slug>/.handoff/`.

Its closing report lists one line per artifact with `created` / `updated` /
`reused` / `skipped`, the count of unresolved markers, and a handoff line
pointing at `ISSUES.md` and at the loop invocation.

### `/ms-harness:context-map`

```
/ms-harness:context-map [path] [+file] [-file] [--adopt]
```

Keeps the canonical AGENTS context tree in sync with the target repository's
**implemented code**. Ten artifacts: `AGENTS.md`, `CLAUDE.md`, and the eight
`docs/agents/*.md` files (project overview, architecture, tech stack, coding
guidelines, domain rules, API contracts, data model, dependencies).

| Token | Meaning |
|---|---|
| a path | target repo root; omitted, the target is the current working directory |
| `+<id>` | include-only mode — generate only the listed artifact ids |
| `-<id>` | exclude mode — generate all except the listed ids |
| `--adopt` | take ownership of pre-existing hand-written artifacts |

Mixing `+` and `-` is an error. With no filter flag, all ten artifacts are
considered.

The command documents reality, not intent: source code, manifests, CI config and
configs are the only sources of truth, and planning artifacts (`.spec/`) are
never read. It delegates to three agents — `ms-harness:context-map-inspector`
(read-only sweep producing a digest), then `ms-harness:context-map-core` and
`ms-harness:context-map-docs` writing in parallel from that digest.

Every generated file carries an ownership banner on line 3. Runs are idempotent
upserts: content is diffed against the bytes on disk and only changed artifacts
are rewritten, so re-running is safe and updates only what drifted.

### `/ms-harness:init` and the init chain

```
/ms-harness:init
```

A status router over the project spec chain under `.spec/init/`. It reports each
artifact as `present`, `absent` or `stale`, then invokes — via the `SlashCommand`
tool, always as `/ms-harness:init:<name>` — the single next command in the chain.
One hop per execution; it writes nothing itself.

| # | Artifact | Command | Inputs |
|---|---|---|---|
| 1 | `.spec/init/project-description.md` | `/ms-harness:init:project-description` | — |
| 2 | `.spec/init/user-stories.md` | `/ms-harness:init:user-stories` | 1 |
| 3 | `.spec/init/database-schema.md` | `/ms-harness:init:database-schema` | 1, 2 |
| 4 | `.spec/init/project-issues.md` | `/ms-harness:init:project-issues` | 1, 2, 3 |
| — | `.spec/init/design/` | the developer, manually | — |

Freshness is tracked with `file@sha256:<12>` stamps written on line 3 of each
derived artifact: when an input's hash no longer matches the stamp, the artifact
reads `stale` and the chain re-runs the command that owns it. Re-runs are
upsert-safe — each command interviews only about the delta.

`.spec/init/design/` is always manual; no chain command writes there, and its
absence is never an error. `/ms-harness:init:project-issues` reads it when it is
present.

Writes of the whole chain are confined to `.spec/init/`.

### `/ms-harness:init:project-issues`

The fourth artifact is the one the execution loop can consume directly. It is
written in the same issue format as `ISSUES.md`: `## Slice <N>: ` headings,
a `- **Blocked by**:` field carrying the dependency grammar, a
`- **Demoável por**:` field naming how the slice alone is verified, and a full
issue body per slice. Ordering is expressed as declared blockers, never as a
schedule, so the loop's preflight accepts the file with no format adaptation.

## Publishing issues to GitHub (optional)

`ISSUES.md` is produced without a single `gh` call. Publication is a separate,
later and optional step, reachable **only** through a recorded approval
checkpoint: the router presents the numbered slice list with each title, its
`Blocked by` line, the tasks it covers and the requirement ids it covers, and
waits for an explicit approval. Without that record, the run stops at the drafted
document.

When publication does run:

- The destination repository is whatever `gh repo view` prints **for the current
  directory**. There is no embedded `owner/repo` anywhere in the harness.
- Issues are created in topological order of `- **Blocked by**:`, and each real
  number is written back into `ISSUES.md` as `- **Issue**: #<n>` immediately
  after creation, so a run interrupted halfway is resumable and never re-creates
  a slice that already carries a number.
- The triage label defaults to `ready-for-agent` and is configurable.

Degradations, none of which fail the run:

| Situation | Behaviour |
|---|---|
| `gh` not on PATH | warn naming the cause, skip only publication, report the pipeline complete |
| `gh` not authenticated | same, naming authentication as the cause |
| no repository resolvable for the directory | same, naming the unresolvable destination |
| the triage label does not exist in the destination | publish every issue **without a label** and warn naming the missing label; the label is never created |

With publication skipped, `ISSUES.md` stays byte-identical to what the draft
produced and remains a valid input for the loop, which never consults GitHub.

The harness never closes, reopens, relabels or edits an issue it did not create
in the current run. The single exception is one edit of an epic created in that
same run, to fill in its children's numbers.

## Configuring the test command

The **primary and stack-agnostic** source of the suite command is a declarative
config file in the consumer project root:

```
# .ms-harness.conf
test_cmd = make test
```

- File name: **`.ms-harness.conf`**, read from the loop's invocation directory.
- Format: plain `key=value`, one per line. Blanks around `=` are tolerated. A
  line whose first non-blank character is `#` is a comment. Blank lines and
  unknown keys are ignored, so the file may carry other settings.
- Key: **`test_cmd=`**. The value is everything after the first `=`, trimmed; it
  is not a shell expression and is not expanded when read.
- Readable with `sed`/`grep` alone — `jq` is optional in this harness and is
  never required to read it.

`scripts/test-commands.conf` is a **fallback table**, consulted only when nothing
declarative resolved the command. Its rows are `<probe> :: <command>` pairs, and
its **traversal order is documented as non-semantic**: no entry outranks another
by language, framework, runtime, package manager or containerisation, and the
order exists only to make a traversal deterministic. It is never used to break a
tie — when more than one row matches, the loop warns, lists every matched
candidate and disables the suite gate rather than letting the file's order impose
a precedence between stacks. Probing inspects **only the invocation directory**:
no recursive scan, no walk up to a parent.

Language and package-manager names appear in the harness in exactly one place:
the data rows of that table. They are never a branch of control flow.

## Executing the backlog

```
./scripts/loop.sh [options] [.spec/features/<slug>/ISSUES.md]
```

The loop reads the issue document and runs **one issue per fresh engine session**,
with a self-contained prompt, gating each on mechanical checks before committing
it. A session is never reused, not between issues and not between correction
cycles. From start to finish it asks the developer nothing.

### Input resolution

First rule that resolves wins:

1. the positional argument;
2. exactly one `.spec/features/*/ISSUES.md`;
3. the init chain issue artifact, `.spec/init/project-issues.md`.

Two or more candidates tied at the same level abort the run, printing every
candidate found: the loop never asks and never picks one by itself. No candidate
at all aborts naming every location searched.

### Preflight

Before any engine session, and with zero engine invocations on any failure path:

- `git` on PATH, inside a git work tree, and the **work tree clean**;
- at least one `## Slice <N>: <title>` heading, no malformed heading and no
  repeated slice number;
- every `- **Blocked by**:` field inside the grammar
  `nenhum | comma-separated list of "Slice <N>" and/or "#<n>"`;
- that graph acyclic.

Any violation aborts, quoting the offending line, with a non-zero exit code.

### Flags

| Flag | Meaning |
|---|---|
| `--engine codex\|claude` | implementation engine (default: `codex`) |
| `--test-cmd "<cmd>"` | the consumer project's test command, for the suite gate |
| `--max-cycles N` | correction cycles per issue (default: `3`) |
| `--no-verify` | disable the verifier gate (equivalent to `MS_LOOP_VERIFY=off`) |
| `--keep-going` | keep going after an issue fails (default: stop at the first failure) |
| `--only-slice N` | restrict the run to a single slice number |
| `-h`, `--help` | print the script header |

Every flag also accepts the `--flag=value` form.

### Environment variables

| Variable | Meaning |
|---|---|
| `MS_LOOP_TEST_CMD` | test command for the suite gate; `--test-cmd` wins over it |
| `MS_LOOP_VERIFY` | verifier gate: `always` (default), `auto` or `off` |
| `MS_LOOP_MAX_CYCLES` | correction cycles per issue (default: `3`) |
| `MS_LOOP_MAX_LIMIT_WAITS` | consecutive usage-limit waits per issue (default: `20`) |
| `MS_LOOP_VERIFY_MODEL` | model of the verifier session (with the `claude` engine, defaults to `haiku`) |
| `MS_LOOP_LIMIT_WAIT_DEFAULT` | usage-limit wait in seconds when the engine announces no reset time (default: `1800`) |
| `MS_LOOP_LIMIT_BUFFER` | seconds added after an announced reset (default: `60`) |
| `MS_LOOP_LABEL` | triage label used when publishing issues (default: `ready-for-agent`) |

`MS_LOOP_VERIFY=auto` skips the verifier on the first cycle when the session
wrote code and the suite gate is green; `always` runs it every time.

Hitting the engine's usage limit is not a failure: the loop waits for the reset
and re-runs the **same** issue without consuming a correction cycle, up to
`MS_LOOP_MAX_LIMIT_WAITS` consecutive waits.

The loop also **exports**, one value per issue, for the consumer project's own
hooks: `MS_LOOP_ISSUE_NUM`, `MS_LOOP_ISSUE_TITLE`, `MS_LOOP_ISSUE_TOTAL`,
`MS_LOOP_ISSUE_ATTEMPT`, `MS_LOOP_ENGINE` and `MS_LOOP_LABEL`. No secret, token
or connection string is ever exported, written into a prompt or written into a
log, and no `.env` file is ever read.

### Gates

The engine exit code is **never** a verdict of completion, on any path. In order:

1. the session finished at all — a signal about the run, never about the work;
2. the tree signature — did this session write? An issue already implemented in
   `HEAD` correctly produces no write;
3. the **suite gate** — the resolved test command, run by the loop *outside* the
   agent session, its real output captured as the cause fed to the next
   correction cycle;
4. the **verifier gate** — a fresh, read-only session judging the issue's
   `## Critérios de aceite` checkboxes one by one, emitting one
   `CRITERION <n>: DONE|INCOMPLETE — <evidence>` line per checkbox. The verdict is
   red when nothing parses, when the line count differs from the checkbox count
   (anti-gaming: red even when every line says `DONE`), or when any line says
   `INCOMPLETE`.

No test command resolves → loud warning, the suite gate is **disabled**, and the
run continues on the verifier gate alone. The loop never aborts over an
unresolved test command. With both gates off it warns before the first session
that no mechanical validation is active.

### Git preconditions and commits

`git` is a **mandatory** dependency and never degrades. The loop refuses to start
outside a git work tree, and refuses to start with a dirty work tree — it commits
per issue and would otherwise swallow uncommitted paths into that commit.

One commit per completed issue, `feat(issue-<N>): <title>`, created **only after**
the gates went green. A `failed` or `blocked` issue never produces a commit, and
an issue already implemented in `HEAD` completes with no commit at all because
the session correctly wrote nothing.

### State directory

Everything the loop writes lives under the input document's own directory, never
at the consumer project root:

```
.spec/features/<slug>/ISSUES.md   ->  .spec/features/<slug>/.loop/
.spec/init/project-issues.md      ->  .spec/init/.loop/

  <state-dir>/slices/slice-NN.md   one self-contained file per slice
  <state-dir>/manifest.txt         slice-NN.md|<N>|<title>|<hash>|<blocked>
  <state-dir>/progress.tsv         the progress record
  <state-dir>/logs/                one log per engine session
  <state-dir>/prompts/             one prompt per engine session
```

The state directory is neutralised through `.git/info/exclude`, idempotently and
with a single appended line. The consumer project's `.gitignore` is never
touched, the input document is never rewritten, and nothing is written outside
`.spec/`.

`progress.tsv` keys each entry on a **composite key** — the slice number plus the
hash of that slice's body alone. Invalidation is therefore per slice: editing one
slice re-executes exactly that slice. Publication writing `- **Issue**: #<n>` back
into the document invalidates nothing, because that field is excluded from the
hashed body.

### States and exit code

Five states, and only these:

| State | Meaning | Re-run behaviour |
|---|---|---|
| `done` | every active gate green | skipped on a re-run |
| `unverified` | executed and committed with **zero** active gates, so never declared done | always re-executed |
| `failed` | correction cycles exhausted without a green gate | always re-executed |
| `blocked` | transitively downstream of a slice that can no longer complete | always re-executed |
| `blocked-external` | blocked by a `#<n>` that matches no slice of this document | always re-executed |

Readiness is decided from the input document and the progress record alone —
GitHub is never consulted — so the loop behaves identically with `gh` absent from
`PATH`. Blocking propagates **transitively**, with zero engine sessions for any
blocked slice. The default is to stop at the first failure; `--keep-going`
continues into independent branches of the graph.

**Exit code rule: the run exits non-zero if and only if some issue ended `failed`
or some issue ended `unverified`.** `blocked`, `blocked-external` and a skipped
publication never change the exit code.

## End to end, from a bare repository

Starting from an empty directory with no `.spec/` at all:

```bash
mkdir my-project && cd my-project
git init
```

1. **Describe the project.** Run `/ms-harness:init` — it reports every chain
   artifact `absent` and hops into `/ms-harness:init:project-description`, which
   interviews you and writes `.spec/init/project-description.md`. Re-run
   `/ms-harness:init` to walk the chain one artifact at a time through
   `/ms-harness:init:user-stories`, `/ms-harness:init:database-schema` and
   `/ms-harness:init:project-issues`. (Have UI specs? Drop them under
   `.spec/init/design/` first — that directory is always yours, and the fourth
   command reads it.)

   You can skip straight to step 2 instead: `/ms-harness:spec` runs in a bare
   project, tells you exactly what is missing and which command produces it, and
   continues only after you decide.

2. **Plan a feature.**

   ```
   /ms-harness:spec add a public health endpoint returning build metadata
   ```

   The pipeline produces `.spec/features/<slug>/SPEC.md`, `PLAN.md`, `ISSUES.md`
   and one issue body per slice under `.handoff/`, then shows you the numbered
   slice list and stops. Approve it if you want the slices filed on GitHub;
   decline and everything stays local — the loop reads the document either way.

3. **Declare how the project is tested.**

   ```bash
   printf 'test_cmd = make test\n' > .ms-harness.conf
   ```

   Skip this and the loop probes the fallback table; resolve nothing and it warns
   and runs on the verifier gate alone.

4. **Commit the plan**, because the loop requires a clean work tree:

   ```bash
   git add .spec .ms-harness.conf && git commit -m "chore: plan the health endpoint"
   ```

5. **Execute the backlog.**

   ```bash
   ./scripts/loop.sh .spec/features/<slug>/ISSUES.md
   ```

   With a single `ISSUES.md` under `.spec/features/`, the path can be omitted.
   The opening summary names the resolved test command and the rule that resolved
   it, plus any externally blocked issue. Then one fresh session per issue, gated
   and committed.

6. **Read the final report** — issues grouped by state, each line pointing at its
   logs under `.spec/features/<slug>/.loop/logs/`. Re-run the loop to pick up
   exactly where it stopped: `done` issues are skipped, everything else is
   re-executed.

7. **Document what was built.**

   ```
   /ms-harness:context-map
   ```

## Repository sanity checks

For contributors to the harness itself:

```bash
scripts/check-shell.sh        # bash -n, shellcheck when present, bash 3.2 / BSD audit
scripts/check-drift.sh        # the rules and contract literals duplicated on purpose
scripts/check-conformance.sh  # the SPEC's acceptance criteria, one labelled block per AC
scripts/test-loop.sh          # the loop's red/green suite, on mocked engines only
```

`scripts/test-loop.sh` spends no API token and makes no network call: fake engine
binaries go first on `PATH` and every case asserts no real engine was reachable
while it ran.

Command and agent files duplicate their shared rules on purpose — a plugin file
must be self-contained at run time, because it executes inside the developer's
project where the plugin root is not reachable through an `@`-include. The cost
is silent drift, and `check-drift.sh` is what makes drift loud.

## Delta from the mirrored harness

ms-harness mirrors the surface of
[`bc-harness`](https://github.com/beerandcodeteam/beer-and-code-harness) 0.2.0 —
the Beer and Code Harness, MIT, © Beer and Code — and changes three things
that blocked reuse outside that harness's home stack.

**The unit of work is the issue, not the phase.** `bc-harness` plans into a phase
document and its loop feeds one phase per session. Here the planner stops at
`PLAN.md` and the issuer turns it into `ISSUES.md`: independently grabbable
vertical slices, each verifiable on its own, ordered by declared blockers rather
than by a schedule. There is no `PHASES.md`, no phase template and no phase
vocabulary anywhere — the fourth init artifact is `project-issues.md`, not
`project-phases.md`. Because issues form a graph rather than a chain, failure
propagates **transitively** to everything downstream, which a linear phase list
never had to do.

**No Laravel Sail coupling, and no stack coupling at all.** `bc-harness` ships a
`PreToolUse` hook (`hooks/hooks.json` → `sail-guard.sh`) that rewrites Bash
commands when it detects Laravel Sail, and its test-command detection gives Sail
precedence over every other manifest. ms-harness ships **no hooks directory at
all**: installing it changes the semantics of no Claude Code tool. The Sail row
and its precedence are gone from the detection table, and the table itself is
demoted to a fallback behind `.ms-harness.conf` — the project declares its own
test command instead of the harness guessing. No language, framework, runtime or
package manager is named as control flow anywhere; those names survive only as
data rows of `scripts/test-commands.conf`.

**Git writes are split by layer instead of banned outright.** The planning
pipeline (`commands/`, `agents/`) runs no git write command, exactly as in the
mirrored harness. The execution loop is deliberately outside that prohibition: it
names git as a hard precondition and commits once per completed issue. Publishing
to a tracker is likewise narrowed — creation only, destination resolved at run
time from `gh repo view`, never an embedded `owner/repo`.

**The context tree pipeline is invoked as `/ms-harness:context-map`.** The command
file, its three agents and the ownership banner they stamp all carry that name; the
ten artifacts it writes, and the way it writes them, are unchanged.

Kept as they were: the `/ms-harness:spec` pipeline shape, the ten canonical
artifacts and their ownership banner, the init chain with its `sha256` staleness
stamps, one fresh session per unit of work, zero questions during a run, and the
rule that the engine exit code is never a completion verdict.

## License

MIT — see [LICENSE](LICENSE). The file carries two copyright notices: this
harness's, and that of `bc-harness` (© Beer and Code), the MIT-licensed work
these sources are derived from.
