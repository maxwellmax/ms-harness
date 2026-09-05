#!/usr/bin/env bash
#
# check-drift.sh — guard against textual drift of the rules and contract
# literals that are duplicated across the harness on purpose.
#
# Nothing here is copy-paste by accident. A plugin command file and a plugin
# agent file must be SELF-CONTAINED at run time (RNF-09): they execute inside
# the developer's project, where the plugin root is not reachable through an
# `@`-include, so a shared rule cannot be factored out into one file and
# referenced. The same holds for the contract literals the loop and the agents
# both have to know. The price of that duplication is silent drift — this
# script makes drift LOUD.
#
# Each anchor below is a sentence, a fragment or a contract literal that must
# appear VERBATIM in every file of its group. Rewording one copy breaks the
# anchor and fails the check, naming the file and the missing anchor.
#
# Four anchor groups:
#
#   (a) SHARED INIT RULES — the interview, language, re-run, staleness and
#       close-out rules across the four `commands/init/*.md` and, for the
#       stamp parser and the design/ contract, `commands/init.md`.
#   (b) CT-07 PROTOCOL — the verifier verdict protocol, written once in
#       `agents/issue-verifier.md` and once in the prompt `scripts/loop.sh`
#       builds for its verifier gate. Two copies of one wire format.
#   (c) CT-01 FIELD LITERALS — `## Slice `, `- **Blocked by**:`,
#       `- **Demoável por**:` and `- **Issue**:`, across the two producers of
#       the issue document (`agents/issuer.md`,
#       `commands/init/project-issues.md`) and its consumer (`scripts/loop.sh`).
#   (d) CT-02 HEADING LITERALS — the PT-BR issue-body headings `## Issue pai`,
#       `## Bloqueado por` and `## Critérios de aceite`, across the agent that
#       writes them and the agent that reads them.
#
# Usage: scripts/check-drift.sh [repo-root]
#        With no argument the repository root is derived from this script's
#        own location. Exit 0 = no drift.

set -u

ROOT=${1:-$(dirname "$0")/..}
cd "$ROOT" || {
  echo "FAIL: cannot enter '$ROOT'." >&2
  exit 1
}

FAIL=0

# check "<anchor>" <file>... — the anchor must appear verbatim in every file
# listed. A file that does not exist counts as missing the anchor.
check() {
  ck_anchor=$1
  shift
  ck_missing=""
  for ck_file in "$@"; do
    if [ ! -f "$ck_file" ]; then
      ck_missing="$ck_missing $ck_file (file not found)"
      continue
    fi
    grep -qF -- "$ck_anchor" "$ck_file" || ck_missing="$ck_missing $ck_file"
  done
  if [ -n "$ck_missing" ]; then
    echo "DRIFT: missing in${ck_missing}:"
    echo "  $ck_anchor"
    FAIL=1
  fi
}

DESC=commands/init/project-description.md
STORIES=commands/init/user-stories.md
SCHEMA=commands/init/database-schema.md
ISSUES=commands/init/project-issues.md
ROUTER=commands/init.md

ISSUER=agents/issuer.md
VERIFIER=agents/issue-verifier.md
LOOP=scripts/loop.sh

# Plain indexed arrays only — the supported hosts include the macOS factory
# bash 3.2, which has no associative array.
ALL4=("$DESC" "$STORIES" "$SCHEMA" "$ISSUES")
DOWN3=("$STORIES" "$SCHEMA" "$ISSUES")

# ---------------------------------------------------------------------------
# (a) Shared init rules
# ---------------------------------------------------------------------------

echo "== (a) shared init rules"

# Interview rules (all four chain commands)
check 'Use `AskUserQuestion` for discrete decisions with clear options' "${ALL4[@]}"
check "Ask real open questions in plain text when the answer is not a menu. Batch related questions; don't drip one at a time." "${ALL4[@]}"
check 'as an open question rather than inventing' "${ALL4[@]}"

# Re-run contract (all four)
check 'Re-running this command must **update** the existing document, never rebuild it from scratch — `.spec` belongs to the developer, and manual edits there are decisions, not noise.' "${ALL4[@]}"
check '**before** interviewing. Every decision recorded in it' "${ALL4[@]}"
check 'Interview only about **deltas**' "${ALL4[@]}"
check 'Never re-ask what the document already answers.' "${ALL4[@]}"
check 'Update via **Edit**, not a full rewrite' "${ALL4[@]}"
check 'stays deleted — restore it only if the developer explicitly confirms.' "${ALL4[@]}"

# Write step and self-check preamble (all four)
check '(create the `.spec/init/` directories if missing)' "${ALL4[@]}"
check 'After writing, run these checks. Any failure → fix the document via Edit and re-run until all pass. Never report completion with a failing check.' "${ALL4[@]}"

