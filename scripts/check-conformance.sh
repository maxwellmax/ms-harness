#!/usr/bin/env bash
#
# check-conformance.sh — the SPEC's acceptance criteria, executable in CI.
#
# One labelled block per acceptance criterion of
# `.spec/features/ms-harness-issue-driven/SPEC.md`. Every criterion that can be
# decided by reading the repository is decided here; the criteria that need a
# live pipeline run are named in their block and explicitly left to the manual
# walkthrough of the README, rather than silently skipped.
#
# Usage: scripts/check-conformance.sh [repo-root]
#        With no argument the repository root is derived from this script's own
#        location. Exit 0 = conformant.
#
# ---------------------------------------------------------------------------
# THE SCANNED SURFACE
# ---------------------------------------------------------------------------
#
# The surface every grep below runs over is the VERSIONED surface of the
# plugin: the tracked files of the repository, which is exactly what an install
# ships. Outside a git work tree the surface falls back to every regular file
# under the root. Untracked scratch — a local driver script, a build log — is
# not part of what ships and is not judged here.
#
# ---------------------------------------------------------------------------
# THE NAMED EXCLUSION SET — this list and nothing else
# ---------------------------------------------------------------------------
#
#   .git/                        version control internals, never shipped
#   .spec/                       the planning artifacts, which quote the
#                                removed coupling because they specify its
#                                removal
#   scripts/check-conformance.sh THIS SCRIPT — it carries every searched
#                                literal as its own rule data, so without
#                                self-exclusion it would fail itself
#   README.md                    root documentation: its prose may name the
#                                removed coupling
#   CHANGELOG.md                 root documentation, same reason
#
# Nothing else is excluded. In particular `scripts/test-loop.sh` is INSIDE the
# surface: a test file that names the coupling it forbids is drift like any
# other, and the suite assembles such literals at run time for that reason.
#
# README.md is excluded from the forbidden-literal greps, and is still READ by
# the AC-01 tail, which asserts that every embedded command is documented in it
# (UI-01). Excluded from being searched for violations is not the same as
# unread.
#
# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------
#
# `jq` is required: the manifest assertions of AC-01 are written in it. That is
# a dependency of this CI check, not of the harness at run time — RNF-05 keeps
# `jq` optional for the plugin itself, and neither `scripts/loop.sh` nor any
# command or agent needs it.
#

set -u

ROOT=${1:-$(dirname "$0")/..}
cd "$ROOT" || {
  echo "FAIL: cannot enter '$ROOT'." >&2
  exit 1
}

FAIL=0
SELF="scripts/check-conformance.sh"

if ! command -v jq > /dev/null 2>&1; then
  echo "FAIL: jq is required by this check (AC-01 manifest assertions)." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

block() { echo; echo "== $1"; }
pass()  { echo "  ok    $1"; }

bad() {
  echo "  FAIL  $1"
  if [ -n "${2:-}" ]; then
    printf '%s\n' "$2" | sed 's|^|          |'
  fi
  FAIL=1
}

# assert_empty <label> <matches>
assert_empty() {
  if [ -n "$2" ]; then
    bad "$1" "$2"
  else
    pass "$1"
  fi
}

# assert_eq <expected> <actual> <label>
assert_eq() {
  if [ "$1" = "$2" ]; then
    pass "$3"
  else
    bad "$3" "expected '$1', got '$2'"
  fi
}

# assert_match <value> <ere> <label>
assert_match() {
  if printf '%s\n' "$1" | grep -qE -- "$2"; then
    pass "$3"
  else
    bad "$3" "'$1' does not match /$2/"
  fi
}

# ---------------------------------------------------------------------------
# The surface, after the named exclusion set
# ---------------------------------------------------------------------------

if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  ALL_FILES=$(git ls-files)
else
  ALL_FILES=$(find . -type f | sed 's|^\./||' | sort)
fi

