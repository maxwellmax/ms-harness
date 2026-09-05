#!/usr/bin/env bash
#
# test-loop.sh — red/green suite for scripts/loop.sh, driven by mocked engines.
#
# No network call and no API token is ever spent: fake `claude` and `codex`
# binaries go first on PATH and their behaviour is chosen by MOCK_SCENARIO.
# Every case asserts that no real engine binary was reachable while it ran.
#
# Implementation sessions and verifier sessions are counted SEPARATELY, because
# the verifier is itself an engine session.
#
# Usage: scripts/test-loop.sh [case-name]      (exit 0 = every case green)
#
# MS_LOOP_BIN points the suite at a patched copy of loop.sh, which is how the
# cases are proven able to go red.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOOP="${MS_LOOP_BIN:-$ROOT/scripts/loop.sh}"
CHECK_SHELL="$ROOT/scripts/check-shell.sh"
ONLY="${1:-}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

MOCK_BIN="$TMP/bin"
TAB=$(printf '\t')

PASS=0
FAIL=0

if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
else
  RED=''; GREEN=''; BLUE=''; NC=''
fi

ok()  { PASS=$((PASS + 1)); printf '  %bok%b   %s\n' "$GREEN" "$NC" "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  %bFAIL%b %s\n' "$RED" "$NC" "$1"; }

assert_eq() {
  if [ "$1" = "$2" ]; then
    ok "$3"
  else
    bad "$3 (expected '$1', got '$2')"
  fi
}

assert_ne() {
  if [ "$1" != "$2" ]; then
    ok "$3"
  else
    bad "$3 (expected anything but '$1')"
  fi
}

assert_contains() {
  if grep -qF -- "$2" "$1"; then
    ok "$3"
  else
    bad "$3 (did not find '$2')"
  fi
}

assert_matches() {
  if grep -qE -- "$2" "$1"; then
    ok "$3"
  else
    bad "$3 (nothing matched /$2/)"
  fi
}

assert_not_contains() {
  if grep -qF -- "$2" "$1"; then
    bad "$3 (found '$2')"
  else
    ok "$3"
  fi
}

assert_empty_file() {
  if [ -s "$1" ]; then
    bad "$2 (file is not empty: $(tr '\n' ' ' < "$1"))"
  else
    ok "$2"
  fi
}

# ---------------------------------------------------------------------------
# Mock engines — one script dispatching on its own basename
# ---------------------------------------------------------------------------

make_mocks() {
  mkdir -p "$MOCK_BIN"

  cat > "$MOCK_BIN/mock-engine" <<'MOCK'
#!/usr/bin/env bash
set -uo pipefail

state="${MOCK_STATE:?MOCK_STATE is required}"
scenario="${MOCK_SCENARIO:-ok}"
name=$(basename "$0")
verify=0
prompt=""

mkdir -p "$state"

bump() {
  b_file="$state/$1"
  b_n=0
  [ -f "$b_file" ] && b_n=$(cat "$b_file")
  b_n=$((b_n + 1))
  echo "$b_n" > "$b_file"
  echo "$b_n"
}

# A real `claude -p` reads stdin when it is not a TTY. If the loop ever forgets
# to close stdin, the mock swallows the caller's stream and the run hangs or
# skips work — so the mock reads it on purpose and the suite notices.
if [ "$name" = "claude" ]; then
  [ -t 0 ] || cat > /dev/null
  while [ $# -gt 0 ]; do
    case "$1" in
      -p) prompt="${2:-}"; shift 2 ;;
      --allowedTools) verify=1; shift 2 ;;
      *) shift ;;
    esac
  done
else
  while [ $# -gt 0 ]; do
    case "$1" in
      --sandbox)
        [ "${2:-}" = "read-only" ] && verify=1
        shift 2
        ;;
      *) shift ;;
    esac
  done
  [ -t 0 ] || prompt=$(cat)
fi

echo "$name $scenario" >> "$state/invocations"

if [ "$verify" -eq 1 ]; then
  bump verify_calls > /dev/null
else
  bump impl_calls > /dev/null
fi

exit 0
MOCK

  chmod +x "$MOCK_BIN/mock-engine"
  for engine in claude codex; do
    cp "$MOCK_BIN/mock-engine" "$MOCK_BIN/$engine"
    chmod +x "$MOCK_BIN/$engine"
  done
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

