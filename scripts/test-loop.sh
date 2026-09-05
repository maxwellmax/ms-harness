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

# The directory the loop is invoked from and the PATH it sees. Both default to
# the fixture and the mock PATH; a case overrides one to prove that the test
# command is probed in the INVOCATION directory only, or that the run needs no
# `gh` on PATH.
RUN_DIR=""
RUN_PATH=""

new_fixture() {
  FIX="$TMP/fx-$1"
  OUT="$TMP/out-$1.log"
  rm -rf "$FIX"
  mkdir -p "$FIX"
  : > "$OUT"
  RC=0
  RUN_DIR=""
  RUN_PATH=""
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
    cd "${RUN_DIR:-$FIX}" || exit 1
    PATH="${RUN_PATH:-$MOCK_BIN:$PATH}" \
    MOCK_STATE="$TMP/mockstate" \
    MOCK_SCENARIO="${MOCK_SCENARIO:-ok}" \
      "$LOOP" "$@"
  ) < /dev/null > "$OUT" 2>&1
  RC=$?
}

# Everything a fixture added since the last commit. The loop refuses a dirty
# work tree, so a case that drops a manifest or a config file into the fixture
# has to commit it before running.
commit_fixture() {
  (
    cd "$FIX" || exit 1
    git add -A
    git commit -qm "fixture: added files"
  ) > /dev/null 2>&1
}

# A PATH with `gh` genuinely absent: symlinks to the tools the loop actually
# uses and nothing else. RF-11 decides readiness from the document and the
# progress record, so the whole graph has to resolve without it.
GH_FREE_BIN=""