SURFACE=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    .git/* | .spec/* | "$SELF" | README.md | CHANGELOG.md) continue ;;
  esac
  [ -f "$f" ] || continue
  SURFACE="$SURFACE$f
"
done <<EOF
$ALL_FILES
EOF

SURFACE_COUNT=$(printf '%s' "$SURFACE" | grep -c '' || true)

# scan <ere> — every match on the surface, as `file:line:text`
scan() {
  while IFS= read -r sc_f; do
    [ -n "$sc_f" ] || continue
    grep -nE -- "$1" "$sc_f" 2> /dev/null | sed "s|^|$sc_f:|"
  done <<EOF
$SURFACE
EOF
}

# scan_i <ere> — the same, case-insensitive
scan_i() {
  while IFS= read -r sc_f; do
    [ -n "$sc_f" ] || continue
    grep -niE -- "$1" "$sc_f" 2> /dev/null | sed "s|^|$sc_f:|"
  done <<EOF
$SURFACE
EOF
}

echo "ms-harness conformance — $SURFACE_COUNT files on the surface"
echo "exclusion set: .git/ .spec/ $SELF README.md CHANGELOG.md"

# ---------------------------------------------------------------------------
# AC-01 — packaging and namespace (RF-01, RF-02, RF-03, UI-01)
# ---------------------------------------------------------------------------

block "AC-01 — manifests, namespace, documented command surface"

# RF-01 — plugin.json
if [ -f .claude-plugin/plugin.json ]; then
  pass "plugin.json exists"
  assert_eq "ms-harness" "$(jq -r '.name' .claude-plugin/plugin.json)" "plugin.json name is ms-harness"
  assert_match "$(jq -r '.version' .claude-plugin/plugin.json)" '^[0-9]+\.[0-9]+\.[0-9]+$' "plugin.json version is SemVer"
  # CT-03 — the object carries every declared field
  for field in name version description author license; do
    if [ "$(jq -r "has(\"$field\")" .claude-plugin/plugin.json)" = "true" ]; then
      pass "plugin.json has .$field (CT-03)"
    else
      bad "plugin.json has .$field (CT-03)" "field missing"
    fi
  done
else
  bad "plugin.json exists" ".claude-plugin/plugin.json not found"
fi

# RF-02 — marketplace.json, with no identity inherited from the mirrored harness
if [ -f .claude-plugin/marketplace.json ]; then
  pass "marketplace.json exists"
  assert_eq "ms-harness
maxwell
maxwellgti@hotmail.com" "$(jq -r '.name, .owner.name, .owner.email' .claude-plugin/marketplace.json)" "marketplace.json identity is this harness's own"
  MP_SOURCE=$(jq -r '.plugins[] | select(.name=="ms-harness") | .source' .claude-plugin/marketplace.json)
  assert_eq "1" "$(printf '%s' "$MP_SOURCE" | grep -c '' || true)" "marketplace.json has exactly one ms-harness plugin entry"
  if [ -n "$MP_SOURCE" ]; then
    pass "the ms-harness entry declares a non-empty source"
  else
    bad "the ms-harness entry declares a non-empty source" "source is empty"
  fi
  # CT-04 — every declared field of the marketplace object and of its entries
  for field in name owner metadata plugins; do
    if [ "$(jq -r "has(\"$field\")" .claude-plugin/marketplace.json)" = "true" ]; then
      pass "marketplace.json has .$field (CT-04)"
    else
      bad "marketplace.json has .$field (CT-04)" "field missing"
    fi
  done
  assert_eq "0" "$(jq '[.plugins[] | select((has("name") and has("source") and has("description")) | not)] | length' .claude-plugin/marketplace.json)" "every marketplace entry has name, source and description (CT-04)"
  assert_eq "0" "$(grep -ci 'beer-and-code\|beerandcode' .claude-plugin/marketplace.json || true)" "marketplace.json inherits no identity from the mirrored harness"
else
  bad "marketplace.json exists" ".claude-plugin/marketplace.json not found"
fi

assert_empty "no file on the surface names the mirrored harness's marketplace" "$(scan_i 'beer-and-code|beerandcode')"

# RF-03 — the NEGATIVE NAMESPACE CHECK.
#
# The alternation is built at RUN TIME from the basenames of `agents/*.md` and
# `commands/**/*.md`, so it holds exactly the names this plugin actually ships
# and can never match a foreign name. `AGENTS.md`, `SPEC.md`, `PLAN.md` and
# every other name that is not an embedded agent or command are outside the
# alternation by construction, and the guard below proves it rather than
# asserting it.
#
# Two delegation shapes are rejected:
#   1. a slash command written bare — `/spec` instead of `/ms-harness:spec`;
#      the namespaced form reads `/ms-harness:` before the name, so it cannot
#      match.
#   2. a subagent named bare inside backticks — `issuer` instead of
#      `ms-harness:issuer`; the namespaced form has `ms-harness:` between the
#      backtick and the name, so it cannot match either.
HARNESS_NAMES=$(
  {
    ls agents/*.md 2> /dev/null
    find commands -name '*.md' 2> /dev/null
  } | sed 's|.*/||; s|\.md$||' | sort -u | tr '\n' '|' | sed 's/|$//'
)

if [ -z "$HARNESS_NAMES" ]; then
  bad "the namespace alternation is built from the shipped command and agent names" "no agents/*.md or commands/**/*.md found"
else
  pass "namespace alternation built from $(printf '%s' "$HARNESS_NAMES" | tr '|' '\n' | grep -c '') shipped names"

  NS_SLASH="(^|[^A-Za-z0-9:_.-])/($HARNESS_NAMES)([^A-Za-z0-9_-]|\$)"
  NS_BARE="\`($HARNESS_NAMES)\`"

  # The guard the acceptance criterion asks for: a foreign name must not match.
  NS_GUARD=$(printf 'AGENTS.md\nCLAUDE.md\ndocs/agents/tech-stack.md\n' | grep -E "$NS_SLASH|$NS_BARE" || true)
  assert_empty "the namespace check does not match AGENTS.md or any other foreign name" "$NS_GUARD"

  assert_empty "no slash command is written without the ms-harness: namespace" "$(scan "$NS_SLASH")"
  assert_empty "no subagent is delegated to under a bare name" "$(scan "$NS_BARE")"
fi

# UI-01 tail — every embedded command is documented in the README.
if [ -f README.md ]; then
  UNDOCUMENTED=""
  while IFS= read -r cmd_file; do
    [ -n "$cmd_file" ] || continue
    cmd_name=$(printf '%s' "$cmd_file" | sed 's|^commands/||; s|\.md$||; s|/|:|g')
    grep -qF "/ms-harness:$cmd_name" README.md || UNDOCUMENTED="$UNDOCUMENTED$cmd_file (expected a mention of /ms-harness:$cmd_name)
"
  done <<EOF
$(find commands -name '*.md' 2> /dev/null | sort)
EOF
  assert_empty "every file under commands/** is documented in the README (UI-01)" "$UNDOCUMENTED"
else
  bad "every file under commands/** is documented in the README (UI-01)" "README.md not found"
fi

# ---------------------------------------------------------------------------
# AC-02 — the unit of work is the issue, never a phase (RF-05)
# ---------------------------------------------------------------------------

block "AC-02 — no phase vocabulary anywhere on the surface"

assert_empty "no phase document, phase template or phase vocabulary" "$(scan_i 'PHASES\.md|project-phases|## Phase [0-9]')"

# ---------------------------------------------------------------------------
# AC-03 — no stack coupling embedded, no tool-semantics hook (RF-13, RF-14, RF-15)
# ---------------------------------------------------------------------------

block "AC-03 — no embedded stack coupling, no PreToolUse hook"

assert_empty "the string 'sail' occurs nowhere on the surface, in any case (RF-13)" "$(scan_i 'sail')"
assert_empty "no PreToolUse hook is embedded (RF-14)" "$(scan 'PreToolUse')"

if [ -f hooks/hooks.json ]; then
  if jq -e '.hooks.PreToolUse' hooks/hooks.json > /dev/null 2>&1; then
    bad "hooks/hooks.json declares no PreToolUse handler (RF-14)" "jq found .hooks.PreToolUse"
  else
    pass "hooks/hooks.json declares no PreToolUse handler (RF-14)"
  fi
else
  pass "no hooks/hooks.json at all — RF-14 satisfied by absence"
fi

# ---------------------------------------------------------------------------
# AC-04 — no language, framework or runtime as control flow (RF-17, RF-18)
# ---------------------------------------------------------------------------

block "AC-04 — stack names only as data rows of the fallback table"

# The one permitted home for such a name is a DATA ROW of the fallback table:
# a line of scripts/test-commands.conf whose first character is not `#`. A
# match anywhere else — including the prose of that same file — fails.
STACK_HITS=$(scan_i 'laravel|artisan|vendor/bin|docker compose exec' \
  | grep -vE '^scripts/test-commands\.conf:[0-9]+:[[:space:]]*[^#[:space:]]' || true)