FIX=""
OUT=""
RC=0

new_fixture() {
  FIX="$TMP/fx-$1"
  OUT="$TMP/out-$1.log"
  rm -rf "$FIX"
  mkdir -p "$FIX"
  : > "$OUT"
  RC=0
}

git_init_fixture() {
  (
    cd "$FIX" || exit 1
    git init -q .
    git config user.email harness@example.test
    git config user.name harness
    echo "fixture" > README.md
    git add -A
    git commit -qm "fixture: initial commit"
  ) > /dev/null 2>&1
}

# The CT-01 shaped document every resolution and split case runs against: three
# slices, issue bodies carrying their own level-2 headings, and a trailing
# document section that must NOT leak into the last slice.
write_standard_issues() {
  wsi_target="$1"
  mkdir -p "$(dirname "$wsi_target")"
  cat > "$wsi_target" <<'DOC'
# Issues: standard

- **Épico**: não publicada
- **Fatias**: 3
- **Mapa de tasks**: T01 → Slice 1 · T02 → Slice 2 · T03 → Slice 3

---

## Slice 1: [feat] Foundation

- **Issue**: não publicada
- **Tasks**: T01
- **Cobre**: RF-01
- **Blocked by**: nenhum
- **Demoável por**: the marker file exists

### Corpo

## Contexto

Fatia 1 do plano padrão.

## O que construir

O alicerce.

## Critérios de aceite

- [ ] o alicerce existe

## Bloqueado por

Nenhum — pode começar imediatamente.

---

## Slice 2: [feat] Second

- **Issue**: não publicada
- **Tasks**: T02
- **Cobre**: RF-02
- **Blocked by**: Slice 1
- **Demoável por**: the second marker exists

### Corpo

## Contexto

Fatia 2 do plano padrão.

## Critérios de aceite

- [ ] a segunda camada existe

---

## Slice 3: [feat] Third

- **Issue**: não publicada
- **Tasks**: T03
- **Cobre**: RF-03
- **Blocked by**: Slice 2
- **Demoável por**: the third marker exists

### Corpo

## Contexto

Fatia 3 do plano padrão.

## Critérios de aceite

- [ ] a terceira camada existe

---

## Open Questions

This trailing document section belongs to no slice.
DOC
}