make_gh_free_bin() {
  GH_FREE_BIN="$TMP/nogh"
  mkdir -p "$GH_FREE_BIN"
  for mgb_tool in bash sh env git sed grep awk cut tr mkdir mv rm cp ln ls cat wc \
    dirname basename date sha256sum shasum sort head tail chmod; do
    mgb_path=$(command -v "$mgb_tool" 2> /dev/null)
    [ -n "$mgb_path" ] || continue
    ln -sf "$mgb_path" "$GH_FREE_BIN/$mgb_tool"
  done
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

# One slice of the progress record, on the composite key the loop looks it up
# by, leaving every other entry untouched.
seed_progress_one() {
  spo_dir="$1"
  spo_num="$2"
  spo_state="$3"
  spo_file="$spo_dir/progress.tsv"
  [ -f "$spo_file" ] || : > "$spo_file"
  spo_hash=$(awk -F'|' -v n="$spo_num" '$2 == n { print $4 }' "$spo_dir/manifest.txt")
  grep -v "^$spo_num${TAB}" "$spo_file" > "$spo_file.tmp"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$spo_num" "$spo_hash" "$spo_state" "passed" "passed" "" >> "$spo_file.tmp"
  mv "$spo_file.tmp" "$spo_file"
}

# A minimal CT-01 document, one slice per argument, each argument being
#   <number>|<title>|<Blocked by value>|<Issue field value>
# Enough to carry a dependency graph, and no more.
write_graph_issues() {
  wgi_target="$1"
  shift
  mkdir -p "$(dirname "$wgi_target")"
  {
    echo "# Issues: graph"
    echo
    for wgi_spec in "$@"; do
      wgi_num="${wgi_spec%%|*}"
      wgi_rest="${wgi_spec#*|}"
      wgi_title="${wgi_rest%%|*}"
      wgi_rest="${wgi_rest#*|}"
      wgi_blocked="${wgi_rest%%|*}"
      wgi_issue="${wgi_rest#*|}"
      echo "## Slice $wgi_num: [feat] $wgi_title"
      echo
      echo "- **Issue**: $wgi_issue"
      echo "- **Tasks**: T0$wgi_num"
      echo "- **Blocked by**: $wgi_blocked"
      echo
      echo "### Corpo"
      echo
      echo "## Critérios de aceite"
      echo
      echo "- [ ] $wgi_title exists"
      echo
      echo "---"
      echo
    done
  } > "$wgi_target"
}

graph_fixture() {
  gf_name="$1"
  shift
  new_fixture "$gf_name"
  git_init_fixture
  write_graph_issues "$FIX/.spec/features/demo/ISSUES.md" "$@"
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
# Cases — test command resolution chain (T15: RF-16 to RF-20, UI-04)
#
# The precedence is proven PAIRWISE — each level against the one below it — so
# a regression that collapses two levels into one cannot hide behind a case
# that only exercises the top of the chain.
# ---------------------------------------------------------------------------

case_testcmd_flag_beats_environment() {
  standard_fixture testcmd-flag-env
  reset_engine_counters

  MS_LOOP_TEST_CMD="make from-env" run_loop --test-cmd "make from-flag"
  assert_eq "0" "$RC" "flag over environment: exit 0"
  assert_contains "$OUT" "Suite gate: 'make from-flag' — resolved by the --test-cmd flag" "the flag resolves and names itself"
  assert_not_contains "$OUT" "make from-env" "the environment variable was not used"
}

case_testcmd_environment_beats_declarative_config() {
  standard_fixture testcmd-env-conf
  printf 'test_cmd=make from-config\n' > "$FIX/.ms-harness.conf"
  commit_fixture
  reset_engine_counters

  run_loop
  assert_contains "$OUT" "Suite gate: 'make from-config' — resolved by the test_cmd key of .ms-harness.conf" "the declarative config resolves on its own"

  MS_LOOP_TEST_CMD="make from-env" run_loop
  assert_eq "0" "$RC" "environment over declarative config: exit 0"
  assert_contains "$OUT" "Suite gate: 'make from-env' — resolved by the MS_LOOP_TEST_CMD environment variable" "the environment variable outranks .ms-harness.conf"
  assert_not_contains "$OUT" "make from-config" "the declarative config was not used"
}

case_testcmd_config_beats_fallback_table() {
  standard_fixture testcmd-conf-table
  printf 'module example.test\n' > "$FIX/go.mod"
  commit_fixture
  reset_engine_counters

  run_loop
  assert_contains "$OUT" "resolved by the fallback table" "with no config, the table resolves"

  printf '# the consumer declares its own command\ntest_cmd=make from-config\n' > "$FIX/.ms-harness.conf"
  commit_fixture
  run_loop
  assert_eq "0" "$RC" "declarative config over fallback table: exit 0"
  assert_contains "$OUT" "Suite gate: 'make from-config' — resolved by the test_cmd key of .ms-harness.conf" "the declarative config outranks the table"
  assert_not_contains "$OUT" "fallback table" "no table entry is consulted once the config resolved"
}

case_testcmd_table_beats_disabled_gate() {
  standard_fixture testcmd-table-none
  reset_engine_counters

  run_loop
  assert_contains "$OUT" "Suite gate DISABLED: no test command resolved" "with nothing to go on, the gate is disabled"

  printf 'module example.test\n' > "$FIX/go.mod"
  commit_fixture
  run_loop
  assert_eq "0" "$RC" "fallback table over the disabled gate: exit 0"
  assert_contains "$OUT" "Suite gate: 'go test ./...' — resolved by the fallback table" "a single table match re-enables the gate"
  assert_not_contains "$OUT" "Suite gate DISABLED" "the gate is not disabled when the table resolved"
}

# Every row of scripts/test-commands.conf, one isolated fixture each: the table
# is data, and this is the case that proves each row of that data is live.
case_testcmd_one_fixture_per_supported_manifest() {
  while IFS='|' read -r mf_file mf_content mf_expected; do
    [ -n "$mf_file" ] || continue
    standard_fixture "manifest-$(printf '%s' "$mf_file" | tr '.' '-')"
    printf '%s\n' "$mf_content" > "$FIX/$mf_file"
    commit_fixture
    reset_engine_counters

    run_loop
    assert_eq "0" "$RC" "$mf_file alone: exit 0"
    assert_contains "$OUT" "Suite gate: '$mf_expected' — resolved by the fallback table" \
      "$mf_file resolves '$mf_expected' from the fallback table"
  done <<'FIXTURES'
composer.json|{ "scripts": { "test": "run-it" } }|composer test
package.json|{ "scripts": { "test": "run-it" } }|npm test
pytest.ini|[pytest]|pytest
pyproject.toml|[tool.pytest.ini_options]|pytest
go.mod|module example.test|go test ./...
Cargo.toml|[package]|cargo test
FIXTURES
}

case_testcmd_no_manifest_at_all_warns_and_runs() {
  standard_fixture testcmd-no-manifest
  reset_engine_counters

  run_loop
  assert_eq "0" "$RC" "a directory with no manifest at all still exits 0"
  assert_contains "$OUT" "Suite gate DISABLED: no test command resolved" "the loud warning is printed"
  assert_contains "$OUT" "never aborts the loop" "the warning says the run continues"
  assert_contains "$OUT" "Run plan" "the run went on past the unresolved command"
  assert_contains "$OUT" "Next ready slice: Slice 1" "the issue is still selected for execution"
  assert_not_contains "$OUT" "Precondition not met" "an unresolved test command is not a precondition failure"
}

case_testcmd_two_manifests_disable_the_gate() {
  standard_fixture testcmd-two-manifests
  printf 'module example.test\n' > "$FIX/go.mod"
  printf '[package]\nname = "example"\n' > "$FIX/Cargo.toml"
  commit_fixture
  reset_engine_counters

  run_loop
  assert_eq "0" "$RC" "two supported manifests: the run still exits 0"
  assert_contains "$OUT" "the fallback table matched 2 rules" "the ambiguity is named"
  assert_contains "$OUT" "matched: exists go.mod :: go test ./..." "the first matched candidate is listed"
  assert_contains "$OUT" "matched: exists Cargo.toml :: cargo test" "the second matched candidate is listed"
  assert_not_contains "$OUT" "Suite gate: " "neither candidate command was adopted"
  assert_contains "$OUT" "Suite gate DISABLED" "the suite gate is disabled instead of picked"
}

# RF-18 AC: deleting the whole fallback table leaves the loop working through
# the declarative config, which is what makes the table a fallback and not the
# primary source.
case_testcmd_emptied_table_still_resolves_through_config() {
  standard_fixture testcmd-emptied-table
  printf 'test_cmd=make from-config\n' > "$FIX/.ms-harness.conf"
  printf 'module example.test\n' > "$FIX/go.mod"
  commit_fixture

  mkdir -p "$TMP/alt-scripts"
  cp "$LOOP" "$TMP/alt-scripts/loop.sh"
  chmod +x "$TMP/alt-scripts/loop.sh"
  : > "$TMP/alt-scripts/test-commands.conf"

  et_saved="$LOOP"
  LOOP="$TMP/alt-scripts/loop.sh"
  reset_engine_counters
  run_loop
  LOOP="$et_saved"

  assert_eq "0" "$RC" "an emptied fallback table keeps the loop working"
  assert_contains "$OUT" "Suite gate: 'make from-config' — resolved by the test_cmd key of .ms-harness.conf" "the declarative config resolves with the table gone"
  assert_not_contains "$OUT" "go test ./..." "no table row survived to resolve anything"
}

# UI-04: in each of the five scenarios of the chain, the opening section names
# the applied rule and names only that one.
case_testcmd_opening_line_names_the_applied_rule() {
  standard_fixture testcmd-opening-line
  reset_engine_counters

  run_loop --test-cmd "make from-flag"
  assert_matches "$OUT" "Suite gate: 'make from-flag' — resolved by the --test-cmd flag$" "scenario 1 names the flag and nothing else"

  MS_LOOP_TEST_CMD="make from-env" run_loop
  assert_matches "$OUT" "Suite gate: 'make from-env' — resolved by the MS_LOOP_TEST_CMD environment variable$" "scenario 2 names the environment variable and nothing else"

  printf 'test_cmd=make from-config\n' > "$FIX/.ms-harness.conf"
  commit_fixture
  run_loop
  assert_matches "$OUT" "Suite gate: 'make from-config' — resolved by the test_cmd key of \.ms-harness\.conf$" "scenario 3 names the declarative config and nothing else"

  rm -f "$FIX/.ms-harness.conf"
  printf 'module example.test\n' > "$FIX/go.mod"
  commit_fixture
  run_loop
  assert_matches "$OUT" "Suite gate: 'go test \./\.\.\.' — resolved by the fallback table .*test-commands\.conf, rule 'exists go\.mod'$" "scenario 4 names the table and the exact rule that matched"

  rm -f "$FIX/go.mod"
  commit_fixture
  run_loop
  assert_contains "$OUT" "Suite gate DISABLED: no test command resolved. Searched, in this order:" "scenario 5 names the disabled gate"
  assert_contains "$OUT" "1. the --test-cmd flag" "the disabled-gate warning names level 1"
  assert_contains "$OUT" "2. the MS_LOOP_TEST_CMD environment variable" "the disabled-gate warning names level 2"
  assert_contains "$OUT" "3. the test_cmd key of .ms-harness.conf" "the disabled-gate warning names level 3"
  assert_contains "$OUT" "test-commands.conf (no rule matched" "the disabled-gate warning names level 4"
  assert_zero_engine_calls "the five resolution scenarios"
}

# RF-20: with both gates off the loop says so BEFORE any engine session, not
# after the fact.
case_testcmd_zero_gates_warns_before_the_first_session() {
  standard_fixture testcmd-zero-gates
  reset_engine_counters

  run_loop --no-verify
  assert_eq "0" "$RC" "both gates disabled: preflight and plan still complete"
  assert_contains "$OUT" "NO MECHANICAL VALIDATION IS ACTIVE" "the zero-gates warning is printed"
  assert_contains "$OUT" "recorded 'unverified', never 'done'" "the warning states the consequence"

  zg_warn_line=$(grep -n "NO MECHANICAL VALIDATION IS ACTIVE" "$OUT" | cut -d: -f1)
  zg_plan_line=$(grep -n "Run plan" "$OUT" | cut -d: -f1)
  assert_eq "1" "$([ "$zg_warn_line" -lt "$zg_plan_line" ] && echo 1 || echo 0)" "the warning comes before the run plan, so before any engine session"
  assert_zero_engine_calls "both gates disabled"

  # One gate is enough to silence it.
  run_loop --no-verify --test-cmd "make test"
  assert_not_contains "$OUT" "NO MECHANICAL VALIDATION IS ACTIVE" "a resolved suite gate silences the zero-gates warning"
  run_loop
  assert_not_contains "$OUT" "NO MECHANICAL VALIDATION IS ACTIVE" "an enabled verifier gate silences it too"
}

# RF-17: the probe inspects the invocation directory ONLY — it never recurses
# into a subdirectory and never climbs to a parent.
case_testcmd_probe_inspects_the_invocation_directory_only() {
  new_fixture testcmd-probe-scope
  git_init_fixture
  mkdir -p "$FIX/sub" "$FIX/inner"
  printf 'module example.test\n' > "$FIX/go.mod"
  printf '[package]\nname = "nested"\n' > "$FIX/sub/Cargo.toml"
  write_standard_issues "$FIX/inner/.spec/features/demo/ISSUES.md"
  commit_fixture
  reset_engine_counters

  RUN_DIR="$FIX/inner"
  run_loop
  RUN_DIR=""
  assert_eq "0" "$RC" "probing from a subdirectory: exit 0"
  assert_contains "$OUT" "Suite gate DISABLED: no test command resolved" "the manifest in the parent directory is not reached"
  assert_not_contains "$OUT" "go test ./..." "no walk up to the parent directory happened"
  assert_not_contains "$OUT" "cargo test" "no recursive scan into a subdirectory happened"
}

# RF-18 AC, as a static assertion on the script itself: the only place a
# language or a package manager may be named is the data rows of the table.
case_testcmd_loop_names_no_stack() {
  new_fixture testcmd-no-stack
  grep -nE 'laravel|artisan|vendor/bin|docker compose exec' "$LOOP" > "$OUT" 2>&1
  assert_empty_file "$OUT" "loop.sh names no framework, container command or vendored binary path"

  grep -niE '(^|[^[:alnum:]_-])sail([^[:alnum:]_-]|$)' "$LOOP" > "$OUT" 2>&1
  assert_empty_file "$OUT" "loop.sh contains no occurrence of 'sail' in any case (RF-13)"

  # The teeth of "no `elif` naming a language or a framework outside the data
  # rows": every manifest and package-manager name the harness knows lives in
  # the table, so none of them may appear in the script that reads it.
  grep -nE 'composer|package\.json|pytest|pyproject|go\.mod|Cargo\.toml|npm|cargo' "$LOOP" > "$OUT" 2>&1
  assert_empty_file "$OUT" "no manifest or package-manager name from the table appears in loop.sh at all"

  # And the table really is where they live, so the assertion above is not
  # vacuously true because the harness forgot the data.
  grep -cE '^[^#]' "$(dirname "$LOOP")/test-commands.conf" > "$OUT" 2>&1
  assert_ne "0" "$(cat "$OUT")" "the fallback table carries the data rows loop.sh refuses to name"
}

# ---------------------------------------------------------------------------
# Cases — dependency graph and selection (T17: RF-11, RF-34 a, b)
# ---------------------------------------------------------------------------

case_graph_resolves_with_gh_absent_from_path() {
  standard_fixture graph-no-gh
  make_gh_free_bin
  reset_engine_counters

  RUN_PATH="$MOCK_BIN:$GH_FREE_BIN"
  gn_gh=$(PATH="$RUN_PATH" command -v gh 2> /dev/null)
  assert_eq "" "$gn_gh" "gh really is absent from the PATH the run uses"

  run_loop
  RUN_PATH=""
  assert_eq "0" "$RC" "the graph resolves with gh absent from PATH: exit 0"
  assert_contains "$OUT" "Execution order, from '- **Blocked by**:' alone: Slice 1 -> Slice 2 -> Slice 3" "the declared dependency order is honoured without gh"
  assert_contains "$OUT" "Next ready slice: Slice 1" "the first ready slice is the one nothing blocks"
}

case_graph_never_queries_github() {
  new_fixture graph-no-github
  grep -nE '(^|[^[:alnum:]_./"-])gh([[:space:]]|$)' "$LOOP" | grep -vE '^[0-9]+:[[:space:]]*#' > "$OUT" 2>&1
  assert_empty_file "$OUT" "loop.sh never invokes gh outside its own comments"
}

case_graph_blocker_not_done_is_never_selected() {
  standard_fixture graph-readiness
  reset_engine_counters

  run_loop
  assert_contains "$OUT" "Next ready slice: Slice 1" "a slice with an unfinished blocker is not selected"
  assert_contains "$OUT" "3 slice(s) to execute, 0 skipped" "the blocked slices stay queued, they are not dropped"

  # Only `done` advances the ready set.
  for gr_state in unverified failed blocked; do
    seed_progress_one "$(state_dir)" 1 "$gr_state"
    run_loop
    assert_contains "$OUT" "Next ready slice: Slice 1" "a blocker recorded '$gr_state' does not release Slice 2"
  done

  seed_progress_one "$(state_dir)" 1 "done"
  run_loop
  assert_contains "$OUT" "Next ready slice: Slice 2" "Slice 2 is released only once its blocker is recorded done"

  seed_progress_one "$(state_dir)" 2 "done"
  run_loop
  assert_contains "$OUT" "Next ready slice: Slice 3" "selection walks the chain in dependency order"
  assert_zero_engine_calls "graph readiness"
}

case_graph_external_block_is_reported_and_never_selected() {
  graph_fixture graph-external \
    "1|Ready|nenhum|não publicada" \
    "2|Waiting on the world|#999|não publicada" \
    "3|Independent|nenhum|não publicada"
  reset_engine_counters

  run_loop
  assert_eq "0" "$RC" "an external block never makes the run fail"
  assert_matches "$OUT" 'Slice 2 — blocked-external \(skip: blocked externally by #999\)' "the opening summary reports the slice as blocked-external"
  assert_contains "$OUT" "Blocked externally — never selected, and never a reason for the run to fail:" "the opening summary has an explicit external-block section"
  assert_contains "$OUT" "Slice 2 — waiting on #999, which matches no slice of .spec/features/demo/ISSUES.md" "the summary names the unmatched issue number"
  assert_contains "$OUT" "2 slice(s) to execute, 1 skipped" "the externally blocked slice is out of the queue"
  assert_matches "$(state_dir)/progress.tsv" "^2${TAB}[0-9a-f]{64}${TAB}blocked-external${TAB}disabled${TAB}disabled${TAB}" "the state is recorded, not only printed"

  # It stays out of the selection at every point of the run, not only first.
  seed_progress_one "$(state_dir)" 1 "done"
  seed_progress_one "$(state_dir)" 3 "done"
  run_loop
  assert_eq "0" "$RC" "with everything else done, the run still exits 0"
  assert_contains "$OUT" "No slice is ready to execute." "the externally blocked slice is never selected"
  assert_zero_engine_calls "external block"
}

# RF-34b: propagation is TRANSITIVE. Slice 3 does not depend on the unreachable
# slice directly — it depends on a slice that does — and it is blocked all the
# same, with no engine session for either of them.
case_graph_blocking_propagates_transitively() {
  graph_fixture graph-transitive \
    "1|A, unreachable|#999|não publicada" \
    "2|B, depends on A|Slice 1|não publicada" \
    "3|C, depends on B|Slice 2|não publicada" \
    "4|D, independent|nenhum|não publicada"
  reset_engine_counters

  run_loop
  assert_eq "0" "$RC" "transitive blocking alone never fails the run"
  assert_matches "$OUT" 'Slice 1 — blocked-external \(skip: blocked externally by #999\)' "the root cause is reported as the external block it is"
  assert_matches "$OUT" 'Slice 2 — blocked \(skip: blocked by Slice 1, which is blocked externally\)' "the direct dependent is blocked and the cause names the root"
  assert_matches "$OUT" 'Slice 3 — blocked \(skip: blocked by Slice 1, which is blocked externally\)' "the indirect dependent is blocked transitively"
  assert_matches "$OUT" 'Slice 4 — pending \(run\)' "an independent branch of the graph is untouched"
  assert_contains "$OUT" "1 slice(s) to execute, 3 skipped" "only the independent slice is queued"
  assert_contains "$OUT" "Next ready slice: Slice 4" "selection jumps straight to the reachable branch"

  assert_matches "$(state_dir)/progress.tsv" "^2${TAB}[0-9a-f]{64}${TAB}blocked${TAB}disabled${TAB}disabled${TAB}" "the direct dependent is recorded blocked"
  assert_matches "$(state_dir)/progress.tsv" "^3${TAB}[0-9a-f]{64}${TAB}blocked${TAB}disabled${TAB}disabled${TAB}" "the transitive dependent is recorded blocked"
  assert_zero_engine_calls "transitive blocking"
}

# CT-01: `- **Blocked by**:` is the single parsed source. The `## Bloqueado por`
# heading of the body is prose, and a divergence between the two is not an
# error — the field wins and the prose is not read.
case_graph_body_prose_heading_is_never_parsed() {
  new_fixture graph-prose
  git_init_fixture
  mkdir -p "$FIX/.spec/features/demo"
  cat > "$FIX/.spec/features/demo/ISSUES.md" <<'DOC'
# Issues: prose

## Slice 1: [feat] First

- **Issue**: não publicada
- **Blocked by**: nenhum

### Corpo

## Bloqueado por

Slice 2 e a issue #999 — prosa para quem lê, nunca parseada.

---

## Slice 2: [feat] Second

- **Issue**: não publicada
- **Blocked by**: nenhum

### Corpo

## Bloqueado por

Nada.
DOC
  reset_engine_counters

  run_loop
  assert_eq "0" "$RC" "a divergence between the field and the body prose is not an error"
  assert_not_contains "$OUT" "blocked-external" "the #999 named only in the prose creates no external block"
  assert_not_contains "$OUT" "has a cycle" "the prose naming Slice 2 creates no edge and so no cycle"
  assert_contains "$OUT" "Execution order, from '- **Blocked by**:' alone: Slice 1 -> Slice 2" "the field alone builds the graph"
  assert_contains "$OUT" "2 slice(s) to execute, 0 skipped" "both slices are runnable, as their fields declare"
}

# RF-11: a `#<n>` blocker that DOES match a slice of this same document is an
# ordinary edge, not an external block.
case_graph_issue_number_blocker_matching_a_slice_is_an_edge() {
  graph_fixture graph-issue-edge \
    "1|Published first|nenhum|#42" \
    "2|Blocked by the published one|#42|não publicada"
  reset_engine_counters

  run_loop
  assert_eq "0" "$RC" "an issue-number blocker matching a slice: exit 0"
  assert_not_contains "$OUT" "blocked-external" "#42 matches Slice 1, so it is not an external block"
  assert_contains "$OUT" "Execution order, from '- **Blocked by**:' alone: Slice 1 -> Slice 2" "the issue number resolves to an edge"
  assert_contains "$OUT" "Next ready slice: Slice 1" "Slice 2 waits on the slice that carries #42"

  seed_progress_one "$(state_dir)" 1 "done"
  run_loop
  assert_contains "$OUT" "Next ready slice: Slice 2" "Slice 2 is released once #42's slice is recorded done"
  assert_zero_engine_calls "issue-number edge"
}

# RF-34a/b with a `failed` root. The run loop that ends a slice `failed` is a
# later task, so the entry point it will call is driven here on a patched copy
# of the script — the harness's sanctioned way of reaching a path main() does
# not reach yet. What is asserted is the propagation itself: the whole cone
# downstream of the failure, at any depth, recorded `blocked` with the failure
# named as the cause, an independent branch untouched, and no engine session
# for any of them.
case_graph_failure_propagates_transitively() {
  graph_fixture graph-failed-root \
    "1|A, the one that fails|nenhum|não publicada" \
    "2|B, depends on A|Slice 1|não publicada" \
    "3|C, depends on B|Slice 2|não publicada" \
    "4|D, independent|nenhum|não publicada"
  reset_engine_counters

  gf_dir="$TMP/failed-root-scripts"
  mkdir -p "$gf_dir"
  sed 's/^  print_run_plan$/  print_run_plan\
  mark_dependents_of_failure 1/' "$LOOP" > "$gf_dir/loop.sh"
  chmod +x "$gf_dir/loop.sh"
  cp "$(dirname "$LOOP")/test-commands.conf" "$gf_dir/test-commands.conf"
  assert_ne "0" "$(grep -c 'mark_dependents_of_failure 1' "$gf_dir/loop.sh")" "the patched copy really drives the failure path"

  gf_saved="$LOOP"
  LOOP="$gf_dir/loop.sh"
  run_loop
  LOOP="$gf_saved"

  assert_eq "0" "$RC" "marking the cone of a failed slice is not itself an error"
  assert_matches "$(state_dir)/progress.tsv" "^2${TAB}[0-9a-f]{64}${TAB}blocked${TAB}disabled${TAB}disabled${TAB}blocked by Slice 1, which failed$" "the direct dependent of the failed slice is recorded blocked, cause named"
  assert_matches "$(state_dir)/progress.tsv" "^3${TAB}[0-9a-f]{64}${TAB}blocked${TAB}disabled${TAB}disabled${TAB}blocked by Slice 1, which failed$" "the indirect dependent is recorded blocked transitively"
  assert_eq "0" "$(grep -c "^4${TAB}" "$(state_dir)/progress.tsv")" "the independent branch is not touched by the failure"
  assert_zero_engine_calls "failure propagation"
}

# RF-11 / CT-01, as a static assertion: `## Bloqueado por` may be named in the
# prose of this script, but never read as a source of the graph.
case_graph_prose_heading_is_not_a_parsing_source() {
  new_fixture graph-prose-static
  grep -n 'Bloqueado por' "$LOOP" | grep -vE '^[0-9]+:[[:space:]]*#' > "$OUT" 2>&1
  assert_empty_file "$OUT" "'Bloqueado por' appears in loop.sh only inside comments, never as a parsing source"

  grep -c '\*\*Blocked by\*\*' "$LOOP" > "$OUT" 2>&1
  assert_ne "0" "$(cat "$OUT")" "the field that IS parsed is the one the contract names"
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
case_testcmd_flag_beats_environment
case_testcmd_environment_beats_declarative_config
case_testcmd_config_beats_fallback_table
case_testcmd_table_beats_disabled_gate
case_testcmd_one_fixture_per_supported_manifest
case_testcmd_no_manifest_at_all_warns_and_runs
case_testcmd_two_manifests_disable_the_gate
case_testcmd_emptied_table_still_resolves_through_config
case_testcmd_opening_line_names_the_applied_rule
case_testcmd_zero_gates_warns_before_the_first_session
case_testcmd_probe_inspects_the_invocation_directory_only
case_testcmd_loop_names_no_stack
case_graph_resolves_with_gh_absent_from_path
case_graph_never_queries_github
case_graph_blocker_not_done_is_never_selected
case_graph_external_block_is_reported_and_never_selected
case_graph_blocking_propagates_transitively
case_graph_body_prose_heading_is_never_parsed
case_graph_issue_number_blocker_matching_a_slice_is_an_edge
case_graph_failure_propagates_transitively
case_graph_prose_heading_is_not_a_parsing_source
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