assert_empty "no framework, container command or vendored binary path outside the table's data rows" "$STACK_HITS"

if [ -f scripts/test-commands.conf ]; then
  pass "the fallback table exists"
  assert_match "$(grep -cE '^[^#[:space:]]' scripts/test-commands.conf || true)" '^[1-9][0-9]*$' "the fallback table carries at least one data row"
  assert_match "$(grep -c 'NON-SEMANTIC\|non-semantic' scripts/test-commands.conf || true)" '^[1-9][0-9]*$' "the fallback table documents its order as non-semantic (RF-17)"
else
  bad "the fallback table exists" "scripts/test-commands.conf not found"
fi

# ---------------------------------------------------------------------------
# AC-05 — runs in a bare project (RF-21, RF-22, RF-23)
#
# The behavioural half of this criterion — invoke the pipeline in an empty git
# repository and read `git status --porcelain` afterwards — needs a live engine
# run and is out of static reach; it belongs to the README walkthrough. What IS
# statically decidable is that the bare-project entry point is written down and
# that the missing-architecture status really is propagated to every agent.
# ---------------------------------------------------------------------------

block "AC-05 — bare-project entry point and missing-architecture propagation"

if [ -f commands/spec.md ]; then
  for anchor in 'architecture_reference_status: missing' 'Bootstrap and proceed' 'only after an explicit decision'; do
    if grep -qF -- "$anchor" commands/spec.md; then
      pass "commands/spec.md documents: $anchor"
    else
      bad "commands/spec.md documents: $anchor" "anchor not found"
    fi
  done
