# ms-harness

An issue-driven, stack-agnostic harness for Claude Code. It plans work as vertical
slices, keeps an AGENTS context tree in sync with the implemented code, walks a
project spec chain, and executes the resulting backlog one issue per fresh session.

The unit of work is the **issue** — never a phase. Every command below produces or
consumes issues, and nothing in the harness is bound to a language, framework,
runtime or package manager.

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

## Command surface

The plugin ships exactly these commands. There is no unlisted embedded command.

| Command | What it does | Writes |
|---|---|---|
| `/ms-harness:plan` | Planning pipeline for one feature | `.spec/features/<slug>/` |
| `/ms-harness:ai-context` | Generates or refreshes the AGENTS context tree | `AGENTS.md`, `CLAUDE.md`, `docs/agents/*.md` |
| `/ms-harness:init` | Reports the state of the init spec chain and runs its next step | nothing (router) |
| `/ms-harness:init:project-description` | Interviews the developer into a project description | `.spec/init/project-description.md` |
| `/ms-harness:init:user-stories` | Derives testable user stories | `.spec/init/user-stories.md` |
| `/ms-harness:init:database-schema` | Derives a suggested schema in DBML | `.spec/init/database-schema.md` |
| `/ms-harness:init:project-issues` | Cuts the whole build into numbered vertical slices | `.spec/init/project-issues.md` |

### `/ms-harness:plan`

```
/ms-harness:plan <description | path-to-description-file>
```

A thin router over four agents. It normalizes the input, checks preconditions,
and delegates: `ms-harness:specifier` writes `SPEC.md` (GEARS syntax, RIGID and
FLEXIBLE sections), `ms-harness:clarifier` resolves ambiguities against the
developer's answers, `ms-harness:planner` produces `PLAN.md` and any formal
contracts, and `ms-harness:issuer` emits `ISSUES.md` — the vertical-slice issue
document the execution loop consumes — plus one body file per slice under
`.handoff/`.

Publication of the slices to GitHub is optional and reachable **only** through a
recorded approval checkpoint: the router presents the numbered slice list with
each title, its `Blocked by` line, the tasks it covers and the requirement ids it
covers, and waits for an explicit approval before anything is created in a
tracker. Without that record, the run stops at the drafted document.

The router never writes application code and never runs a git write command. It
writes only under `.spec/features/<slug>/.handoff/`.

Its closing report lists one line per artifact with `created` / `updated` /
`reused` / `skipped`, the count of unresolved markers, and a handoff line
pointing at `ISSUES.md` and at the loop invocation.

### `/ms-harness:ai-context`

```
/ms-harness:ai-context [path] [+file] [-file] [--adopt]
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
never read. It delegates to three agents — `ms-harness:ai-context-inspector`
(read-only sweep producing a digest), then `ms-harness:ai-context-core` and
`ms-harness:ai-context-docs` writing in parallel from that digest.

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

## Executing the backlog

```
./scripts/loop.sh [.spec/features/<slug>/ISSUES.md]
```

The loop reads the issue document and runs one issue per fresh engine session,
gating each on the project's own test suite and on a verifier pass. The suite
command comes primarily from the declarative config file `.ms-harness.conf`
(key `test_cmd=`) in the project root; `scripts/test-commands.conf` is a
fallback table whose row order is documented as non-semantic.

Run `scripts/loop.sh --help` for the full list of flags and environment
variables.

## License

MIT — see [LICENSE](LICENSE).
