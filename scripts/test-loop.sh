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
SELF="$ROOT/scripts/test-loop.sh"
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

assert_same_file() {
  if cmp -s "$1" "$2"; then
    ok "$3"
  else
    bad "$3 ($1 and $2 differ)"
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
sandbox=""
allowed=""

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
# to redirect stdin, the mock swallows the caller's stream and the run hangs or
# skips work — so the mock reads it on purpose and the suite notices.
if [ "$name" = "claude" ]; then
  [ -t 0 ] || cat > /dev/null
  while [ $# -gt 0 ]; do
    case "$1" in
      -p) prompt="${2:-}"; shift 2 ;;
      --allowedTools) allowed="${2:-}"; verify=1; shift 2 ;;
      *) shift ;;
    esac
  done
else
  while [ $# -gt 0 ]; do
    case "$1" in
      --sandbox)
        sandbox="${2:-}"
        [ "$sandbox" = "read-only" ] && verify=1
        shift 2
        ;;
      *) shift ;;
    esac
  done
  [ -t 0 ] || prompt=$(cat)
fi

echo "$name $scenario" >> "$state/invocations"

# The slice under work, read out of the prompt the loop built. Everything this
# mock does is a function of the REAL fixture files, never of a canned answer.
slice=$(printf '%s\n' "$prompt" | grep -oE '^## Slice [0-9]+' | head -1 | grep -oE '[0-9]+' || true)
[ -n "$slice" ] || slice=0
marker="impl-slice-$slice.txt"

if [ "$verify" -eq 1 ]; then
  bump verify_calls > /dev/null
  echo "$name verify sandbox=$sandbox allowedTools=$allowed" >> "$state/verify_args"

  expected=$(printf '%s\n' "$prompt" | awk '
    /^## Checkboxes to judge/ { inside = 1; next }
    /^## / { inside = 0 }
    inside && /^[[:space:]]*- \[/ { count++ }
    END { print count + 0 }
  ')

  case "$scenario" in
    verify-extra) expected=$((expected + 1)) ;;
    verify-short) expected=$((expected - 1)) ;;
    verify-garbage)
      echo "Everything looks broadly fine to me; I did not itemise it."
      exit 0
      ;;
  esac

  i=1
  while [ "$i" -le "$expected" ]; do
    if [ -f "$marker" ]; then
      echo "CRITERION $i: DONE — $marker:1"
    else
      echo "CRITERION $i: INCOMPLETE — $marker does not exist"
    fi
    i=$((i + 1))
  done
  exit 0
fi

bump impl_calls > /dev/null
attempts=$(bump "impl_calls_slice_$slice")
echo "$name impl sandbox=$sandbox" >> "$state/impl_args"

# The usage-limit message lands at the END of the log, which is the only place
# the loop looks for it.
if [ "$scenario" = "usage-limit-once" ] && [ ! -f "$state/limit_hit_$slice" ]; then
  : > "$state/limit_hit_$slice"
  echo "usage limit reached, try again after the reset"
  exit 0
fi

write=1
case "$scenario" in
  noop) write=0 ;;
  green-cycle-2) [ "$attempts" -ge 2 ] || write=0 ;;
esac

if [ "$write" -eq 1 ] && [ "$slice" != "0" ]; then
  echo "work of slice $slice, session $attempts" >> "$marker"
fi

# `claude -p --output-format json` is the impl invocation, and the loop reads
# the completion signal out of that stream.
if [ "$name" = "claude" ]; then
  echo '{"type":"result","is_error":false,"subtype":"success"}'
fi

exit 0
MOCK

  chmod +x "$MOCK_BIN/mock-engine"
  for engine in claude codex; do
    cp "$MOCK_BIN/mock-engine" "$MOCK_BIN/$engine"
    chmod +x "$MOCK_BIN/$engine"
  done

  # The consumer project's suite is mocked too: the suite gate runs a real
  # command, and these are the command names the resolution chain can produce
  # in a fixture. They pass unless a case deliberately makes one fail.
  for runner in make go cargo npm composer pytest; do
    cat > "$MOCK_BIN/$runner" <<'RUNNER'
#!/usr/bin/env bash
echo "mock suite: $(basename "$0") $*"
exit 0
RUNNER
    chmod +x "$MOCK_BIN/$runner"
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

# A fixture repository that owes nothing to the host. The developer's global
# ignore file is neutralised: a machine whose ~/.config/git/ignore happens to
# list `.spec/` must never be the reason this suite is green. The exclusion of
# the planning artifacts is then written into the fixture itself, so it is the
# same on every host.
#
# `.spec/` stays out of the fixture's commit surface on purpose: it carries the
# loop's input document and the loop's state directory, so a case may edit a
# slice body between two runs without tripping the clean-tree precondition of
# RF-35b. That is a property of the FIXTURE — the dirty-tree case proves the
# precondition itself with paths outside `.spec/`.
git_init_fixture() {
  : > "$TMP/no-global-ignore"
  (
    cd "$FIX" || exit 1
    git init -q .
    git config user.email harness@example.test
    git config user.name harness
    git config core.excludesFile "$TMP/no-global-ignore"
    printf '.spec/\n' > .git/info/exclude
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

# A `.ms-harness.conf` declaring the consumer project's test command — the
# primary, stack-agnostic source of RF-17. Written at the invocation directory,
# which is the only place the loop looks for it.
write_ms_conf() {
  printf 'test_cmd=%s\n' "$1" > "${RUN_DIR:-$FIX}/.ms-harness.conf"
}

# One manifest of the fallback table, at the invocation directory. `<file>` and
# `<content>` are data: the suite never branches on which manifest it just
# wrote, exactly as the loop never does (RF-18).
write_manifest() {
  printf '%s\n' "$2" > "${RUN_DIR:-$FIX}/$1"
}

# The fixture builder: a git repository carrying an issue document built from a
# given graph, plus whichever optional artifacts the case asks for.
#
#   build_fixture <name> [document] [--init] [--conf <cmd>] [--manifest <f>=<c>]...
#
#   --standard          the three-slice CT-01 document (the default)
#   --single <n>        a one-slice document with <n> acceptance criteria
#   --graph <spec>      repeatable; one slice per spec, each spec being
#                       "<number>|<title>|<Blocked by>|<Issue field>"
#   --graph-list <l>    the same specs already joined into a newline list, for
#                       a caller that has them in a variable rather than in
#                       literal arguments (no array is used anywhere: the
#                       supported bash is 3.2, per RNF-10)
#   --init              write the document to .spec/init/project-issues.md
#                       instead of .spec/features/demo/ISSUES.md, so the init
#                       chain artifact of RF-08 is built by this same builder
#   --conf <cmd>        a .ms-harness.conf declaring <cmd> as the test command
#   --manifest <f>=<c>  repeatable; a manifest file <f> carrying content <c>
#
# Whatever the options wrote outside `.spec/` is committed before returning,
# because the loop refuses a dirty work tree (RF-35b).
build_fixture() {
  bf_name="$1"
  shift
  bf_doc="standard"
  bf_criteria=1
  bf_graph=""
  bf_init=0
  bf_conf=""
  bf_manifests=""
  bf_extra=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --standard) bf_doc="standard"; shift ;;
      --single) bf_doc="single"; bf_criteria="$2"; shift 2 ;;
      --graph)
        bf_doc="graph"
        bf_graph="$bf_graph$2