else
  bad "commands/spec.md exists" "file not found"
fi

MISSING_STATUS=""
for agent_file in agents/specifier.md agents/clarifier.md agents/planner.md agents/issuer.md; do
  [ -f "$agent_file" ] || {
    MISSING_STATUS="$MISSING_STATUS$agent_file (file not found)
"
    continue
  }
  grep -qF 'architecture_reference_status' "$agent_file" \
    || MISSING_STATUS="$MISSING_STATUS$agent_file
"
done
assert_empty "every pipeline agent receives architecture_reference_status (RF-22)" "$MISSING_STATUS"

# ---------------------------------------------------------------------------
# AC-06 — the PLANNING PIPELINE performs no git write (RF-24, RF-25)
#
# Scoped to `commands/` and `agents/` ON PURPOSE. `scripts/` is deliberately
# NOT covered: the execution loop commits one commit per completed issue, and
# that git write is a requirement (RF-35), not a violation.
# ---------------------------------------------------------------------------

block "AC-06 — no git write instruction under commands/ and agents/"

GIT_WRITE_HITS=""
while IFS= read -r gw_f; do
  [ -n "$gw_f" ] || continue
  case "$gw_f" in
    commands/* | agents/*) ;;
    *) continue ;;
  esac
  gw_hits=$(grep -nE 'git (add|commit|stash|checkout|reset|push|tag|branch)' "$gw_f" 2> /dev/null | sed "s|^|$gw_f:|")
  [ -n "$gw_hits" ] && GIT_WRITE_HITS="$GIT_WRITE_HITS$gw_hits
"
done <<EOF
$SURFACE
EOF
assert_empty "the planning pipeline instructs no git write (RF-25)" "$GIT_WRITE_HITS"

# The complement, stated so the scope is visible rather than inferred: the loop
# is where the git write lives, and it must actually be there.
if [ -f scripts/loop.sh ]; then
  assert_match "$(grep -c 'git commit' scripts/loop.sh || true)" '^[1-9][0-9]*$' "the execution loop does commit — AC-06 does not cover scripts/ (RF-35)"
else
  bad "the execution loop does commit — AC-06 does not cover scripts/ (RF-35)" "scripts/loop.sh not found"
fi

# ---------------------------------------------------------------------------
# AC-07 — the tracker write surface is issue creation and nothing else
#         (RF-26 to RF-29, RF-36, RF-37)
# ---------------------------------------------------------------------------

block "AC-07 — tracker writes limited to issue creation"

assert_empty "no issue is ever closed or reopened (RF-29)" "$(scan 'gh issue (close|reopen)')"

# RF-29's single exception: one edit of an epic created in the same run, to
# fill in its children's numbers. An edit that does not name the epic is a
# violation.
EDIT_HITS=$(scan 'gh issue edit' | grep -viE 'epic|épico' || true)
assert_empty "the only permitted issue edit is the epic fill-in (RF-29)" "$EDIT_HITS"

assert_empty "no label is ever created (RF-37)" "$(scan 'gh label create')"

# RF-36 — the destination is derived at run time, never an embedded constant.
# `gh` takes a repository destination through --repo / -R, or through an
# `api repos/<owner>/<repo>` path; a literal in either position is an embedded
# destination.
assert_empty "no owner/repo literal is used as a publication target (RF-36)" \
  "$(scan '(--repo|[[:space:]]-R)[[:space:]]+["'"'"']?[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+|gh api[[:space:]]+repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+')"

if [ -f agents/issuer.md ]; then
  if grep -qF 'gh repo view' agents/issuer.md; then
    pass "the destination is resolved from gh repo view (RF-36)"
  else
    bad "the destination is resolved from gh repo view (RF-36)" "gh repo view not found in agents/issuer.md"
  fi
  if grep -qF 'ready-for-agent' agents/issuer.md; then
    pass "the triage label default ready-for-agent is written down (RF-36)"
  else
    bad "the triage label default ready-for-agent is written down (RF-36)" "default not found in agents/issuer.md"
  fi
  # RF-27 — `gh` absent or unauthenticated degrades, never fails the run.
  if grep -qF 'gh auth status' agents/issuer.md; then
    pass "the publication step probes gh authentication before writing (RF-27)"
  else
    bad "the publication step probes gh authentication before writing (RF-27)" "gh auth status not found in agents/issuer.md"
  fi
else
  bad "agents/issuer.md exists" "file not found"
fi

if [ -f scripts/loop.sh ]; then
  if grep -qF 'MS_LOOP_LABEL' scripts/loop.sh; then
    pass "the triage label is configurable at run time (RF-36)"
  else
    bad "the triage label is configurable at run time (RF-36)" "MS_LOOP_LABEL not found in scripts/loop.sh"
  fi
else
  bad "scripts/loop.sh exists" "file not found"
fi

# ---------------------------------------------------------------------------

echo
if [ "$FAIL" -eq 0 ]; then
  echo "OK: the repository conforms to AC-01..AC-07."
else
  echo "FAIL: fix the criteria reported above."
fi
exit "$FAIL"