# Close-out skeleton (all four)
check '- The path written.' "${ALL4[@]}"
check '- Self-checks: all green — list any check that initially failed and how it was fixed (Red → Green).' "${ALL4[@]}"
check "- Any open questions still needing the developer's decision." "${ALL4[@]}"

# Language rules — head of the chain versus downstream, intentionally different
check "Match the developer's language." "$DESC"
check 'Match the **language** of the project description' "${DOWN3[@]}"

# Staleness stamp mechanism (the three derived artifacts)
check 'Line 3 of the existing file is its **input stamp**' "${DOWN3[@]}"
check 'never block. A file without a line-3 stamp predates this mechanism — nothing to verify.' "${DOWN3[@]}"
check 'input changed after this artifact was generated — review before proceeding' "${DOWN3[@]}"
check 'Refresh it on **every** run, including re-run Edits' "${DOWN3[@]}"

# Stamp parser loop — the three derived artifacts plus the /ms-harness:init router
check '[a-z0-9.-]+\.md@sha256:[0-9a-f]{12}' "${DOWN3[@]}" "$ROUTER"
check 'cut -c1-12)" = "${pair##*:}" ]' "${DOWN3[@]}" "$ROUTER"

# design/ contract — always manual, never generated (consumer plus router)
check '`.spec/init/design/` is always a **manual artifact**: the developer creates and populates it; no `ms-harness:init:*` command writes there. Its absence is never an error.' "$ISSUES" "$ROUTER"

# ---------------------------------------------------------------------------
# (b) CT-07 — the verifier verdict protocol
#
# One wire format with two copies: the agent that must emit it and the loop
# that must parse it. A reworded copy on either side silently turns every
# verdict red (or, worse, green), so every line of the protocol is an anchor.
# ---------------------------------------------------------------------------

echo "== (b) CT-07 verifier protocol"

check 'You are an INDEPENDENT VERIFIER. Do NOT write, edit or create any file. Your' "$VERIFIER" "$LOOP"
check 'only job is to read the real code and say what is done and what is not.' "$VERIFIER" "$LOOP"
check "For EACH checkbox of the issue's \`## Critérios de aceite\` section, in the order" "$VERIFIER" "$LOOP"
check 'they appear, check the criterion against the real code — files, classes, tests,' "$VERIFIER" "$LOOP"
check 'routes, migrations, whatever the criterion demands — and emit EXACTLY ONE line' "$VERIFIER" "$LOOP"
check 'per checkbox, in this format:' "$VERIFIER" "$LOOP"
check 'CRITERION <n>: DONE|INCOMPLETE — <arquivo:linha ou saída real de comando>' "$VERIFIER" "$LOOP"
check '- <n> is the index of the checkbox, starting at 1.' "$VERIFIER" "$LOOP"
check '- One CRITERION line per checkbox, no exception, never grouped.' "$VERIFIER" "$LOOP"
check '- Emit no other text besides the CRITERION lines.' "$VERIFIER" "$LOOP"
check '- The evidence is either `file:line` or the REAL output of a command you ran.' "$VERIFIER" "$LOOP"
check '  "Not verifiable" does not exist: no evidence means the criterion is not met.' "$VERIFIER" "$LOOP"
check '- Missing code, a TODO, a placeholder or a missing test means INCOMPLETE.' "$VERIFIER" "$LOOP"
check '- When in doubt, INCOMPLETE.' "$VERIFIER" "$LOOP"

# ---------------------------------------------------------------------------
# (c) CT-01 — the field literals of the issue document
#
# Two producers (the issuer agent and the fourth init chain command) and one
# consumer (the loop). `- **Blocked by**:` is the single parsed source of the
# dependency graph and `- **Issue**:` is what publication writes back, so a
# renamed field on any of the three sides breaks the contract at run time.
# ---------------------------------------------------------------------------

echo "== (c) CT-01 field literals"

check '## Slice ' "$ISSUER" "$ISSUES" "$LOOP"
check '- **Blocked by**:' "$ISSUER" "$ISSUES" "$LOOP"
check '- **Demoável por**:' "$ISSUER" "$ISSUES" "$LOOP"
check '- **Issue**:' "$ISSUER" "$ISSUES" "$LOOP"

# ---------------------------------------------------------------------------
# (d) CT-02 — the PT-BR issue-body headings
#
# Exact strings, because the consuming skill `issue-tdd` and the verifier both
# look for them literally. The agent that writes the body and the agent that
# judges it must spell them identically.
# ---------------------------------------------------------------------------

echo "== (d) CT-02 heading literals"

check '## Issue pai' "$ISSUER" "$VERIFIER"
check '## Bloqueado por' "$ISSUER" "$VERIFIER"
check '## Critérios de aceite' "$ISSUER" "$VERIFIER"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "OK: every duplicated rule and contract literal is in sync."
else
  echo "FAIL: reword the drifted copy, or update the anchor if the wording changed on purpose."
fi
exit "$FAIL"