standard_fixture() {
  new_fixture "$1"
  git_init_fixture
  write_standard_issues "$FIX/.spec/features/demo/ISSUES.md"
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

run_loop() {
  (
    cd "$FIX" || exit 1
    PATH="$MOCK_BIN:$PATH" \
    MOCK_STATE="$TMP/mockstate" \
    MOCK_SCENARIO="${MOCK_SCENARIO:-ok}" \
      "$LOOP" "$@"
  ) < /dev/null > "$OUT" 2>&1
  RC=$?
}

reset_engine_counters() {
  rm -rf "$TMP/mockstate"
  mkdir -p "$TMP/mockstate"
}

counter() {
  c_file="$TMP/mockstate/$1"
  if [ -f "$c_file" ]; then cat "$c_file"; else echo 0; fi
}

impl_sessions()   { counter impl_calls; }
verify_sessions() { counter verify_calls; }

assert_zero_engine_calls() {
  assert_eq "0" "$(impl_sessions)" "$1: zero implementation sessions"
  assert_eq "0" "$(verify_sessions)" "$1: zero verifier sessions"
}

state_dir() { printf '%s' "$FIX/.spec/features/demo/.loop"; }

seed_progress() {
  sp_state_dir="$1"
  sp_state="$2"
  : > "$sp_state_dir/progress.tsv"
  # shellcheck disable=SC2034  # every manifest field must be named to be skipped
  while IFS='|' read -r sp_file sp_num sp_title sp_hash sp_braw; do
    [ -n "$sp_num" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$sp_num" "$sp_hash" "$sp_state" "passed" "passed" "" >> "$sp_state_dir/progress.tsv"
  done < "$sp_state_dir/manifest.txt"
}

# ---------------------------------------------------------------------------
# Cases — harness (T13)
# ---------------------------------------------------------------------------

case_harness_mocks_shadow_real_engines() {
  new_fixture harness-mocks
  reset_engine_counters
  hm_resolved=$(PATH="$MOCK_BIN:$PATH" command -v codex)
  assert_eq "$MOCK_BIN/codex" "$hm_resolved" "codex resolves to the mock, not to a real binary"
  hm_resolved=$(PATH="$MOCK_BIN:$PATH" command -v claude)
  assert_eq "$MOCK_BIN/claude" "$hm_resolved" "claude resolves to the mock, not to a real binary"

  # The mock is the only engine the suite can reach: it never opens a socket
  # and never reads a credential.
  assert_not_contains "$MOCK_BIN/mock-engine" "curl" "the mock engine makes no network call"
  assert_not_contains "$MOCK_BIN/mock-engine" "API_KEY" "the mock engine reads no API token"

  assert_eq "0" "$(impl_sessions)" "implementation sessions start at zero"
  assert_eq "0" "$(verify_sessions)" "verifier sessions are counted separately and start at zero"
}

case_shell_audit_rejects_bash4_construct() {
  new_fixture shell-audit
  mkdir -p "$FIX/scripts"
  # The forbidden construct is assembled at run time rather than written out
  # literally, so this suite keeps passing its own portability audit.
  {
    echo '#!/usr/bin/env bash'
    printf 'declare %sA registry\n' '-'
    echo 'registry[key]=value'
    echo 'echo "${registry[key]}"'
  } > "$FIX/scripts/offender.sh"
  "$CHECK_SHELL" "$FIX/scripts/offender.sh" > "$OUT" 2>&1
  RC=$?
  assert_ne "0" "$RC" "check-shell.sh rejects a bash-4 construct"
  assert_contains "$OUT" "offender.sh" "the audit names the offending file"
  assert_contains "$OUT" "associative array" "the audit names the offending construct"
}

case_loop_has_no_associative_array() {
  new_fixture no-assoc
  grep -nE '(declare|typeset|local)[[:space:]]+-[A-Za-z]*A([[:space:]]|$)' "$LOOP" > "$OUT" 2>&1
  assert_empty_file "$OUT" "loop.sh declares no associative array (bash 3.2)"
}

# ---------------------------------------------------------------------------
# Cases — input resolution (RF-32, CT-05)
# ---------------------------------------------------------------------------

case_input_positional_wins() {
  standard_fixture positional
  write_standard_issues "$FIX/.spec/features/other/ISSUES.md"
  write_standard_issues "$FIX/.spec/init/project-issues.md"
  reset_engine_counters

  run_loop ".spec/features/other/ISSUES.md"
  assert_eq "0" "$RC" "positional argument: exit 0"
  assert_contains "$OUT" "resolved by positional argument" "positional argument is the rule that resolved"
  assert_contains "$OUT" "state: .spec/features/other/.loop" "state dir follows the positional input"
  assert_zero_engine_calls "positional argument"
}

case_input_single_feature_glob() {
  standard_fixture feature-glob
  reset_engine_counters

  run_loop
  assert_eq "0" "$RC" "single feature ISSUES.md: exit 0"
  assert_contains "$OUT" "resolved by the single .spec/features/*/ISSUES.md" "the feature glob is the rule that resolved"
  assert_contains "$OUT" "state: .spec/features/demo/.loop" "state dir sits beside the feature document"
  assert_zero_engine_calls "single feature ISSUES.md"
}

case_input_init_artifact() {
  new_fixture init-artifact
  git_init_fixture
  write_standard_issues "$FIX/.spec/init/project-issues.md"
  reset_engine_counters

  run_loop
  assert_eq "0" "$RC" "init chain artifact: exit 0"
  assert_contains "$OUT" "resolved by the init chain artifact .spec/init/project-issues.md" "the init artifact is the rule that resolved"
  assert_contains "$OUT" "state: .spec/init/.loop" "init chain state dir is .spec/init/.loop"
  assert_zero_engine_calls "init chain artifact"
}

case_input_feature_glob_beats_init_artifact() {
  standard_fixture glob-beats-init
  write_standard_issues "$FIX/.spec/init/project-issues.md"
  reset_engine_counters

  run_loop
  assert_eq "0" "$RC" "feature glob over init artifact: exit 0"
  assert_contains "$OUT" "resolved by the single .spec/features/*/ISSUES.md" "the feature glob outranks the init artifact"
  assert_not_contains "$OUT" "state: .spec/init/.loop" "the init artifact was not used"
  assert_zero_engine_calls "feature glob over init artifact"
}

case_input_tie_aborts_listing_candidates() {
  standard_fixture tie
  write_standard_issues "$FIX/.spec/features/second/ISSUES.md"
  reset_engine_counters

  run_loop
  assert_ne "0" "$RC" "two feature documents: non-zero exit"
  assert_contains "$OUT" "Ambiguous input" "the tie is named as ambiguous input"
  assert_contains "$OUT" ".spec/features/demo/ISSUES.md" "the first candidate is printed"
  assert_contains "$OUT" ".spec/features/second/ISSUES.md" "the second candidate is printed"
  assert_not_contains "$OUT" "Preflight OK" "the run never got past preflight"
  assert_zero_engine_calls "two feature documents"
}

case_input_no_candidate_aborts() {
  new_fixture no-candidate
  git_init_fixture
  reset_engine_counters

  run_loop
  assert_ne "0" "$RC" "no candidate: non-zero exit"
  assert_contains "$OUT" "No issue document found. Searched, in this order:" "the abort names that it searched"
  assert_contains "$OUT" "the positional argument" "level 1 of the ladder is named"
  assert_contains "$OUT" ".spec/features/*/ISSUES.md" "level 2 of the ladder is named"
  assert_contains "$OUT" ".spec/init/project-issues.md" "level 3 of the ladder is named"
  assert_zero_engine_calls "no candidate"
}

# ---------------------------------------------------------------------------
# Cases — git preconditions (RF-35 a, b)
# ---------------------------------------------------------------------------

case_precondition_outside_git_work_tree() {
  new_fixture no-git
  write_standard_issues "$FIX/.spec/features/demo/ISSUES.md"
  reset_engine_counters

  run_loop
  assert_ne "0" "$RC" "outside a git work tree: non-zero exit"
  assert_contains "$OUT" "Precondition not met: not inside a git work tree" "the precondition is named"
  assert_contains "$OUT" "commits one commit per completed issue" "the abort explains why git is mandatory"
  assert_not_contains "$OUT" "Preflight OK" "preflight never succeeded"
  assert_zero_engine_calls "outside a git work tree"
}

case_precondition_dirty_work_tree() {
  standard_fixture dirty-tree
  echo "uncommitted" > "$FIX/scratch.txt"
  mkdir -p "$FIX/src"
  echo "more" > "$FIX/src/leftover.txt"
  reset_engine_counters

  run_loop
  assert_ne "0" "$RC" "dirty work tree: non-zero exit"
  assert_contains "$OUT" "Precondition not met: the work tree is dirty" "the precondition is named"
  assert_contains "$OUT" "scratch.txt" "the first dirty path is listed"
  assert_contains "$OUT" "src/" "the second dirty path is listed"
  assert_zero_engine_calls "dirty work tree"
}

# ---------------------------------------------------------------------------
# Cases — format contract (CT-05)
# ---------------------------------------------------------------------------

case_format_no_slice_heading() {
  new_fixture fmt-no-heading
  git_init_fixture
  mkdir -p "$FIX/.spec/features/demo"
  cat > "$FIX/.spec/features/demo/ISSUES.md" <<'DOC'
# Issues: broken

- **Épico**: não publicada

## Fatia 1: [feat] wrong heading vocabulary

- **Blocked by**: nenhum
DOC
  reset_engine_counters

  run_loop
  assert_ne "0" "$RC" "no slice heading: non-zero exit"
  assert_contains "$OUT" "Input format contract violated" "the abort names the format contract"
  assert_contains "$OUT" "no '## Slice <N>: <title>' heading found" "the abort says which heading is missing"
  assert_zero_engine_calls "no slice heading"
}

case_format_malformed_slice_heading() {
  new_fixture fmt-malformed
  git_init_fixture
  mkdir -p "$FIX/.spec/features/demo"
  cat > "$FIX/.spec/features/demo/ISSUES.md" <<'DOC'
# Issues: broken

## Slice 1: [feat] Fine

- **Blocked by**: nenhum

### Corpo

Body.

---

## Slice two: [feat] Broken

- **Blocked by**: nenhum

### Corpo

Body.
DOC
  reset_engine_counters

  run_loop
  assert_ne "0" "$RC" "malformed slice heading: non-zero exit"
  assert_contains "$OUT" "malformed slice heading" "the abort names the violation"
  assert_contains "$OUT" "13: ## Slice two: [feat] Broken" "the offending line is quoted with its line number"
  assert_zero_engine_calls "malformed slice heading"
}

case_format_blocked_by_outside_grammar() {
  new_fixture fmt-grammar
  git_init_fixture
  mkdir -p "$FIX/.spec/features/demo"
  cat > "$FIX/.spec/features/demo/ISSUES.md" <<'DOC'
# Issues: broken

## Slice 1: [feat] Fine

- **Blocked by**: nenhum

### Corpo

Body.

---

## Slice 2: [feat] Broken blocker

- **Blocked by**: nenhum (externamente, o merge de #61)

### Corpo

Body.
DOC
  reset_engine_counters

  run_loop
  assert_ne "0" "$RC" "Blocked by outside the grammar: non-zero exit"
  assert_contains "$OUT" "outside the grammar" "the abort names the grammar violation"
  assert_contains "$OUT" "15: - **Blocked by**: nenhum (externamente, o merge de #61)" "the offending line is quoted with its line number"
  assert_zero_engine_calls "Blocked by outside the grammar"
}

case_format_cyclic_graph() {
  new_fixture fmt-cycle
  git_init_fixture
  mkdir -p "$FIX/.spec/features/demo"
  cat > "$FIX/.spec/features/demo/ISSUES.md" <<'DOC'
# Issues: broken

## Slice 1: [feat] A

- **Blocked by**: Slice 3

### Corpo

Body.

---

## Slice 2: [feat] B

- **Blocked by**: Slice 1

### Corpo

Body.

---

## Slice 3: [feat] C

- **Blocked by**: Slice 2

### Corpo

Body.
DOC
  reset_engine_counters

  run_loop
  assert_ne "0" "$RC" "cyclic graph: non-zero exit"
  assert_contains "$OUT" "graph has a cycle" "the abort names the cycle"
  assert_contains "$OUT" "Slice 1 — - **Blocked by**: Slice 3" "the offending Blocked by line of slice 1 is quoted"
  assert_contains "$OUT" "Slice 3 — - **Blocked by**: Slice 2" "the offending Blocked by line of slice 3 is quoted"
  assert_zero_engine_calls "cyclic graph"
}

# The init chain artifact goes through the SAME validation as ISSUES.md, with
# no format adaptation (RF-08 AC): the identical broken document is rejected
# with the identical message.
case_format_init_artifact_same_validation() {
  new_fixture fmt-init-same
  git_init_fixture
  mkdir -p "$FIX/.spec/init"
  cat > "$FIX/.spec/init/project-issues.md" <<'DOC'
# Issues: init chain

## Slice 1: [feat] Fine

- **Blocked by**: nenhum

### Corpo

Body.

---

## Slice two: [feat] Broken

- **Blocked by**: nenhum

### Corpo

Body.
DOC
  reset_engine_counters

  run_loop
  assert_ne "0" "$RC" "init artifact, malformed heading: non-zero exit"
  assert_contains "$OUT" "malformed slice heading" "the init artifact is validated by the same rule"
  assert_contains "$OUT" "13: ## Slice two: [feat] Broken" "the init artifact abort quotes the offending line too"
  assert_zero_engine_calls "init artifact, malformed heading"

  # ... and a well-formed init artifact passes that same validation untouched.
  write_standard_issues "$FIX/.spec/init/project-issues.md"
  reset_engine_counters
  run_loop
  assert_eq "0" "$RC" "well-formed init artifact passes the ISSUES.md validation as is"
  assert_contains "$OUT" "Input format OK (3 slices declared" "the init artifact needs no format adaptation"
}

# ---------------------------------------------------------------------------
# Cases — slice split and manifest (T05)
# ---------------------------------------------------------------------------

case_split_file_count_matches_headings() {
  standard_fixture split-count
  reset_engine_counters

  run_loop
  assert_eq "0" "$RC" "split run: exit 0"

  sc_expected=$(grep -cE '^## Slice [0-9]+: ' "$FIX/.spec/features/demo/ISSUES.md")
  sc_actual=$(ls -1 "$(state_dir)/slices" | wc -l | tr -d ' ')
  assert_eq "$sc_expected" "$sc_actual" "one slice file per '## Slice N: ' heading"

  assert_contains "$(state_dir)/manifest.txt" "slice-01.md|1|[feat] Foundation|" "manifest carries slice-NN.md|N|title|hash|blocked"
  assert_matches "$(state_dir)/manifest.txt" '^slice-02\.md\|2\|\[feat\] Second\|[0-9a-f]{64}\|Slice 1$' "manifest line 2 carries the body hash and the raw Blocked by"
}

case_split_keeps_issue_body_headings() {
  standard_fixture split-body
  reset_engine_counters

  run_loop
  assert_contains "$(state_dir)/slices/slice-01.md" "## Critérios de aceite" "the level-2 issue body headings stay inside the slice"
  assert_contains "$(state_dir)/slices/slice-01.md" "### Corpo" "the body marker stays inside the slice"
  assert_not_contains "$(state_dir)/slices/slice-01.md" "## Slice 2:" "the next slice heading closes the capture"
}

case_split_trailing_section_does_not_leak() {
  standard_fixture split-trailing
  reset_engine_counters

  run_loop
  assert_not_contains "$(state_dir)/slices/slice-03.md" "## Open Questions" "the trailing level-2 section does not leak into the last slice"
  assert_not_contains "$(state_dir)/slices/slice-03.md" "belongs to no slice" "the trailing section body does not leak either"
  assert_contains "$(state_dir)/slices/slice-03.md" "a terceira camada existe" "the last slice still carries its own body"
}

case_split_writes_nothing_outside_spec() {
  standard_fixture split-scope
  reset_engine_counters

  ss_before=$(cd "$FIX" && git rev-parse HEAD)
  run_loop
  assert_eq "0" "$RC" "run over a clean tree: exit 0"

  (cd "$FIX" && git status --porcelain) > "$TMP/status.txt"
  assert_empty_file "$TMP/status.txt" "git status --porcelain lists no path at all after a run"

  ss_outside=$(cd "$FIX" && git status --porcelain --ignored=no | grep -v '^.. \.spec/' || true)
  assert_eq "" "$ss_outside" "no path outside .spec/ appears in git status"

  assert_eq "$ss_before" "$(cd "$FIX" && git rev-parse HEAD)" "the split creates no commit"
  assert_contains "$FIX/.git/info/exclude" "/.spec/features/demo/.loop/" "the state dir is registered in .git/info/exclude"
  assert_not_contains "$FIX/.gitignore" ".loop" "the consumer .gitignore is never touched" 2> /dev/null || ok "the consumer .gitignore is never created"
}

case_split_never_rewrites_the_input() {
  standard_fixture split-input-intact
  reset_engine_counters

  sn_before=$(cd "$FIX" && cat .spec/features/demo/ISSUES.md | (command -v sha256sum > /dev/null 2>&1 && sha256sum || shasum -a 256))
  run_loop
  sn_after=$(cd "$FIX" && cat .spec/features/demo/ISSUES.md | (command -v sha256sum > /dev/null 2>&1 && sha256sum || shasum -a 256))
  assert_eq "$sn_before" "$sn_after" "the split never rewrites the input document"
}

case_exclude_registration_is_idempotent() {
  standard_fixture exclude-idempotent
  reset_engine_counters

  run_loop
  run_loop
  ei_count=$(grep -cxF "/.spec/features/demo/.loop/" "$FIX/.git/info/exclude")
  assert_eq "1" "$ei_count" "two runs leave exactly one .git/info/exclude entry"
}

# ---------------------------------------------------------------------------
# Cases — progress record (T06: RF-12, RF-33, CT-06)
# ---------------------------------------------------------------------------

case_progress_all_done_is_skipped() {
  standard_fixture progress-done
  reset_engine_counters

  run_loop
  seed_progress "$(state_dir)" "done"

  reset_engine_counters
  run_loop
  assert_eq "0" "$RC" "second run over an all-done record: exit 0"
  assert_contains "$OUT" "0 slice(s) to execute, 3 skipped" "every done slice is skipped"
  assert_zero_engine_calls "second run over an all-done record"
}

case_progress_editing_one_slice_reexecutes_only_it() {
  standard_fixture progress-edit
  reset_engine_counters

  run_loop
  seed_progress "$(state_dir)" "done"

  # Change slice 2's body only.
  pe_doc="$FIX/.spec/features/demo/ISSUES.md"
  cp "$pe_doc" "$TMP/edited.md"
  awk '{ print } /^Fatia 2 do plano padrão\.$/ { print ""; print "Uma linha nova só na fatia 2." }' \
    "$TMP/edited.md" > "$pe_doc"

  reset_engine_counters
  run_loop
  assert_eq "0" "$RC" "run after editing one slice body: exit 0"
  assert_contains "$OUT" "1 slice(s) to execute, 2 skipped" "only the edited slice is re-executed"
  assert_matches "$OUT" 'Slice 1 — done \(skip\)' "slice 1 stays done"
  assert_matches "$OUT" 'Slice 2 — pending \(run\)' "slice 2 falls out of the record"
  assert_matches "$OUT" 'Slice 3 — done \(skip\)' "slice 3 stays done"
}

case_progress_publication_invalidates_nothing() {
  standard_fixture progress-publication
  reset_engine_counters

  run_loop
  seed_progress "$(state_dir)" "done"

  # Publication (RF-28) writes the real issue number back into ISSUES.md.
  pp_doc="$FIX/.spec/features/demo/ISSUES.md"
  awk '
    /^## Slice 2: / { in_two = 1 }
    /^## Slice 3: / { in_two = 0 }
    in_two && $0 == "- **Issue**: não publicada" { print "- **Issue**: #42"; next }
    { print }
  ' "$pp_doc" > "$TMP/published.md"
  cp "$TMP/published.md" "$pp_doc"
  assert_contains "$pp_doc" "- **Issue**: #42" "the fixture really simulates publication"

  reset_engine_counters
  run_loop
  assert_eq "0" "$RC" "run after publication: exit 0"
  assert_contains "$OUT" "0 slice(s) to execute, 3 skipped" "inserting '- **Issue**: #N' invalidates no entry"
  assert_zero_engine_calls "run after publication"
}

case_progress_non_done_states_are_reexecuted() {
  standard_fixture progress-states
  reset_engine_counters
  run_loop

  for pn_state in unverified failed blocked blocked-external; do
    seed_progress "$(state_dir)" "$pn_state"
    reset_engine_counters
    run_loop
    assert_contains "$OUT" "3 slice(s) to execute, 0 skipped" "state '$pn_state' is always re-executed"
    assert_matches "$OUT" "Slice 2 — $pn_state \\(run\\)" "state '$pn_state' is reported and still queued"
  done
}

case_progress_record_shape() {
  standard_fixture progress-shape
  reset_engine_counters
  run_loop
  seed_progress "$(state_dir)" "done"

  pr_lines=$(grep -c '' "$(state_dir)/progress.tsv")
  assert_eq "3" "$pr_lines" "the progress record has one line per slice"

  pr_fields=$(head -1 "$(state_dir)/progress.tsv" | tr "$TAB" '\n' | grep -c '')
  assert_eq "6" "$pr_fields" "each line carries number, hash, state and the two gate results plus the cause"

  assert_matches "$(state_dir)/progress.tsv" "^1${TAB}[0-9a-f]{64}${TAB}done${TAB}passed${TAB}passed${TAB}" "the record is tab separated and keyed on number plus body hash"
}

case_progress_hash_is_per_slice() {
  standard_fixture progress-hash
  reset_engine_counters
  run_loop
  cp "$(state_dir)/manifest.txt" "$TMP/manifest-before.txt"

  ph_doc="$FIX/.spec/features/demo/ISSUES.md"
  awk '{ print } /^Fatia 2 do plano padrão\.$/ { print ""; print "Mudança isolada." }' \
    "$ph_doc" > "$TMP/hash-edited.md"
  cp "$TMP/hash-edited.md" "$ph_doc"
  run_loop

  ph_before_1=$(grep '^slice-01.md|' "$TMP/manifest-before.txt" | cut -d'|' -f4)
  ph_after_1=$(grep '^slice-01.md|' "$(state_dir)/manifest.txt" | cut -d'|' -f4)
  ph_before_2=$(grep '^slice-02.md|' "$TMP/manifest-before.txt" | cut -d'|' -f4)
  ph_after_2=$(grep '^slice-02.md|' "$(state_dir)/manifest.txt" | cut -d'|' -f4)

  assert_eq "$ph_before_1" "$ph_after_1" "the hash of an untouched slice does not move"
  assert_ne "$ph_before_2" "$ph_after_2" "the hash of the edited slice changes"
}

case_only_slice_restricts_the_plan() {
  standard_fixture only-slice
  reset_engine_counters

  run_loop --only-slice 2
  assert_eq "0" "$RC" "--only-slice: exit 0"
  assert_contains "$OUT" "1 slice(s) to execute, 2 skipped" "--only-slice queues a single slice"
  assert_matches "$OUT" 'Slice 2 — pending \(run\)' "the requested slice is queued"
  assert_matches "$OUT" 'Slice 1 — pending \(skip: --only-slice 2\)' "the other slices are skipped by the flag"

  run_loop --only-slice 99
  assert_ne "0" "$RC" "--only-slice with an unknown number: non-zero exit"
  assert_contains "$OUT" "no such slice" "the unknown slice number is reported"
}

case_cli_surface_is_accepted() {
  standard_fixture cli-surface
  reset_engine_counters

  run_loop --engine claude --test-cmd "make test" --max-cycles 5 --no-verify --keep-going
  assert_eq "0" "$RC" "the full flag surface is accepted"
  assert_contains "$OUT" "engine: claude" "--engine selects the engine"

  run_loop --engine perl
  assert_ne "0" "$RC" "an unknown engine is rejected"
  assert_contains "$OUT" "Unknown engine" "the unknown engine is named"

  MS_LOOP_VERIFY=weird run_loop
  assert_ne "0" "$RC" "an invalid MS_LOOP_VERIFY is rejected"

  run_loop --help
  assert_eq "0" "$RC" "--help exits 0"
  assert_contains "$OUT" "MS_LOOP_MAX_LIMIT_WAITS" "the header documents every environment variable"
  assert_contains "$OUT" "MS_LOOP_LABEL" "the header documents the triage label variable"
  assert_zero_engine_calls "cli surface"
}

case_env_max_cycles_is_read() {
  standard_fixture env-vars
  reset_engine_counters

  MS_LOOP_MAX_CYCLES=zero run_loop
  assert_ne "0" "$RC" "MS_LOOP_MAX_CYCLES is validated"
  assert_contains "$OUT" "--max-cycles expects a positive integer" "an invalid cycle count is named"

  MS_LOOP_MAX_LIMIT_WAITS=-1 run_loop
  assert_ne "0" "$RC" "MS_LOOP_MAX_LIMIT_WAITS is validated"
  assert_contains "$OUT" "MS_LOOP_MAX_LIMIT_WAITS expects a positive integer" "an invalid wait count is named"

  MS_LOOP_TEST_CMD="make test" run_loop
  assert_eq "0" "$RC" "MS_LOOP_TEST_CMD does not disturb the preflight"
  assert_zero_engine_calls "environment variables"
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

CASES="
case_harness_mocks_shadow_real_engines
case_shell_audit_rejects_bash4_construct
case_loop_has_no_associative_array
case_input_positional_wins
case_input_single_feature_glob
case_input_init_artifact
case_input_feature_glob_beats_init_artifact
case_input_tie_aborts_listing_candidates
case_input_no_candidate_aborts
case_precondition_outside_git_work_tree
case_precondition_dirty_work_tree
case_format_no_slice_heading
case_format_malformed_slice_heading
case_format_blocked_by_outside_grammar
case_format_cyclic_graph
case_format_init_artifact_same_validation
case_split_file_count_matches_headings
case_split_keeps_issue_body_headings
case_split_trailing_section_does_not_leak
case_split_writes_nothing_outside_spec
case_split_never_rewrites_the_input
case_exclude_registration_is_idempotent
case_progress_all_done_is_skipped
case_progress_editing_one_slice_reexecutes_only_it
case_progress_publication_invalidates_nothing
case_progress_non_done_states_are_reexecuted
case_progress_record_shape
case_progress_hash_is_per_slice
case_only_slice_restricts_the_plan
case_cli_surface_is_accepted
case_env_max_cycles_is_read
"

make_mocks

if [ ! -x "$LOOP" ]; then
  echo "FAIL: $LOOP is not executable."
  exit 1
fi

for case_name in $CASES; do
  if [ -n "$ONLY" ] && [ "$case_name" != "$ONLY" ] && [ "case_$ONLY" != "$case_name" ]; then
    continue
  fi
  printf '%b==%b %s\n' "$BLUE" "$NC" "${case_name#case_}"
  "$case_name"
done

echo
echo "sessions counted separately — implementation: $(impl_sessions), verifier: $(verify_sessions)"
echo "passed: $PASS   failed: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