"
        shift 2
        ;;
      --graph-list)
        bf_doc="graph"
        bf_graph="$bf_graph$2"
        shift 2
        ;;
      --init) bf_init=1; shift ;;
      --conf) bf_conf="$2"; bf_extra=1; shift 2 ;;
      --manifest)
        bf_manifests="$bf_manifests$2
"
        bf_extra=1
        shift 2
        ;;
      *)
        echo "build_fixture: unknown option '$1'" >&2
        return 1
        ;;
    esac
  done

  new_fixture "$bf_name"
  git_init_fixture

  if [ "$bf_init" -eq 1 ]; then
    bf_target="$FIX/.spec/init/project-issues.md"
  else
    bf_target="$FIX/.spec/features/demo/ISSUES.md"
  fi

  case "$bf_doc" in
    standard) write_standard_issues "$bf_target" ;;
    single) write_single_issue "$bf_target" "$bf_criteria" ;;
    graph)
      bf_specs=""
      while IFS= read -r bf_line; do
        [ -n "$bf_line" ] || continue
        bf_specs="$bf_specs$bf_line
"
      done <<GRAPH
$bf_graph
GRAPH
      write_graph_issues_from_list "$bf_target" "$bf_specs"
      ;;
  esac

  [ -n "$bf_conf" ] && write_ms_conf "$bf_conf"

  while IFS= read -r bf_entry; do
    [ -n "$bf_entry" ] || continue
    write_manifest "${bf_entry%%=*}" "${bf_entry#*=}"
  done <<MANIFESTS
$bf_manifests
MANIFESTS

  [ "$bf_extra" -eq 1 ] && commit_fixture
  return 0
}

# The single malformed document of the format contract: a level-2 heading that
# reads like a slice heading but is not one, on line 13. It is written by ONE
# function because RF-08 requires the init chain artifact to go through exactly
# the same validation as `ISSUES.md` — the case for it may not use a document of
# its own, or it would be proving something weaker than the requirement.
write_malformed_issues() {
  wmi_target="$1"
  mkdir -p "$(dirname "$wmi_target")"
  cat > "$wmi_target" <<'DOC'
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
}

standard_fixture() {
  build_fixture "$1" --standard
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

# Rolls the counters of the case that just ended into the suite-wide ledgers and
# starts the next case at zero. The two ledgers are separate from end to end:
# the verifier is itself an engine session (RF-10, CT-07), so folding it into
# the implementation count would let a reused implementation session hide behind
# a verification.
TOTAL_IMPL=0
TOTAL_VERIFY=0

reset_engine_counters() {
  TOTAL_IMPL=$((TOTAL_IMPL + $(impl_sessions)))
  TOTAL_VERIFY=$((TOTAL_VERIFY + $(verify_sessions)))
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

# Drops one slice from the progress record, leaving every other entry alone —
# the counterpart of seed_progress_one, for cases that need a slice to look
# unexecuted while the others keep their recorded state.
clear_progress_one() {
  cpo_file="$1/progress.tsv"
  [ -f "$cpo_file" ] || return 0
  grep -v "^$2${TAB}" "$cpo_file" > "$cpo_file.tmp" || true
  mv "$cpo_file.tmp" "$cpo_file"
}

# The number of prompt files of a kind under the state directory: one file per
# engine session, which is how "a session is never reused" is counted.
prompt_files() {
  pf_count=0
  for pf_path in "$1"/prompts/*"$2"*; do
    [ -f "$pf_path" ] && pf_count=$((pf_count + 1))
  done
  printf '%s' "$pf_count"
}

new_commits_since() {
  (cd "$FIX" && git rev-list --count "$1..HEAD")
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

# The same document from a newline-separated list of specs, which is the shape
# `build_fixture` accumulates its repeated `--graph` options into.
write_graph_issues_from_list() {
  wgl_target="$1"
  wgl_specs="$2"
  (
    IFS='
'
    set -f
    # shellcheck disable=SC2086  # split on newlines only, with globbing off
    set -- $wgl_specs
    write_graph_issues "$wgl_target" "$@"
  )
}

# A one-slice CT-01 document with a chosen number of acceptance criteria: the
# smallest fixture that can exercise a gate end to end, and the one the CT-07
# count rule needs when it has to emit one line fewer than there are
# checkboxes.
write_single_issue() {
  wsi_target="$1"
  wsi_criteria="$2"
  mkdir -p "$(dirname "$wsi_target")"
  {
    echo "# Issues: single"
    echo
    echo "## Slice 1: [feat] The only slice"
    echo
    echo "- **Issue**: não publicada"
    echo "- **Tasks**: T01"
    echo "- **Blocked by**: nenhum"
    echo "- **Demoável por**: the marker file exists"
    echo
    echo "### Corpo"
    echo
    echo "## Critérios de aceite"
    echo
    wsi_i=1
    while [ "$wsi_i" -le "$wsi_criteria" ]; do
      echo "- [ ] criterion $wsi_i is met"
      wsi_i=$((wsi_i + 1))
    done
  } > "$wsi_target"
}

single_fixture() {
  build_fixture "$1" --single "${2:-1}"
}

head_rev() { (cd "$FIX" && git rev-parse HEAD); }

graph_fixture() {
  gf_name="$1"
  shift
  gf_specs=""
  for gf_spec in "$@"; do
    gf_specs="$gf_specs$gf_spec
"
  done
  build_fixture "$gf_name" --graph-list "$gf_specs"
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

# Every fixture lives under the suite's own temp directory, which the EXIT trap
# removes, and a run of the loop over a fixture leaves the harness repository
# this suite is invoked from exactly as it found it.
case_harness_run_leaks_nothing_outside_the_temp_dir() {
  standard_fixture leak-scope
  reset_engine_counters

  case "$FIX" in
    "$TMP"/*) ok "the fixture lives under the suite temp dir" ;;
    *) bad "the fixture lives under the suite temp dir (got $FIX)" ;;
  esac
  case "$OUT" in
    "$TMP"/*) ok "the captured log lives under the suite temp dir" ;;
    *) bad "the captured log lives under the suite temp dir (got $OUT)" ;;
  esac

  lk_status=$(git -C "$ROOT" status --porcelain)
  lk_head=$(git -C "$ROOT" rev-parse HEAD)
  run_loop
  assert_eq "0" "$RC" "the run over the fixture exits 0"
  assert_eq "$lk_status" "$(git -C "$ROOT" status --porcelain)" "the run leaves the harness repository untouched"
  assert_eq "$lk_head" "$(git -C "$ROOT" rev-parse HEAD)" "the run creates no commit in the harness repository"
  assert_eq "$(cd "$FIX" && pwd -P)" "$(cd "$FIX" && git rev-parse --show-toplevel)" \
    "the fixture commits land in the fixture repository, never in the harness one"
}

# T13 AC: the suite has to be able to go RED, or a green run proves nothing. A
# patched copy of the loop is built with the RF-32 ambiguity guard disabled —
# a tie stops aborting and stops naming the candidates — and this very suite is
# re-entered on the input-tie case with MS_LOOP_BIN pointing at that copy. The
# same case runs against the real loop first, so a red coming from anything
# other than the patch would be visible here.
case_harness_patched_loop_proves_the_suite_can_go_red() {
  new_fixture patched-red
  pr_dir="$TMP/patched-loop"
  rm -rf "$pr_dir"
  mkdir -p "$pr_dir"
  sed 's/"$rif_count" -gt 1 ]/"$rif_count" -gt 99 ]/g' "$ROOT/scripts/loop.sh" > "$pr_dir/loop.sh"
  chmod +x "$pr_dir/loop.sh"
  cp "$ROOT/scripts/test-commands.conf" "$pr_dir/test-commands.conf"

  pr_hits=$(grep -c '"\$rif_count" -gt 99 ]' "$pr_dir/loop.sh")
  assert_eq "2" "$pr_hits" "the patch disabled both tie guards of the resolution ladder"

  bash "$SELF" case_input_tie_aborts_listing_candidates > "$TMP/nested-green.log" 2>&1
  assert_eq "0" "$?" "the input-tie case is green against the real loop"

  MS_LOOP_BIN="$pr_dir/loop.sh" bash "$SELF" case_input_tie_aborts_listing_candidates \
    > "$TMP/nested-red.log" 2>&1
  assert_ne "0" "$?" "MS_LOOP_BIN pointing at a patched loop turns the case red"
  assert_contains "$TMP/nested-red.log" "FAIL" "the red run names the assertion that failed"
  assert_contains "$TMP/nested-red.log" "the tie is named as ambiguous input" \
    "the ambiguity assertion is the one that went red"
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
  assert_eq "3" "$(impl_sessions)" "one implementation session per slice of the document that resolved"
}

case_input_single_feature_glob() {
  standard_fixture feature-glob
  reset_engine_counters

  run_loop
  assert_eq "0" "$RC" "single feature ISSUES.md: exit 0"
  assert_contains "$OUT" "resolved by the single .spec/features/*/ISSUES.md" "the feature glob is the rule that resolved"
  assert_contains "$OUT" "state: .spec/features/demo/.loop" "state dir sits beside the feature document"
  assert_eq "3" "$(impl_sessions)" "the three slices of the resolved document are executed"
}

case_input_init_artifact() {
  build_fixture init-artifact --standard --init
  reset_engine_counters

  run_loop
  assert_eq "0" "$RC" "init chain artifact: exit 0"
  assert_contains "$OUT" "resolved by the init chain artifact .spec/init/project-issues.md" "the init artifact is the rule that resolved"
  assert_contains "$OUT" "state: .spec/init/.loop" "init chain state dir is .spec/init/.loop"
  assert_eq "3" "$(impl_sessions)" "the init chain artifact executes exactly like ISSUES.md"
}

case_input_feature_glob_beats_init_artifact() {
  standard_fixture glob-beats-init
  write_standard_issues "$FIX/.spec/init/project-issues.md"
  reset_engine_counters

  run_loop
  assert_eq "0" "$RC" "feature glob over init artifact: exit 0"
  assert_contains "$OUT" "resolved by the single .spec/features/*/ISSUES.md" "the feature glob outranks the init artifact"
  assert_not_contains "$OUT" "state: .spec/init/.loop" "the init artifact was not used"
  assert_eq "3" "$(impl_sessions)" "only the slices of the winning document were executed"
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
  write_malformed_issues "$FIX/.spec/features/demo/ISSUES.md"
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
  write_malformed_issues "$FIX/.spec/init/project-issues.md"
  reset_engine_counters

  # Byte-identical to the document the ISSUES.md case is rejected on: the two
  # cases share one fixture, so nothing about the init artifact can be adapted.
  write_malformed_issues "$TMP/malformed-reference.md"
  assert_same_file "$FIX/.spec/init/project-issues.md" "$TMP/malformed-reference.md" \
    "the init artifact is the very same fixture the ISSUES.md case uses"

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

# The loop itself writes nothing outside .spec/, so the case runs with sessions
# that write nothing at all: the work is already in HEAD, the verifier confirms
# it against the real files, and whatever appears in git status afterwards can
# only have been put there by the loop.
case_split_writes_nothing_outside_spec() {
  standard_fixture split-scope
  for ss_num in 1 2 3; do
    echo "already implemented" > "$FIX/impl-slice-$ss_num.txt"
  done
  commit_fixture
  reset_engine_counters

  ss_before=$(cd "$FIX" && git rev-parse HEAD)
  MOCK_SCENARIO=noop run_loop
  assert_eq "0" "$RC" "run over a clean tree: exit 0"
  assert_contains "$OUT" "ALREADY IMPLEMENTED in HEAD" "a session that writes nothing over green gates is not a failure"

  (cd "$FIX" && git status --porcelain) > "$TMP/status.txt"
  assert_empty_file "$TMP/status.txt" "git status --porcelain lists no path at all after a run"

  ss_outside=$(cd "$FIX" && git status --porcelain --ignored=no | grep -v '^.. \.spec/' || true)
  assert_eq "" "$ss_outside" "no path outside .spec/ appears in git status"

  assert_eq "$ss_before" "$(cd "$FIX" && git rev-parse HEAD)" "an issue already implemented in HEAD creates no commit"
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
  assert_contains "$OUT" "Suite gate — green" "the suite gate really ran the command the flag gave it"

  run_loop --engine perl
  assert_ne "0" "$RC" "an unknown engine is rejected"
  assert_contains "$OUT" "Unknown engine" "the unknown engine is named"

  MS_LOOP_VERIFY=weird run_loop
  assert_ne "0" "$RC" "an invalid MS_LOOP_VERIFY is rejected"

  run_loop --help
  assert_eq "0" "$RC" "--help exits 0"
  assert_contains "$OUT" "MS_LOOP_MAX_LIMIT_WAITS" "the header documents every environment variable"
  assert_contains "$OUT" "MS_LOOP_LABEL" "the header documents the triage label variable"
  assert_contains "$OUT" "MS_LOOP_ISSUE_NUM" "the header documents the per-issue context exported for consumer hooks"
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
  build_fixture testcmd-env-conf --standard --conf "make from-config"
  reset_engine_counters

  run_loop
  assert_contains "$OUT" "Suite gate: 'make from-config' — resolved by the test_cmd key of .ms-harness.conf" "the declarative config resolves on its own"

  MS_LOOP_TEST_CMD="make from-env" run_loop
  assert_eq "0" "$RC" "environment over declarative config: exit 0"
  assert_contains "$OUT" "Suite gate: 'make from-env' — resolved by the MS_LOOP_TEST_CMD environment variable" "the environment variable outranks .ms-harness.conf"
  assert_not_contains "$OUT" "make from-config" "the declarative config was not used"
}

case_testcmd_config_beats_fallback_table() {
  build_fixture testcmd-conf-table --standard --manifest "go.mod=module example.test"
  reset_engine_counters

  run_loop
  assert_contains "$OUT" "resolved by the fallback table" "with no config, the table resolves"

  write_ms_conf "make from-config"
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

  write_manifest go.mod "module example.test"
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
    build_fixture "manifest-$(printf '%s' "$mf_file" | tr '.' '-')" \
      --standard --manifest "$mf_file=$mf_content"
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
  build_fixture testcmd-two-manifests --standard \
    --manifest "go.mod=module example.test" \
    --manifest 'Cargo.toml=[package]'
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
  build_fixture testcmd-emptied-table --standard \
    --conf "make from-config" --manifest "go.mod=module example.test"

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

  write_ms_conf "make from-config"
  commit_fixture
  run_loop
  assert_matches "$OUT" "Suite gate: 'make from-config' — resolved by the test_cmd key of \.ms-harness\.conf$" "scenario 3 names the declarative config and nothing else"

  rm -f "$FIX/.ms-harness.conf"
  write_manifest go.mod "module example.test"
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
}

# RF-20: with both gates off the loop says so BEFORE any engine session, not
# after the fact.
case_testcmd_zero_gates_warns_before_the_first_session() {
  standard_fixture testcmd-zero-gates
  reset_engine_counters

  run_loop --no-verify
  assert_ne "0" "$RC" "both gates disabled: the run exits non-zero"
  assert_contains "$OUT" "NO MECHANICAL VALIDATION IS ACTIVE" "the zero-gates warning is printed"
  assert_contains "$OUT" "recorded 'unverified', never 'done'" "the warning states the consequence"

  zg_warn_line=$(grep -n "NO MECHANICAL VALIDATION IS ACTIVE" "$OUT" | cut -d: -f1)
  zg_plan_line=$(grep -n "Run plan" "$OUT" | cut -d: -f1)
  assert_eq "1" "$([ "$zg_warn_line" -lt "$zg_plan_line" ] && echo 1 || echo 0)" "the warning comes before the run plan, so before any engine session"

  zg_first_session=$(grep -n "Slice 1:" "$OUT" | head -1 | cut -d: -f1)
  assert_eq "1" "$([ "$zg_warn_line" -lt "$zg_first_session" ] && echo 1 || echo 0)" "the warning precedes the first engine session of the run"
  assert_eq "0" "$(grep -c "${TAB}done${TAB}" "$(state_dir)/progress.tsv")" "no issue of a zero-gates run is recorded done"
  assert_eq "1" "$(grep -c "${TAB}unverified${TAB}" "$(state_dir)/progress.tsv")" "the executed issue is recorded unverified instead"
  # And the consequence of never reaching `done`: an `unverified` blocker
  # releases nothing, exactly as an unfinished blocker of any other kind.
  assert_eq "2" "$(grep -c "${TAB}blocked${TAB}" "$(state_dir)/progress.tsv")" "the slices behind it stay blocked, because no issue of this run is done"

  # One gate is enough to silence it.
  reset_engine_counters
  run_loop --no-verify --test-cmd "make test"
  assert_eq "0" "$RC" "one active gate is enough to reach a real verdict"
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

  # The forbidden names are assembled at run time rather than written out
  # literally, exactly as the portability audit case above assembles its own
  # forbidden construct: this file is on the versioned surface that
  # scripts/check-conformance.sh scans for these very strings (AC-03, AC-04),
  # and a test that carries the coupling it forbids is drift like any other.
  stack_names=$(printf '%s|%s|%s|%s' 'lara''vel' 'arti''san' 'vendor''/bin' 'docker compose'' exec')
  removed_wrapper='sa''il'

  grep -nE "$stack_names" "$LOOP" > "$OUT" 2>&1
  assert_empty_file "$OUT" "loop.sh names no framework, container command or vendored binary path"

  grep -niE "(^|[^[:alnum:]_-])$removed_wrapper([^[:alnum:]_-]|\$)" "$LOOP" > "$OUT" 2>&1
  assert_empty_file "$OUT" "loop.sh contains no occurrence of the removed container wrapper, in any case (RF-13)"

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
  assert_eq "0" "$RC" "the chain runs to the end in dependency order"

  # Only `done` advances the ready set: every other recorded state leaves the
  # blocker unfinished, and the slices it blocks stay behind it.
  for gr_state in unverified failed blocked; do
    seed_progress_one "$(state_dir)" 1 "$gr_state"
    clear_progress_one "$(state_dir)" 2
    clear_progress_one "$(state_dir)" 3
    run_loop
    assert_contains "$OUT" "Next ready slice: Slice 1" "a blocker recorded '$gr_state' does not release Slice 2"
  done

  seed_progress_one "$(state_dir)" 1 "done"
  clear_progress_one "$(state_dir)" 2
  clear_progress_one "$(state_dir)" 3
  run_loop
  assert_contains "$OUT" "Next ready slice: Slice 2" "Slice 2 is released only once its blocker is recorded done"

  seed_progress_one "$(state_dir)" 1 "done"
  seed_progress_one "$(state_dir)" 2 "done"
  clear_progress_one "$(state_dir)" 3
  run_loop
  assert_contains "$OUT" "Next ready slice: Slice 3" "selection walks the chain in dependency order"
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
  reset_engine_counters
  run_loop
  assert_eq "0" "$RC" "with everything else done, the run still exits 0"
  assert_contains "$OUT" "No slice is ready to execute." "the externally blocked slice is never selected"
  assert_zero_engine_calls "external block, second run"
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
  assert_eq "1" "$(impl_sessions)" "only the reachable branch reached an engine session"
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

## Critérios de aceite

- [ ] a primeira fatia existe

## Bloqueado por

Slice 2 e a issue #999 — prosa para quem lê, nunca parseada.

---

## Slice 2: [feat] Second

- **Issue**: não publicada
- **Blocked by**: nenhum

### Corpo

## Critérios de aceite

- [ ] a segunda fatia existe

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
  clear_progress_one "$(state_dir)" 2
  run_loop
  assert_contains "$OUT" "Next ready slice: Slice 2" "Slice 2 is released once #42's slice is recorded done"
}

# RF-34a/b with a `failed` root, driven through the real execution path: the
# session writes nothing, the verifier judges the real files and reproves, the
# single correction cycle is spent and the issue ends `failed`. From there the
# whole cone downstream of it goes down transitively, with no engine session
# for any of them, and the run exits non-zero.
case_graph_failure_propagates_transitively() {
  graph_fixture graph-failed-root \
    "1|A, the one that fails|nenhum|não publicada" \
    "2|B, depends on A|Slice 1|não publicada" \
    "3|C, depends on B|Slice 2|não publicada" \
    "4|D, independent|nenhum|não publicada"
  reset_engine_counters

  MOCK_SCENARIO=noop run_loop --max-cycles 1
  assert_ne "0" "$RC" "an issue that ends failed makes the run exit non-zero"
  assert_matches "$(state_dir)/progress.tsv" "^1${TAB}[0-9a-f]{64}${TAB}failed${TAB}" "the root issue is recorded failed"
  assert_matches "$(state_dir)/progress.tsv" "^2${TAB}[0-9a-f]{64}${TAB}blocked${TAB}disabled${TAB}disabled${TAB}blocked by Slice 1, which failed$" "the direct dependent of the failed slice is recorded blocked, cause named"
  assert_matches "$(state_dir)/progress.tsv" "^3${TAB}[0-9a-f]{64}${TAB}blocked${TAB}disabled${TAB}disabled${TAB}blocked by Slice 1, which failed$" "the indirect dependent is recorded blocked transitively"
  assert_eq "1" "$(impl_sessions)" "the engine is invoked for the failed issue only"
  assert_contains "$OUT" "Stopping at the first failed issue" "the default behaviour is to stop at the first failure"
  assert_eq "0" "$(new_commits_since "$(cd "$FIX" && git rev-list --max-parents=0 HEAD)")" "neither the failed issue nor a blocked one produced a commit"
}

# RF-34c: stopping at the first failure is the default and `--keep-going` is
# the opt-in that carries the run into the branches the failure does not reach.
# The flag changes what still executes; it never changes the verdict.
case_graph_keep_going_runs_an_independent_branch() {
  graph_fixture graph-keep-going \
    "1|A, the one that fails|nenhum|não publicada" \
    "2|B, behind the failure|Slice 1|não publicada" \
    "3|C, an independent branch|nenhum|não publicada"
  reset_engine_counters

  MOCK_SCENARIO=noop run_loop --max-cycles 1
  assert_ne "0" "$RC" "the default run exits non-zero on the failure"
  assert_contains "$OUT" "Stopping at the first failed issue (use --keep-going to carry on)" "the default names the flag that changes it"
  assert_not_contains "$OUT" "Slice 3: [feat] C, an independent branch" "by default the independent branch is never reached"
  assert_eq "1" "$(impl_sessions)" "one implementation session: the issue that failed"

  reset_engine_counters
  MOCK_SCENARIO=noop run_loop --max-cycles 1 --keep-going
  assert_ne "0" "$RC" "--keep-going still exits non-zero, because an issue ended failed"
  assert_contains "$OUT" "--keep-going: moving on to the other branches of the graph" "the flag is what carries the run on"
  assert_contains "$OUT" "Slice 3: [feat] C, an independent branch" "the independent branch executes after the failure"
  assert_eq "2" "$(impl_sessions)" "the failed issue and the independent branch, and nothing else"
  assert_matches "$(state_dir)/progress.tsv" "^2${TAB}[0-9a-f]{64}${TAB}blocked${TAB}" "what sits behind the failure stays blocked even with --keep-going"
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
# Cases — gates and the CT-07 verdict protocol (T16: RF-10, RF-20, CT-07)
# ---------------------------------------------------------------------------

# RF-10: the engine exit code is never a verdict of completion. The mock exits
# 0 and writes nothing; the verifier judges the real files and reproves, so the
# issue ends failed with no commit.
case_gate_engine_exit_zero_without_writing_fails_the_issue() {
  single_fixture gate-noop
  reset_engine_counters
  gz_before=$(head_rev)

  MOCK_SCENARIO=noop run_loop --max-cycles 1
  assert_ne "0" "$RC" "an engine that exits 0 without writing does not approve the issue"
  assert_contains "$OUT" "The session wrote nothing" "the empty session is reported as the signal it is"
  assert_contains "$OUT" "Verifier gate red" "the verdict came from a gate, never from the exit code"
  assert_matches "$(state_dir)/progress.tsv" "^1${TAB}[0-9a-f]{64}${TAB}failed${TAB}" "the issue is recorded failed"
  assert_eq "$gz_before" "$(head_rev)" "a failed issue produces no commit"
  assert_eq "1" "$(impl_sessions)" "one implementation session for the single cycle"
}

# The suite gate runs the resolved command OUTSIDE the agent session and hands
# its REAL output to the correction cycle, which is what a fresh session needs
# in order to fix anything.
case_gate_red_suite_fails_then_the_correction_cycle_makes_one_commit() {
  single_fixture gate-suite-red
  cat > "$FIX/fake-suite.sh" <<'SUITE'
#!/usr/bin/env bash
if [ -f .suite-was-run ]; then
  echo "fake suite: 1 passed"
  exit 0
fi
: > .suite-was-run
echo "fake suite: 1 failed — assertion 'the alicerce exists' did not hold"
exit 1
SUITE
  chmod +x "$FIX/fake-suite.sh"
  commit_fixture
  reset_engine_counters
  gs_before=$(head_rev)

  run_loop --test-cmd "./fake-suite.sh"
  assert_eq "0" "$RC" "a red suite that goes green in a correction cycle ends green"
  assert_contains "$OUT" "Suite gate red" "the red suite is reported"
  assert_contains "$OUT" "Correction cycle 2/3" "a correction cycle runs after the red gate"
  assert_eq "1" "$(new_commits_since "$gs_before")" "exactly one commit covers the issue, created only after the gates went green"
  assert_contains "$(state_dir)/prompts/slice-01.cycle-2.txt" "assertion 'the alicerce exists' did not hold" \
    "the correction prompt carries the REAL cause, not a generic 'the tests failed'"
  assert_contains "$(state_dir)/prompts/slice-01.cycle-2.txt" "./fake-suite.sh" "the correction prompt names the command that went red"
  assert_matches "$(state_dir)/progress.tsv" "^1${TAB}[0-9a-f]{64}${TAB}done${TAB}passed${TAB}passed${TAB}" "both gate results are recorded"
}

# RNF-08: the verifier judges code it can never edit.
case_gate_verifier_session_is_read_only() {
  single_fixture gate-readonly
  reset_engine_counters

  run_loop
  assert_eq "0" "$RC" "the run completes"
  assert_contains "$TMP/mockstate/verify_args" "sandbox=read-only" "the codex verifier session runs read-only"
  assert_not_contains "$TMP/mockstate/impl_args" "sandbox=read-only" "the implementation session is not the read-only one"

  single_fixture gate-readonly-claude
  reset_engine_counters
  run_loop --engine claude
  assert_eq "0" "$RC" "the run completes on the other engine too"
  assert_contains "$TMP/mockstate/verify_args" "allowedTools=Read,Glob,Grep" "the claude verifier session gets read-only tools only"
}

# CT-07 anti-gaming: the verdict is red whenever the parsed line count differs
# from the checkbox count, EVEN when every line emitted says DONE.
case_gate_verifier_count_divergence_is_red() {
  single_fixture gate-count-extra 2
  reset_engine_counters
  MOCK_SCENARIO=verify-extra run_loop --max-cycles 1
  assert_ne "0" "$RC" "more verdict lines than checkboxes is red"
  assert_contains "$OUT" "emitted 3 verdict line(s) for 2 acceptance criteria" "the divergence is named with both counts"
  assert_not_contains "$OUT" "INCOMPLETE" "every line the verifier emitted said DONE, and it is still red"

  single_fixture gate-count-short 2
  reset_engine_counters
  MOCK_SCENARIO=verify-short run_loop --max-cycles 1
  assert_ne "0" "$RC" "fewer verdict lines than checkboxes is red"
  assert_contains "$OUT" "emitted 1 verdict line(s) for 2 acceptance criteria" "the short verdict is named with both counts"
  assert_not_contains "$OUT" "INCOMPLETE" "the short verdict said DONE on every line it emitted, and it is still red"
}

case_gate_verifier_zero_parsed_lines_is_red() {
  single_fixture gate-garbage
  reset_engine_counters

  MOCK_SCENARIO=verify-garbage run_loop --max-cycles 1
  assert_ne "0" "$RC" "a verdict that parses to zero lines is red"
  assert_contains "$OUT" "emitted no 'CRITERION <n>: DONE|INCOMPLETE' line at all" "the missing protocol is named"
  assert_matches "$(state_dir)/progress.tsv" "^1${TAB}[0-9a-f]{64}${TAB}failed${TAB}" "the issue is recorded failed"
}

# INCOMPLETE once, then DONE: the correction cycle is fed the verifier's own
# lines and the issue ends with exactly one commit.
case_gate_verifier_incomplete_then_done() {
  single_fixture gate-verify-cycle
  reset_engine_counters
  gv_before=$(head_rev)

  MOCK_SCENARIO=green-cycle-2 run_loop
  assert_eq "0" "$RC" "an issue completed in the second cycle ends green"
  assert_contains "$(state_dir)/prompts/slice-01.cycle-2.txt" "CRITERION 1: INCOMPLETE" "the correction prompt carries the verifier's real lines"
  assert_eq "1" "$(new_commits_since "$gv_before")" "exactly one commit, after the gates went green"
  assert_eq "2" "$(impl_sessions)" "two implementation sessions: the first attempt and one correction cycle"
  assert_eq "2" "$(verify_sessions)" "verifier sessions are counted separately"
}

# RNF-06: a usage limit is not a failed attempt. The loop waits and re-runs the
# SAME issue on the SAME cycle, so no correction cycle is consumed.
case_usage_limit_waits_and_reruns_the_same_issue() {
  single_fixture usage-limit
  reset_engine_counters

  MS_LOOP_LIMIT_WAIT_DEFAULT=1 MS_LOOP_LIMIT_BUFFER=1 \
    MOCK_SCENARIO=usage-limit-once run_loop --max-cycles 1
  assert_eq "0" "$RC" "the issue completes after the wait, on its only cycle"
  assert_contains "$OUT" "Usage limit reached" "the limit is detected at the end of the log"
  assert_contains "$OUT" "no correction cycle is consumed" "the wait says it costs no cycle"
  assert_eq "2" "$(impl_sessions)" "the same issue is re-run in a fresh session after the reset"
  assert_eq "1" "$(prompt_files "$(state_dir)" 'cycle-')" "the re-run consumed no correction cycle: still a single implementation prompt"
  assert_not_contains "$OUT" "Correction cycle" "no correction cycle was entered"
}

# RF-20 with the zero-gates clause of RF-10, asserted as the three consequences
# it is — the warning lands before any engine session, the issue is recorded
# `unverified` and never `done`, and the run exits non-zero — plus the fourth
# that follows from `unverified` not being `done`: the next run executes the
# very same issue again, instead of skipping it as RF-12 would a `done` one.
case_gate_zero_gates_records_unverified_and_reruns() {
  single_fixture gate-zero-gates
  reset_engine_counters

  run_loop --no-verify
  assert_ne "0" "$RC" "with the suite gate unresolved and the verifier off, the run exits non-zero"
  assert_contains "$OUT" "NO MECHANICAL VALIDATION IS ACTIVE" "the zero-gates warning is printed"

  zgr_warn=$(grep -n "NO MECHANICAL VALIDATION IS ACTIVE" "$OUT" | head -1 | cut -d: -f1)
  zgr_session=$(grep -n "Slice 1: \[feat\] The only slice" "$OUT" | head -1 | cut -d: -f1)
  assert_ne "" "$zgr_session" "the issue really was executed, so the ordering below compares two real lines"
  assert_eq "1" "$([ "$zgr_warn" -lt "$zgr_session" ] && echo 1 || echo 0)" "the warning is printed before any engine invocation"

  assert_matches "$(state_dir)/progress.tsv" "^1${TAB}[0-9a-f]{64}${TAB}unverified${TAB}disabled${TAB}disabled${TAB}" \
    "the issue is recorded unverified, with both gate results recorded disabled"
  assert_eq "0" "$(grep -c "${TAB}done${TAB}" "$(state_dir)/progress.tsv")" "no issue of a zero-gates run is recorded done"
  assert_eq "1" "$(impl_sessions)" "the issue was executed all the same: zero gates never means zero work"

  reset_engine_counters
  run_loop --no-verify
  assert_ne "0" "$RC" "the following run exits non-zero too, for the same reason"
  assert_matches "$OUT" 'Slice 1 — unverified \(run\)' "the unverified issue is re-executed, never skipped"
  assert_contains "$OUT" "1 slice(s) to execute, 0 skipped" "RF-12 skips only done, so nothing of a zero-gates run is skipped"
  assert_eq "1" "$(impl_sessions)" "the re-execution is a fresh implementation session of its own"
}

# ---------------------------------------------------------------------------
# Cases — commits, session hygiene and exit codes (T18/T17: RF-09, RF-35, RF-34)
# ---------------------------------------------------------------------------

# RF-12: resume, driven end to end rather than seeded. The first run records
# every issue `done` by itself; the second reads that record, executes nothing
# and exits 0.
case_resume_two_consecutive_runs_are_idempotent() {
  standard_fixture resume-idempotent
  reset_engine_counters

  run_loop
  assert_eq "0" "$RC" "the first run completes"
  assert_eq "3" "$(grep -c "${TAB}done${TAB}" "$(state_dir)/progress.tsv")" "the first run records all three issues done, with nothing seeded"
  assert_eq "3" "$(impl_sessions)" "one implementation session per issue on the first run"

  reset_engine_counters
  run_loop
  assert_eq "0" "$RC" "the second consecutive run over the all-done record: exit 0"
  assert_contains "$OUT" "0 slice(s) to execute, 3 skipped" "every done issue is skipped"
  assert_contains "$OUT" "Skipping Slice 1" "the skip is reported per issue"
  assert_zero_engine_calls "second consecutive run over an all-done record"
}

# RF-27 / RNF-05: `gh` is optional to the loop, not merely tolerated. On a PATH
# where it does not exist at all, the whole run — selection, gates, commits and
# report — completes normally.
case_run_completes_with_gh_absent() {
  standard_fixture run-no-gh
  make_gh_free_bin
  reset_engine_counters
  rg_before=$(head_rev)

  RUN_PATH="$MOCK_BIN:$GH_FREE_BIN"
  rg_gh=$(PATH="$RUN_PATH" command -v gh 2> /dev/null)
  assert_eq "" "$rg_gh" "gh really is absent from the PATH the run uses"

  run_loop
  RUN_PATH=""
  assert_eq "0" "$RC" "a run with gh absent from PATH completes normally"
  assert_eq "3" "$(grep -c "${TAB}done${TAB}" "$(state_dir)/progress.tsv")" "every issue is recorded done"
  assert_eq "3" "$(new_commits_since "$rg_before")" "and each approved issue produced its commit"
  assert_contains "$OUT" "FINAL REPORT" "the run reaches its final report"
  assert_not_contains "$OUT" "command not found" "nothing on the path of the run reached for a missing binary"
}

case_commit_one_per_approved_issue() {
  standard_fixture commit-per-issue
  reset_engine_counters
  cp_before=$(head_rev)

  run_loop
  assert_eq "0" "$RC" "every issue approved: exit 0"
  assert_eq "3" "$(new_commits_since "$cp_before")" "exactly one new commit per approved issue"
  (cd "$FIX" && git log --format=%s "$cp_before..HEAD") > "$TMP/subjects.txt"
  assert_contains "$TMP/subjects.txt" "feat(issue-1): [feat] Foundation" "the commit subject carries the issue number and its title"
  assert_contains "$TMP/subjects.txt" "feat(issue-3): [feat] Third" "the last issue is committed under its own number"
  (cd "$FIX" && git show --stat --format= HEAD) > "$TMP/last-commit.txt"
  assert_contains "$TMP/last-commit.txt" "impl-slice-3.txt" "the commit covers the work of that issue"
  assert_not_contains "$TMP/last-commit.txt" "impl-slice-1.txt" "and only of that issue"
}

# RF-35c: a commit exists only after the active gates went green. An issue that
# ran and failed leaves nothing in the history, and neither does one that never
# ran at all because it sits behind the failure.
case_commit_failed_and_blocked_produce_none() {
  graph_fixture commit-none \
    "1|A, the one that fails|nenhum|não publicada" \
    "2|B, behind the failure|Slice 1|não publicada"
  reset_engine_counters
  cn_before=$(head_rev)

  MOCK_SCENARIO=noop run_loop --max-cycles 1
  assert_ne "0" "$RC" "the failed issue makes the run exit non-zero"
  assert_matches "$(state_dir)/progress.tsv" "^1${TAB}[0-9a-f]{64}${TAB}failed${TAB}" "the executed issue is recorded failed"
  assert_matches "$(state_dir)/progress.tsv" "^2${TAB}[0-9a-f]{64}${TAB}blocked${TAB}" "the issue behind it is recorded blocked"
  assert_eq "0" "$(new_commits_since "$cn_before")" "neither a failed nor a blocked issue produces a commit"
  assert_eq "$cn_before" "$(head_rev)" "HEAD is exactly where it was before the run"
}

# RF-35d: green gates with a clean work tree means the issue was already
# implemented in HEAD. Done, no commit, and not a failure.
case_already_implemented_issue_leaves_head_untouched() {
  single_fixture already-implemented
  echo "already implemented" > "$FIX/impl-slice-1.txt"
  commit_fixture
  reset_engine_counters
  ai_before=$(head_rev)

  MOCK_SCENARIO=noop run_loop
  assert_eq "0" "$RC" "an issue already implemented in HEAD is not a failure"
  assert_contains "$OUT" "ALREADY IMPLEMENTED in HEAD" "the outcome is named"
  assert_eq "$ai_before" "$(head_rev)" "git rev-parse HEAD is identical to before the issue"
  assert_matches "$(state_dir)/progress.tsv" "^1${TAB}[0-9a-f]{64}${TAB}done${TAB}" "the issue is still recorded done"
}

# RF-09: N issues plus M correction cycles produce exactly N+M implementation
# sessions, each with its own prompt file, none reused. The verifier is itself
# an engine session and is counted separately.
case_sessions_are_never_reused() {
  standard_fixture session-hygiene
  reset_engine_counters

  MOCK_SCENARIO=green-cycle-2 run_loop
  assert_eq "0" "$RC" "three issues, one correction cycle each: exit 0"
  assert_eq "6" "$(impl_sessions)" "N=3 issues plus M=3 correction cycles is 6 implementation sessions"
  assert_eq "6" "$(prompt_files "$(state_dir)" 'cycle-')" "one implementation prompt file per session, none reused"
  assert_eq "6" "$(verify_sessions)" "the verifier sessions are counted separately from those"
  assert_eq "6" "$(prompt_files "$(state_dir)" 'verify-')" "and they have prompt files of their own"

  # Self-contained: a correction prompt carries the whole issue, because the
  # session that reads it has no memory of the one before it.
  assert_contains "$(state_dir)/prompts/slice-02.cycle-2.txt" "## Slice 2:" "the correction prompt carries the whole issue"
  assert_contains "$(state_dir)/prompts/slice-02.cycle-2.txt" "Discover the stack and the conventions" "and the stack-discovery preamble that assumes no language"
  assert_not_contains "$(state_dir)/prompts/slice-02.cycle-2.txt" "## Slice 1:" "and nothing of another issue"
}

# RF-34e, the full matrix: `failed` and `unverified` are the only two causes of
# a non-zero exit; `blocked` and `blocked-external` never are.
case_exit_code_matrix() {
  standard_fixture exit-matrix
  reset_engine_counters
  run_loop
  assert_eq "0" "$RC" "all green: exit 0"
  assert_contains "$OUT" "Run finished: every executed issue is recorded done." "the green run says so"

  single_fixture exit-matrix-failed
  reset_engine_counters
  MOCK_SCENARIO=noop run_loop --max-cycles 1
  assert_ne "0" "$RC" "some issue failed: non-zero"

  single_fixture exit-matrix-unverified
  reset_engine_counters
  run_loop --no-verify
  assert_ne "0" "$RC" "some issue unverified: non-zero"
  assert_contains "$OUT" "recorded 'unverified'" "the report names the cause of the non-zero exit"

  graph_fixture exit-matrix-external \
    "1|Ready|nenhum|não publicada" \
    "2|Waiting on the world|#999|não publicada"
  reset_engine_counters
  run_loop
  assert_eq "0" "$RC" "blocked-external as the only anomaly: exit 0"
  assert_contains "$OUT" "Externally blocked issues never change the exit code." "the report says the external block is not a failure"

  # The fourth outcome: `blocked`. It only ever arises behind something else,
  # and behind an external block there is no `failed` anywhere in the run — so
  # a run whose anomalies are `blocked` and `blocked-external` still exits 0.
  graph_fixture exit-matrix-blocked \
    "1|Ready|nenhum|não publicada" \
    "2|Waiting on the world|#999|não publicada" \
    "3|Behind the external block|Slice 2|não publicada"
  reset_engine_counters
  run_loop
  assert_eq "0" "$RC" "blocked and blocked-external as the only anomalies: exit 0"
  assert_matches "$(state_dir)/progress.tsv" "^3${TAB}[0-9a-f]{64}${TAB}blocked${TAB}" "the transitively blocked issue is recorded blocked"
  assert_eq "0" "$(grep -c "${TAB}failed${TAB}" "$(state_dir)/progress.tsv")" "and no issue of this run ended failed"
}

# UI-04 / RF-34: the final report groups every issue by state and points at the
# logs of each one.
case_final_report_groups_by_state() {
  graph_fixture report-groups \
    "1|Ready|nenhum|não publicada" \
    "2|Waiting on the world|#999|não publicada" \
    "3|Behind the external block|Slice 2|não publicada"
  reset_engine_counters

  run_loop
  assert_eq "0" "$RC" "the run exits 0"
  assert_contains "$OUT" "FINAL REPORT" "the run ends in a report"
  assert_matches "$OUT" "^done \(1\):" "the report groups the completed issues"
  assert_matches "$OUT" "^blocked \(1\):" "and the blocked ones"
  assert_matches "$OUT" "^blocked-external \(1\):" "and the externally blocked ones"
  assert_contains "$OUT" "logs: .spec/features/demo/.loop/logs/slice-01.*" "each line points at the logs of its issue"
}

# RNF-07: no credential file is ever read, and nothing that looks like one is
# ever written into a prompt or a log.
case_loop_never_reads_a_credential_file() {
  new_fixture no-dotenv
  grep -nE '\.env|API_KEY|SECRET|TOKEN|PASSWORD' "$LOOP" | grep -vE '^[0-9]+:[[:space:]]*#' > "$OUT" 2>&1
  assert_empty_file "$OUT" "loop.sh names a credential file or a secret variable nowhere but in the comment that forbids it"
}

# ---------------------------------------------------------------------------
# Repository sanity scripts — check-drift.sh and check-conformance.sh
#
# Both take the repository root as an optional argument, which is how the cases
# below prove they can go red: the versioned tree is copied into the fixture,
# one anchor is reworded or one violation is planted, and the script runs
# against the copy. The harness repository itself is never modified.
# ---------------------------------------------------------------------------

CHECK_DRIFT="$ROOT/scripts/check-drift.sh"
CHECK_CONFORMANCE="$ROOT/scripts/check-conformance.sh"

# copy_versioned_tree <dest> — the tracked files of the harness repository, and
# nothing else. The copy carries no .git, so check-conformance.sh exercises its
# non-git fallback and sees the planted file the way CI would see a new one.
copy_versioned_tree() {
  cvt_dest=$1
  mkdir -p "$cvt_dest"
  ( cd "$ROOT" && git ls-files ) | while IFS= read -r cvt_f; do
    [ -n "$cvt_f" ] || continue
    mkdir -p "$cvt_dest/$(dirname "$cvt_f")"
    cp "$ROOT/$cvt_f" "$cvt_dest/$cvt_f"
  done
}

case_drift_pristine_tree_is_in_sync() {
  new_fixture drift-pristine
  "$CHECK_DRIFT" "$ROOT" > "$OUT" 2>&1
  RC=$?
  assert_eq "0" "$RC" "check-drift.sh exits 0 on the intact tree"
  assert_contains "$OUT" "every duplicated rule and contract literal is in sync" "and says so"
}

# The four anchor groups exist and cover the files the contract names.
case_drift_anchor_groups_cover_the_listed_files() {
  new_fixture drift-groups
  assert_contains "$CHECK_DRIFT" "(a) shared init rules" "group (a) — shared init rules"
  assert_contains "$CHECK_DRIFT" "(b) CT-07 verifier protocol" "group (b) — CT-07 protocol"
  assert_contains "$CHECK_DRIFT" "(c) CT-01 field literals" "group (c) — CT-01 fields"
  assert_contains "$CHECK_DRIFT" "(d) CT-02 heading literals" "group (d) — CT-02 headings"

  # Group (a) binds the four chain commands plus the router.
  for f in commands/init/project-description.md commands/init/user-stories.md \
    commands/init/database-schema.md commands/init/project-issues.md commands/init.md; do
    assert_contains "$CHECK_DRIFT" "$f" "group (a) names $f"
  done

  # Groups (b), (c) and (d) bind the verifier, the issuer and the loop.
  assert_contains "$CHECK_DRIFT" "agents/issue-verifier.md" "the verifier agent is anchored"
  assert_contains "$CHECK_DRIFT" "agents/issuer.md" "the issuer agent is anchored"
  assert_contains "$CHECK_DRIFT" "scripts/loop.sh" "the loop is anchored"

  # The CT-01 field literals and the CT-02 headings are anchors, not prose.
  assert_contains "$CHECK_DRIFT" 'check '"'"'- **Blocked by**:'"'"'' "the blocking field is an anchor"
  assert_contains "$CHECK_DRIFT" 'check '"'"'- **Demoável por**:'"'"'' "the demo field is an anchor"
  assert_contains "$CHECK_DRIFT" 'check '"'"'- **Issue**:'"'"'' "the published-number field is an anchor"
  assert_contains "$CHECK_DRIFT" 'check '"'"'## Critérios de aceite'"'"'' "the acceptance-criteria heading is an anchor"
}

# Rewording one copy of an anchor makes the check go red, naming both the file
# that drifted and the anchor it lost.
case_drift_reworded_anchor_goes_red() {
  new_fixture drift-reworded
  copy_versioned_tree "$FIX/tree"

  sed 's/- When in doubt, INCOMPLETE\./- When unsure, INCOMPLETE./' \
    "$FIX/tree/agents/issue-verifier.md" > "$FIX/reworded.md"
  mv "$FIX/reworded.md" "$FIX/tree/agents/issue-verifier.md"

  "$CHECK_DRIFT" "$FIX/tree" > "$OUT" 2>&1
  RC=$?
  assert_ne "0" "$RC" "a reworded anchor copy exits non-zero"
  assert_contains "$OUT" "DRIFT: missing in agents/issue-verifier.md" "the drifted file is named"
  assert_contains "$OUT" "- When in doubt, INCOMPLETE." "the missing anchor is quoted"
}

case_conformance_finished_tree_passes() {
  new_fixture conformance-clean
  "$CHECK_CONFORMANCE" "$ROOT" > "$OUT" 2>&1
  RC=$?
  assert_eq "0" "$RC" "check-conformance.sh exits 0 on the finished tree"
  for ac in AC-01 AC-02 AC-03 AC-04 AC-05 AC-06 AC-07; do
    assert_contains "$OUT" "== $ac" "$ac has its own labelled block"
  done
  assert_contains "$OUT" "does not match AGENTS.md" "the namespace check proves it ignores foreign names"
}

# The planted violation of the acceptance criterion: a file under scripts/
# carrying the name of the container wrapper the harness removed. Assembled at
# run time, so this suite does not carry the literal it plants.
case_conformance_planted_violation_goes_red() {
  new_fixture conformance-planted
  copy_versioned_tree "$FIX/tree"

  planted='sa''il'
  {
    echo '#!/usr/bin/env bash'
    echo "# a stack-coupled helper: $planted test"
  } > "$FIX/tree/scripts/offender.sh"

  "$CHECK_CONFORMANCE" "$FIX/tree" > "$OUT" 2>&1
  RC=$?
  assert_ne "0" "$RC" "a planted stack coupling under scripts/ exits non-zero"
  assert_contains "$OUT" "== AC-03" "the failure is reported under AC-03"
  assert_contains "$OUT" "scripts/offender.sh" "the offending file is named"

  # Removing the plant makes the same copy green again, so the red above is the
  # plant and not the copy.
  rm -f "$FIX/tree/scripts/offender.sh"
  "$CHECK_CONFORMANCE" "$FIX/tree" > "$OUT" 2>&1
  RC=$?
  assert_eq "0" "$RC" "the same copy without the plant exits 0"
}

# The exclusion set is a literal in the header, it is closed, and AC-06 stops
# at commands/ and agents/ — scripts/ is where the loop's git writes live.
case_conformance_exclusion_set_and_ac06_scope() {
  new_fixture conformance-scope
  for entry in '.git/' '.spec/' 'scripts/check-conformance.sh' 'README.md' 'CHANGELOG.md' 'LICENSE'; do
    assert_contains "$CHECK_CONFORMANCE" "#   $entry" "the header names the exclusion '$entry'"
  done
  assert_contains "$CHECK_CONFORMANCE" "Nothing else is excluded." "the exclusion set is declared closed"

  # The runtime filter applies exactly those five and nothing more.
  grep -n 'continue ;;' "$CHECK_CONFORMANCE" | grep -F '.git/*' > "$OUT" 2>&1
  assert_contains "$OUT" '.git/* | .spec/* | "$SELF" | README.md | CHANGELOG.md | LICENSE' \
    "the filter excludes exactly the named set"

  assert_contains "$CHECK_CONFORMANCE" 'commands/* | agents/*' "AC-06 is scoped to commands/ and agents/"
  assert_contains "$CHECK_CONFORMANCE" "AC-06 does not cover scripts/" "AC-06 states that scripts/ is out of its scope"

  # And the loop really does perform the git write AC-06 refuses to forbid.
  grep -c 'git commit' "$LOOP" > "$OUT" 2>&1
  assert_ne "0" "$(cat "$OUT")" "the loop commits, which is why AC-06 stops before scripts/"
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

CASES="
case_harness_mocks_shadow_real_engines
case_shell_audit_rejects_bash4_construct
case_loop_has_no_associative_array
case_harness_run_leaks_nothing_outside_the_temp_dir
case_harness_patched_loop_proves_the_suite_can_go_red
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
case_graph_keep_going_runs_an_independent_branch
case_graph_prose_heading_is_not_a_parsing_source
case_gate_engine_exit_zero_without_writing_fails_the_issue
case_gate_red_suite_fails_then_the_correction_cycle_makes_one_commit
case_gate_verifier_session_is_read_only
case_gate_verifier_count_divergence_is_red
case_gate_verifier_zero_parsed_lines_is_red
case_gate_verifier_incomplete_then_done
case_usage_limit_waits_and_reruns_the_same_issue
case_gate_zero_gates_records_unverified_and_reruns
case_resume_two_consecutive_runs_are_idempotent
case_run_completes_with_gh_absent
case_commit_one_per_approved_issue
case_commit_failed_and_blocked_produce_none
case_already_implemented_issue_leaves_head_untouched
case_sessions_are_never_reused
case_exit_code_matrix
case_final_report_groups_by_state
case_loop_never_reads_a_credential_file
case_drift_pristine_tree_is_in_sync
case_drift_anchor_groups_cover_the_listed_files
case_drift_reworded_anchor_goes_red
case_conformance_finished_tree_passes
case_conformance_planted_violation_goes_red
case_conformance_exclusion_set_and_ac06_scope
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

reset_engine_counters

echo
echo "engine sessions, counted separately — implementation: $TOTAL_IMPL, verifier: $TOTAL_VERIFY"
echo "passed: $PASS   failed: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
