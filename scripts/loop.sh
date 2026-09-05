#!/usr/bin/env bash
#
# loop.sh — the issue-driven AFK execution loop of ms-harness.
#
# It reads an issue document, splits it into one self-contained slice per issue
# and drives each slice through a fresh engine session gated by mechanical
# checks. The unit of work is the ISSUE (a vertical slice), never a phase.
#
# Invariants:
#   1. Every issue AND every correction cycle runs in a FRESH engine session,
#      with a self-contained prompt. A session is never reused.
#   2. Zero questions. From start to finish, without human interaction.
#   3. An issue is only complete when every ACTIVE mechanical gate is green.
#      The engine exit code is never a completion verdict, on any path.
#   4. Usage limit -> wait for the reset and re-run the SAME issue, without
#      consuming a correction cycle.
#   5. One commit per completed issue, created only after the gates are green.
#
# Stack-agnostic: the issue body and the consumer project's own AGENTS.md /
# CLAUDE.md define language, framework, commands and conventions. No language,
# framework, runtime or package manager is named as control flow anywhere in
# this script; the only place such names may appear is the data rows of
# scripts/test-commands.conf.
#
# Usage:
#   scripts/loop.sh [options] [path-to-issue-document]
#
# Options:
#   --engine codex|claude    implementation engine (default: codex)
#   --test-cmd "<cmd>"       the consumer project's test command (suite gate)
#   --max-cycles N           correction cycles per issue (default: 3)
#   --no-verify              disable the verifier gate (= MS_LOOP_VERIFY=off)
#   --keep-going             keep going after an issue fails (default: stop)
#   --only-slice N           restrict the run to a single slice number
#   -h, --help               print this header
#
# Environment variables:
#   MS_LOOP_TEST_CMD         test command for the suite gate; --test-cmd wins
#   MS_LOOP_VERIFY           verifier gate: always (default) | auto | off
#   MS_LOOP_MAX_CYCLES       correction cycles per issue (default: 3)
#   MS_LOOP_MAX_LIMIT_WAITS  consecutive usage-limit waits per issue (def: 20)
#   MS_LOOP_VERIFY_MODEL     model of the verifier session (claude: haiku)
#   MS_LOOP_LIMIT_WAIT_DEFAULT  usage-limit wait, in seconds, when the engine
#                            announces no reset time (default: 1800)
#   MS_LOOP_LIMIT_BUFFER     seconds added after an announced reset (def: 60)
#   MS_LOOP_LABEL            triage label used when publishing issues
#                            (default: ready-for-agent)
#
# Exported for the consumer project's own hooks, one value per issue:
#   MS_LOOP_ISSUE_NUM  MS_LOOP_ISSUE_TITLE  MS_LOOP_ISSUE_TOTAL
#   MS_LOOP_ISSUE_ATTEMPT  MS_LOOP_ENGINE  MS_LOOP_LABEL
#   No secret, token or connection string is ever exported, written into a
#   prompt or written into a log, and no .env file is ever read.
#
# Gates, in the order they run. The engine exit code is NEVER a verdict of
# completion on any path:
#   1. the engine session finished at all (is_error on claude, exit code on
#      codex) — a signal about the run, never about the work
#   2. the tree signature, a SIGNAL of "did this session write?" — an issue
#      already implemented in HEAD correctly produces no write
#   3. SUITE GATE — the resolved test command, run by the loop OUTSIDE the
#      agent session with stdin redirected, its real output captured as the
#      cause fed to the next correction cycle
#   4. VERIFIER GATE — a fresh, read-only engine session judging the issue's
#      `## Critérios de aceite` checkboxes one by one under CT-07: one
#      `CRITERION <n>: DONE|INCOMPLETE — <evidence>` line per checkbox. Red
#      when nothing parses, when the line count differs from the checkbox
#      count (anti-gaming, red even when every line says DONE), or when any
#      line is INCOMPLETE.
#
# Outcome of an issue, and the exit code of the run:
#   every ACTIVE gate green            -> `done`, exactly one commit,
#                                         `feat(issue-<N>): <title>`, created
#                                         only AFTER the gates went green
#   every active gate green, tree clean-> `done` with NO commit: the issue was
#                                         already implemented in HEAD
#   ZERO active gate                   -> still executed, still committed, but
#                                         recorded `unverified`, never `done`
#   correction cycles exhausted        -> `failed`, never a commit
#   The run exits non-zero IF AND ONLY IF some issue ended `failed` or some
#   issue ended `unverified`. `blocked`, `blocked-external` and a skipped
#   publication never change the exit code.
#
# Input resolution — the first rule that resolves wins:
#   1. the positional argument
#   2. exactly one .spec/features/*/ISSUES.md
#   3. the init chain issue artifact, .spec/init/project-issues.md
#
#   Two or more candidates tied at the same level abort the run, printing every
#   candidate found: the loop never asks and never picks one by itself. No
#   candidate at all aborts naming every location that was searched.
#
# Slice metadata fields of the input document, written before the `### Corpo`
# marker in this order: `- **Issue**:`, `- **Tasks**:`, `- **Cobre**:`,
# `- **Blocked by**:`, `- **Demoável por**:`. The loop parses two of them —
# `- **Blocked by**:` for the dependency graph and `- **Issue**:` for the
# published number, which is excluded from the hashed body. The rest travel
# with the slice into the engine prompt untouched.
#
# Input format contract, validated in preflight before any engine session:
#   - at least one `## Slice <N>: <title>` heading
#   - no malformed `## Slice ...` heading and no repeated slice number
#   - every `- **Blocked by**:` field inside the grammar
#         nenhum | comma-separated list of `Slice <N>` and/or `#<n>`
#   - the `- **Blocked by**:` graph is acyclic
#   Any violation aborts the preflight quoting the offending line. Every
#   preflight abort exits non-zero with zero engine invocations.
#
#   `- **Blocked by**:` is the single parsed source of the dependency graph.
#   The `## Bloqueado por` heading of an issue body is prose for the developer
#   and is never parsed; a divergence between the two is not a format error.
#
# Dependency graph and selection. Readiness is decided from the input document
# and the progress record alone: while an unfinished slice remains, the loop
# takes the next one, in topological order, whose blockers are every one of
# them recorded `done`. GitHub is never consulted to decide readiness, so the
# loop behaves identically with `gh` absent from PATH. A `#<n>` blocker that
# matches no slice of this same document is an EXTERNAL block: that slice is
# never selected, is recorded and reported `blocked-external`, and never makes
# the run fail. Every slice downstream of a slice that can no longer complete —
# one that ended `failed`, one blocked externally — is marked `blocked`
# TRANSITIVELY, with zero engine sessions for any of them.
#
# Suite gate command, resolved by a fixed precedence, first rule that resolves:
#   1. the --test-cmd flag
#   2. the MS_LOOP_TEST_CMD environment variable
#   3. the `test_cmd=` key of .ms-harness.conf in the invocation directory
#   4. the fallback table scripts/test-commands.conf, probing ONLY the
#      invocation directory — no recursive scan, no walk up to a parent
#   5. nothing resolved -> loud warning and the suite gate is DISABLED
#
#   The loop NEVER aborts over an unresolved test command: it degrades onto the
#   verifier gate and says so. More than one fallback-table rule matching is
#   the same degradation — it warns, lists every matched candidate and disables
#   the gate, because picking one would let the table's order impose a
#   precedence between stacks that the table exists to not have.
#
#   Levels 3 and 4 are data files, never code. No language, framework, runtime
#   or package manager is named as a branch anywhere in this script.
#
# Slice capture. A slice opens at its `## Slice <N>: ` heading and carries its
# metadata fields, its `### Corpo` marker and the whole issue body. Capture
# closes at the next `## Slice <N>: ` heading, at end of file, or at a level-2
# heading that is a sibling document section — that is, one seen before the
# slice opened its `### Corpo` body, or one introduced by a `---` thematic
# break. Level-3 and deeper headings always stay inside the slice. The body
# rule exists because an issue body is itself written with level-2 headings
# (`## Contexto`, `## Critérios de aceite`, ...): closing capture on the first
# one of those would truncate every issue to its metadata block.
#
# State. Everything the loop writes lives under the input document's own
# directory, never at the consumer project root:
#   .spec/features/<slug>/ISSUES.md   ->  .spec/features/<slug>/.loop/
#   .spec/init/project-issues.md      ->  .spec/init/.loop/
#     <state-dir>/slices/slice-NN.md  one self-contained file per slice
#     <state-dir>/manifest.txt        slice-NN.md|<N>|<title>|<hash>|<blocked>
#     <state-dir>/progress.tsv        the progress record (see below)
#     <state-dir>/logs/               one log per engine session
#     <state-dir>/prompts/            one prompt per engine session
# The state directory is neutralised through .git/info/exclude, idempotently.
# The consumer project's .gitignore is never touched. The input document is
# never rewritten and nothing is ever written outside .spec/.
#
# Progress record, <state-dir>/progress.tsv, one tab-separated line per slice:
#   <slice number>  <body hash>  <state>  <suite gate>  <verifier gate>  <cause>
# States: done | unverified | failed | blocked | blocked-external
# Gates:  passed | failed | disabled
# The lookup key is COMPOSITE — slice number plus the hash of that slice's body
# alone. An entry whose recorded hash differs from the current one is dropped
# for THAT slice only, never globally: publishing writes `- **Issue**: #<n>`
# back into the input document between runs, and a whole-file hash would
# silently zero all progress. That published field is therefore excluded from
# the hashed body. Only `done` is skipped on a re-run; `unverified`, `failed`
# and `blocked` are always re-executed.
#
# Portability. Supported hosts are Linux and macOS as they ship, so the script
# stays inside bash 3.2 and a BSD userland: no associative arrays, no bash-4
# array-reading builtins, no bash-4 case expansions and no GNU-only date
# arithmetic. Hashing goes through hash_file(), which accepts either
# `sha256sum` or `shasum -a 256`. scripts/check-shell.sh audits all of it.
#
# Requirements:
#   - bash, coreutils and the chosen engine CLI
#   - git, mandatory: it is a named precondition and never degrades
#   - `gh` and `jq` are optional and never required by this script
#
set -euo pipefail

ENGINE="codex"
INPUT_FILE=""
INPUT_RULE=""
TEST_CMD_FLAG=""
KEEP_GOING=false
ONLY_SLICE=""
MAX_CYCLES="${MS_LOOP_MAX_CYCLES:-3}"
VERIFY_MODE="${MS_LOOP_VERIFY:-always}"
MAX_LIMIT_WAITS="${MS_LOOP_MAX_LIMIT_WAITS:-20}"

# Triage label used by the optional publication step; exported so an engine
# session and any consumer hook see the same value the loop resolved.
MS_LOOP_LABEL="${MS_LOOP_LABEL:-ready-for-agent}"
export MS_LOOP_LABEL

TAB=$(printf '\t')

# The fallback table ships with the harness, so it is resolved from the script,
# never from the invocation directory. The declarative config belongs to the
# consumer project and is therefore read from the invocation directory.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
FALLBACK_TABLE="$SCRIPT_DIR/test-commands.conf"
CONSUMER_CONF=".ms-harness.conf"

usage() {
  awk 'NR > 1 && /^#/ { sub(/^#[[:space:]]?/, ""); print; next } NR > 1 { exit }' "$0"
}

need_arg() {
  if [ "$2" -lt 2 ]; then
    echo "Option $1 expects a value." >&2
    exit 2
  fi
}

# shellcheck disable=SC2034  # TEST_CMD_FLAG feeds the suite-gate resolution
# chain and KEEP_GOING the failure policy of the run; both are read downstream.
while [ $# -gt 0 ]; do
  case "$1" in
    --engine)       need_arg "$1" "$#"; ENGINE="$2"; shift 2 ;;
    --engine=*)     ENGINE="${1#*=}"; shift ;;
    --test-cmd)     need_arg "$1" "$#"; TEST_CMD_FLAG="$2"; shift 2 ;;
    --test-cmd=*)   TEST_CMD_FLAG="${1#*=}"; shift ;;
    --max-cycles)   need_arg "$1" "$#"; MAX_CYCLES="$2"; shift 2 ;;
    --max-cycles=*) MAX_CYCLES="${1#*=}"; shift ;;
    --only-slice)   need_arg "$1" "$#"; ONLY_SLICE="$2"; shift 2 ;;
    --only-slice=*) ONLY_SLICE="${1#*=}"; shift ;;
    --no-verify)    VERIFY_MODE="off"; shift ;;
    --keep-going)   KEEP_GOING=true; shift ;;
    -h|--help)      usage; exit 0 ;;
    --*)            echo "Unknown option: $1" >&2; echo "Run 'loop.sh --help'." >&2; exit 2 ;;
    *)              INPUT_FILE="$1"; shift ;;
  esac
done

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

stamp()   { date '+%H:%M:%S'; }
log()     { printf '%b[%s]%b %s\n' "$BLUE" "$(stamp)" "$NC" "$1"; }
success() { printf '%b[%s] %s%b\n' "$GREEN" "$(stamp)" "$1" "$NC"; }
warn()    { printf '%b[%s] %s%b\n' "$YELLOW" "$(stamp)" "$1" "$NC"; }
fail()    { printf '%b[%s] %s%b\n' "$RED" "$(stamp)" "$1" "$NC" >&2; }

# ---------------------------------------------------------------------------
# Portable helpers (bash 3.2 / BSD userland)
# ---------------------------------------------------------------------------

# Hash of a file. Linux ships sha256sum, macOS ships shasum; the loop needs one
# of the two and says so plainly when neither is reachable.
hash_file() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum > /dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    fail "Neither 'sha256sum' nor 'shasum' is on PATH."
    fail "The progress record is keyed on a content hash and cannot be built without one."
    exit 1
  fi
}

# Elapsed seconds -> human duration. Plain arithmetic, because `date -d` is
# GNU-only and absent on macOS.
format_duration() {
  fd_total=$1
  fd_h=$((fd_total / 3600))
  fd_m=$(((fd_total % 3600) / 60))
  fd_s=$((fd_total % 60))
  if [ "$fd_h" -gt 0 ]; then
    printf '%dh %dm %ds' "$fd_h" "$fd_m" "$fd_s"
  elif [ "$fd_m" -gt 0 ]; then
    printf '%dm %ds' "$fd_m" "$fd_s"
  else
    printf '%ds' "$fd_s"
  fi
}

trim() {
  t_value="$1"
  t_value="${t_value#"${t_value%%[![:space:]]*}"}"
  t_value="${t_value%"${t_value##*[![:space:]]}"}"
  printf '%s' "$t_value"
}

is_positive_int() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
    *) [ "$1" -ge 1 ] ;;
  esac
}

# Membership test over a space-separated list; the bash 3.2 stand-in for a set.
in_list() {
  il_needle="$1"
  il_list="$2"
  case " $il_list " in
    *" $il_needle "*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Preconditions (RF-35 a, b) — each one with its own message, all of them
# checked before a single engine session exists.
# ---------------------------------------------------------------------------

require_git_worktree() {
  if ! command -v git > /dev/null 2>&1; then
    fail "Precondition not met: 'git' is not on PATH."
    fail "git is a mandatory dependency of the loop, which commits one commit per completed issue."
    fail "Install git and run again. This precondition never degrades."
    exit 1
  fi

  if [ "$(git rev-parse --is-inside-work-tree 2> /dev/null || true)" != "true" ]; then
    fail "Precondition not met: not inside a git work tree ($(pwd))."
    fail "The loop commits one commit per completed issue, so it refuses to run outside a repository."
    fail "Run 'git init' at the project root, or invoke the loop from inside the repository."
    exit 1
  fi
}

require_clean_worktree() {
  rcw_dirty=$(git status --porcelain)
  if [ -n "$rcw_dirty" ]; then
    fail "Precondition not met: the work tree is dirty."
    fail "The loop commits one commit per completed issue and would swallow these paths:"
    printf '%s\n' "$rcw_dirty" | sed 's/^/    /' >&2
    fail "Commit or stash them before running."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Input resolution (RF-32, CT-05)
# ---------------------------------------------------------------------------

FEATURE_GLOB='.spec/features/*/ISSUES.md'
INIT_ARTIFACT='.spec/init/project-issues.md'

# Candidates of one ladder level, one path per line. Never sorted into a
# preference: the caller aborts on more than one.
collect_candidates() {
  cc_out=""
  for cc_path in $1; do
    [ -f "$cc_path" ] || continue
    cc_out="$cc_out$cc_path
"
  done
  printf '%s' "$cc_out"
}

count_lines() {
  cl_value="$1"
  [ -n "$cl_value" ] || { printf '0'; return 0; }
  printf '%s' "$cl_value" | grep -c '' | tr -d ' '
}

abort_on_tie() {
  aot_level="$1"
  aot_candidates="$2"
  fail "Ambiguous input: $aot_level resolved to more than one document."
  printf '%s\n' "$aot_candidates" | sed '/^$/d; s/^/    /' >&2
  fail "The loop never asks and never picks one by itself. Pass the intended document as an argument:"
  fail "    loop.sh <path-to-issue-document>"
  exit 1
}

resolve_input_file() {
  if [ -n "$INPUT_FILE" ]; then
    INPUT_FILE="${INPUT_FILE#./}"
    if [ ! -f "$INPUT_FILE" ]; then
      fail "Input document not found: $INPUT_FILE"
      exit 1
    fi
    INPUT_RULE="positional argument"
    return 0
  fi

  rif_candidates=$(collect_candidates "$FEATURE_GLOB")
  rif_count=$(count_lines "$rif_candidates")
  if [ "$rif_count" -gt 1 ]; then
    abort_on_tie "$FEATURE_GLOB" "$rif_candidates"
  fi
  if [ "$rif_count" -eq 1 ]; then
    INPUT_FILE=$(printf '%s' "$rif_candidates" | sed '/^$/d')
    INPUT_RULE="the single $FEATURE_GLOB"
    return 0
  fi

  rif_candidates=$(collect_candidates "$INIT_ARTIFACT")
  rif_count=$(count_lines "$rif_candidates")
  if [ "$rif_count" -gt 1 ]; then
    abort_on_tie "$INIT_ARTIFACT" "$rif_candidates"
  fi
  if [ "$rif_count" -eq 1 ]; then
    INPUT_FILE="$INIT_ARTIFACT"
    INPUT_RULE="the init chain artifact $INIT_ARTIFACT"
    return 0
  fi

  fail "No issue document found. Searched, in this order:"
  fail "    1. the positional argument            (none given)"
  fail "    2. $FEATURE_GLOB     (no match)"
  fail "    3. $INIT_ARTIFACT          (absent)"
  fail "Pass the document as an argument, or run the planning pipeline first."
  exit 1
}

# ---------------------------------------------------------------------------
# Format validation (CT-05) + the slice index every later stage reads
#
# SLICE_INDEX holds one record per slice:
#   <number>|<heading line no>|<issue field>|<blocked line no>|<blocked raw>|<title>
# The title comes last so a '|' inside it cannot shift any other field.
# ---------------------------------------------------------------------------

SLICE_INDEX=""
SLICE_COUNT=0

# $1 = what is wrong, $2 = the offending lines (may be empty), one per line,
# each already prefixed with its line number in the input document.
abort_format() {
  fail "Input format contract violated in $INPUT_FILE:"
  fail "    $1"
  if [ -n "${2:-}" ]; then
    printf '%s\n' "$2" | sed '/^$/d; s/^/        /' >&2
  fi
  fail "A slice the loop cannot parse is a slice that silently disappears from the run."
  fail "Fix the document before spending tokens."
  exit 1
}

# `nenhum` or a comma-separated list of `Slice <N>` and/or `#<n>` (RF-11).
blocked_by_is_valid() {
  bbv_value=$(trim "$1")
  [ "$bbv_value" = "nenhum" ] && return 0
  [ -n "$bbv_value" ] || return 1

  bbv_rest="$bbv_value"
  while [ -n "$bbv_rest" ]; do
    bbv_item="${bbv_rest%%,*}"
    if [ "$bbv_item" = "$bbv_rest" ]; then
      bbv_rest=""
    else
      bbv_rest="${bbv_rest#*,}"
      [ -n "$bbv_rest" ] || return 1
    fi
    bbv_item=$(trim "$bbv_item")
    case "$bbv_item" in
      'Slice '*)
        bbv_num="${bbv_item#Slice }"
        is_positive_int "$bbv_num" || return 1
        ;;
      '#'*)
        bbv_num="${bbv_item#\#}"
        is_positive_int "$bbv_num" || return 1
        ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# Blockers of a slice expressed as slice numbers. `Slice <N>` maps directly;
# `#<n>` maps to the slice carrying that issue number, and is an EXTERNAL block
# (no edge) when no slice of this same document carries it.
blockers_as_slice_numbers() {
  basn_raw=$(trim "$1")
  basn_out=""
  [ "$basn_raw" = "nenhum" ] && return 0

  basn_rest="$basn_raw"
  while [ -n "$basn_rest" ]; do
    basn_item="${basn_rest%%,*}"
    if [ "$basn_item" = "$basn_rest" ]; then
      basn_rest=""
    else
      basn_rest="${basn_rest#*,}"
    fi
    basn_item=$(trim "$basn_item")
    case "$basn_item" in
      'Slice '*) basn_out="$basn_out ${basn_item#Slice }" ;;
      '#'*)
        basn_target=$(slice_number_for_issue "${basn_item#\#}")
        [ -n "$basn_target" ] && basn_out="$basn_out $basn_target"
        ;;
    esac
  done
  printf '%s' "$(trim "$basn_out")"
}

slice_number_for_issue() {
  snfi_issue="$1"
  # shellcheck disable=SC2034  # positional fields of the record; a reader
  # only uses the ones it needs, but every field has to be named to be skipped.
  while IFS='|' read -r snfi_num snfi_head snfi_field snfi_bline snfi_braw snfi_title; do
    [ -n "$snfi_num" ] || continue
    if [ "$snfi_field" = "#$snfi_issue" ]; then
      printf '%s' "$snfi_num"
      return 0
    fi
  done <<EOF
$SLICE_INDEX
EOF
  return 0
}

scan_input() {
  si_line_no=0
  si_current=""
  si_head_line=0
  si_issue="-"
  si_blocked_line=0
  si_blocked="nenhum"
  si_title=""
  si_body_open=false
  si_seen_numbers=""
  si_malformed=""
  si_bad_grammar=""
  si_duplicates=""

  SLICE_INDEX=""
  SLICE_COUNT=0

  while IFS= read -r si_raw || [ -n "$si_raw" ]; do
    si_line_no=$((si_line_no + 1))

    if [[ "$si_raw" =~ ^##[[:space:]]Slice[[:space:]]([0-9]+):[[:space:]](.*)$ ]]; then
      flush_slice
      si_current="${BASH_REMATCH[1]}"
      si_title=$(trim "${BASH_REMATCH[2]}")
      si_head_line=$si_line_no
      si_issue="-"
      si_blocked_line=0
      si_blocked="nenhum"
      si_body_open=false
      if in_list "$si_current" "$si_seen_numbers"; then
        si_duplicates="$si_duplicates$si_line_no: $si_raw
"
      fi
      si_seen_numbers="$si_seen_numbers $si_current"
      continue
    fi

    if [[ "$si_raw" =~ ^##[[:space:]]+Slice([^A-Za-z0-9]|$) ]]; then
      si_malformed="$si_malformed$si_line_no: $si_raw
"
      continue
    fi

    case "$si_raw" in
      '### Corpo'*) si_body_open=true ;;
    esac

    case "$si_raw" in
      '- **Blocked by**:'*)
        si_value=$(trim "${si_raw#- \*\*Blocked by\*\*:}")
        if ! blocked_by_is_valid "$si_value"; then
          si_bad_grammar="$si_bad_grammar$si_line_no: $si_raw
"
        elif [ -n "$si_current" ] && [ "$si_body_open" = false ] && [ "$si_blocked_line" -eq 0 ]; then
          si_blocked="$si_value"
          si_blocked_line=$si_line_no
        fi
        ;;
      '- **Issue**:'*)
        if [ -n "$si_current" ] && [ "$si_body_open" = false ] && [ "$si_issue" = "-" ]; then
          si_issue=$(trim "${si_raw#- \*\*Issue\*\*:}")
        fi
        ;;
    esac
  done < "$INPUT_FILE"
  flush_slice

  if [ "$SLICE_COUNT" -lt 1 ]; then
    abort_format "no '## Slice <N>: <title>' heading found — there is nothing to execute." ""
  fi

  if [ -n "$si_malformed" ]; then
    abort_format "malformed slice heading (expected '## Slice <N>: <title>'):" "$si_malformed"
  fi

  if [ -n "$si_duplicates" ]; then
    abort_format "repeated slice number:" "$si_duplicates"
  fi

  if [ -n "$si_bad_grammar" ]; then
    abort_format "'- **Blocked by**:' outside the grammar 'nenhum | comma-separated list of \"Slice <N>\" and/or \"#<n>\"':" "$si_bad_grammar"
  fi

  validate_acyclic
  log "Input format OK ($SLICE_COUNT slices declared, resolved by $INPUT_RULE)"
}

flush_slice() {
  [ -n "$si_current" ] || return 0
  SLICE_INDEX="$SLICE_INDEX$si_current|$si_head_line|$si_issue|$si_blocked_line|$si_blocked|$si_title
"
  SLICE_COUNT=$((SLICE_COUNT + 1))
  si_current=""
}

# Field <n> (1-based) of the SLICE_INDEX record of slice <number>.
slice_field() {
  sf_num="$1"
  sf_field="$2"
  while IFS='|' read -r sf_a sf_b sf_c sf_d sf_e sf_f; do
    [ -n "$sf_a" ] || continue
    [ "$sf_a" = "$sf_num" ] || continue
    case "$sf_field" in
      1) printf '%s' "$sf_a" ;;
      2) printf '%s' "$sf_b" ;;
      3) printf '%s' "$sf_c" ;;
      4) printf '%s' "$sf_d" ;;
      5) printf '%s' "$sf_e" ;;
      6) printf '%s' "$sf_f" ;;
    esac
    return 0
  done <<EOF
$SLICE_INDEX
EOF
  return 0
}

# ---------------------------------------------------------------------------
# State directory (RF-24, RF-33)
# ---------------------------------------------------------------------------

STATE_DIR=""
SLICES_DIR=""
LOG_DIR=""
PROMPT_DIR=""
MANIFEST=""
PROGRESS_FILE=""

resolve_state_dir() {
  rsd_dir=$(dirname "$INPUT_FILE")
  case "$rsd_dir" in
    .spec | .spec/*)
      STATE_DIR="$rsd_dir/.loop"
      ;;
    *)
      # Nothing the loop writes may leave .spec/ (RF-24), so an input document
      # kept elsewhere still gets its state parked under .spec/, keyed by a
      # slug built from its own path.
      rsd_slug=$(printf '%s' "$INPUT_FILE" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^-*//; s/-*$//')
      STATE_DIR=".spec/.loop/$rsd_slug"
      warn "Input document lives outside .spec/; loop state goes to $STATE_DIR (nothing is ever written outside .spec/)."
      ;;
  esac

  SLICES_DIR="$STATE_DIR/slices"
  LOG_DIR="$STATE_DIR/logs"
  PROMPT_DIR="$STATE_DIR/prompts"
  MANIFEST="$STATE_DIR/manifest.txt"
  PROGRESS_FILE="$STATE_DIR/progress.tsv"
}

# Idempotent, and deliberately in .git/info/exclude: the consumer project's
# .gitignore belongs to the consumer and the loop never edits it.
exclude_state_dir() {
  esd_git_dir=$(git rev-parse --git-dir)
  esd_prefix=$(git rev-parse --show-prefix)
  esd_file="$esd_git_dir/info/exclude"
  esd_entry="/${esd_prefix}${STATE_DIR}/"

  mkdir -p "$(dirname "$esd_file")"
  [ -f "$esd_file" ] || : > "$esd_file"

  if ! grep -qxF "$esd_entry" "$esd_file"; then
    printf '%s\n' "$esd_entry" >> "$esd_file"
    log "Registered $esd_entry in .git/info/exclude (the project .gitignore is left alone)"
  fi
}

# ---------------------------------------------------------------------------
# Slice split and run manifest (RF-33, CT-01)
# ---------------------------------------------------------------------------

slice_file_name() { printf 'slice-%02d.md' "$1"; }

# Drops trailing blank lines and a trailing `---` separator, so the thematic
# break that introduces the next document section never lands in a slice.
trim_trailing_rule() {
  ttr_file="$1"
  ttr_tmp="$ttr_file.tmp"
  ttr_pending=""
  : > "$ttr_tmp"
  while IFS= read -r ttr_line || [ -n "$ttr_line" ]; do
    if [ -z "$ttr_line" ] || [ "$ttr_line" = "---" ]; then
      ttr_pending="$ttr_pending$ttr_line
"
      continue
    fi
    if [ -n "$ttr_pending" ]; then
      printf '%s' "$ttr_pending" >> "$ttr_tmp"
      ttr_pending=""
    fi
    printf '%s\n' "$ttr_line" >> "$ttr_tmp"
  done < "$ttr_file"
  mv "$ttr_tmp" "$ttr_file"
}

close_slice_capture() {
  [ -n "$sp_file" ] || return 0
  trim_trailing_rule "$sp_file"
  sp_file=""
  sp_body_open=false
}

split_slices() {
  log "Splitting $INPUT_FILE into one file per slice..."

  rm -rf "$SLICES_DIR"
  mkdir -p "$SLICES_DIR" "$LOG_DIR" "$PROMPT_DIR"

  sp_file=""
  sp_body_open=false
  sp_prev_nonblank=""
  sp_written=0

  while IFS= read -r sp_line || [ -n "$sp_line" ]; do
    if [[ "$sp_line" =~ ^##[[:space:]]Slice[[:space:]]([0-9]+):[[:space:]](.*)$ ]]; then
      close_slice_capture
      sp_file="$SLICES_DIR/$(slice_file_name "${BASH_REMATCH[1]}")"
      printf '%s\n' "$sp_line" > "$sp_file"
      sp_written=$((sp_written + 1))
      sp_body_open=false
      sp_prev_nonblank="$sp_line"
      continue
    fi

    if [ -n "$sp_file" ]; then
      case "$sp_line" in
        '### Corpo'*) sp_body_open=true ;;
      esac

      case "$sp_line" in
        '## '*)
          # A level-2 heading closes capture when it is a sibling document
          # section: either the slice has not opened its `### Corpo` body yet,
          # or a `---` thematic break introduced it. Inside the body it is an
          # issue-body heading (CT-02) and stays.
          if [ "$sp_body_open" = false ] || [ "$sp_prev_nonblank" = "---" ]; then
            close_slice_capture
            sp_prev_nonblank="$sp_line"
            continue
          fi
          ;;
      esac

      printf '%s\n' "$sp_line" >> "$sp_file"
    fi

    if [ -n "$sp_line" ]; then
      sp_prev_nonblank="$sp_line"
    fi
  done < "$INPUT_FILE"
  close_slice_capture

  write_manifest
  success "$sp_written slices extracted into $SLICES_DIR"
}

# The hashed body of a slice is its file minus the `- **Issue**:` field, which
# is exactly what publication rewrites between runs. Excluding it is what keeps
# publishing from invalidating progress (RF-33).
hash_slice_body() {
  hsb_file="$1"
  hsb_tmp="$STATE_DIR/.body.$$"
  grep -v '^- \*\*Issue\*\*:' "$hsb_file" > "$hsb_tmp" || true
  hsb_hash=$(hash_file "$hsb_tmp")
  rm -f "$hsb_tmp"
  printf '%s' "$hsb_hash"
}

write_manifest() {
  : > "$MANIFEST"
  # shellcheck disable=SC2034  # positional fields of the record; a reader
  # only uses the ones it needs, but every field has to be named to be skipped.
  while IFS='|' read -r wm_num wm_head wm_issue wm_bline wm_braw wm_title; do
    [ -n "$wm_num" ] || continue
    wm_file=$(slice_file_name "$wm_num")
    if [ ! -f "$SLICES_DIR/$wm_file" ]; then
      fail "Internal inconsistency: slice $wm_num was indexed but not written to $SLICES_DIR/$wm_file"
      exit 1
    fi
    wm_hash=$(hash_slice_body "$SLICES_DIR/$wm_file")
    printf '%s|%s|%s|%s|%s\n' "$wm_file" "$wm_num" "$wm_title" "$wm_hash" "$wm_braw" >> "$MANIFEST"
  done <<EOF
$SLICE_INDEX
EOF
}

manifest_entries() {
  [ -f "$MANIFEST" ] || return 0
  grep -v '^#' "$MANIFEST" || true
}

manifest_hash_for() {
  mhf_num="$1"
  # shellcheck disable=SC2034  # positional fields of the record; a reader
  # only uses the ones it needs, but every field has to be named to be skipped.
  while IFS='|' read -r mhf_file mhf_n mhf_title mhf_hash mhf_braw; do
    [ -n "$mhf_n" ] || continue
    if [ "$mhf_n" = "$mhf_num" ]; then
      printf '%s' "$mhf_hash"
      return 0
    fi
  done <<EOF
$(manifest_entries)
EOF
  return 0
}

# ---------------------------------------------------------------------------
# Progress record (CT-06, RF-12, RF-33)
#
# progress.tsv, one tab-separated line per slice:
#   <number>  <body hash>  <state>  <suite gate>  <verifier gate>  <cause>
# The lookup key is composite: a recorded hash that no longer matches drops
# THAT slice's entry and nothing else.
# ---------------------------------------------------------------------------

PROGRESS_STATES='done unverified failed blocked blocked-external'
PROGRESS_GATES='passed failed disabled'

# Field <index> (1-based) of the record of slice <number>, looked up on the
# COMPOSITE key: an entry whose recorded hash no longer matches simply does not
# answer, which is per-slice invalidation and never a global reset.
progress_field() {
  pf_num="$1"
  pf_hash="$2"
  pf_index="$3"
  [ -f "$PROGRESS_FILE" ] || return 0
  while IFS= read -r pf_line || [ -n "$pf_line" ]; do
    [ -n "$pf_line" ] || continue
    pf_rest="$pf_line"
    pf_f1="${pf_rest%%"$TAB"*}"; pf_rest="${pf_rest#*"$TAB"}"
    pf_f2="${pf_rest%%"$TAB"*}"; pf_rest="${pf_rest#*"$TAB"}"
    pf_f3="${pf_rest%%"$TAB"*}"; pf_rest="${pf_rest#*"$TAB"}"
    pf_f4="${pf_rest%%"$TAB"*}"; pf_rest="${pf_rest#*"$TAB"}"
    pf_f5="${pf_rest%%"$TAB"*}"; pf_f6="${pf_rest#*"$TAB"}"
    [ "$pf_f1" = "$pf_num" ] && [ "$pf_f2" = "$pf_hash" ] || continue
    case "$pf_index" in
      1) printf '%s' "$pf_f1" ;;
      2) printf '%s' "$pf_f2" ;;
      3) printf '%s' "$pf_f3" ;;
      4) printf '%s' "$pf_f4" ;;
      5) printf '%s' "$pf_f5" ;;
      6) printf '%s' "$pf_f6" ;;
    esac
    return 0
  done < "$PROGRESS_FILE"
  return 0
}

progress_state() { progress_field "$1" "$2" 3; }
progress_cause() { progress_field "$1" "$2" 6; }

progress_is_done() {
  [ "$(progress_state "$1" "$2")" = "done" ]
}

# Only `done` is skipped on a re-run. `unverified`, `failed`, `blocked` and
# `blocked-external` are always re-evaluated (RF-12, RF-34d).
progress_should_run() {
  ! progress_is_done "$1" "$2"
}

progress_put() {
  pp_num="$1"
  pp_hash="$2"
  pp_state="$3"
  pp_suite="$4"
  pp_verify="$5"
  pp_cause="${6:-}"

  if ! in_list "$pp_state" "$PROGRESS_STATES"; then
    fail "Internal error: '$pp_state' is not a progress state ($PROGRESS_STATES)."
    exit 1
  fi
  if ! in_list "$pp_suite" "$PROGRESS_GATES" || ! in_list "$pp_verify" "$PROGRESS_GATES"; then
    fail "Internal error: gate result must be one of: $PROGRESS_GATES."
    exit 1
  fi

  # Tabs and newlines are the record separators; a gate cause is free text.
  pp_cause=$(printf '%s' "$pp_cause" | tr '\t\n' '  ')

  mkdir -p "$STATE_DIR"
  pp_tmp="$PROGRESS_FILE.tmp"
  : > "$pp_tmp"
  if [ -f "$PROGRESS_FILE" ]; then
    while IFS= read -r pp_line || [ -n "$pp_line" ]; do
      [ -n "$pp_line" ] || continue
      if [ "${pp_line%%"$TAB"*}" = "$pp_num" ]; then continue; fi
      printf '%s\n' "$pp_line" >> "$pp_tmp"
    done < "$PROGRESS_FILE"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$pp_num" "$pp_hash" "$pp_state" "$pp_suite" "$pp_verify" "$pp_cause" >> "$pp_tmp"
  mv "$pp_tmp" "$PROGRESS_FILE"
}

# ---------------------------------------------------------------------------
# Suite gate command resolution (RF-16 to RF-20, UI-04)
#
# Five levels, first rule that resolves. Levels 3 and 4 are DATA: a `key=value`
# file owned by the consumer project and a table of `<probe> :: <command>` rows
# shipped with the harness. Both are walked by a plain read loop, so the set of
# languages, frameworks and package managers the harness knows about is exactly
# the set written in those two files — never a branch in this script (RF-18).
# ---------------------------------------------------------------------------

TEST_CMD=""
TEST_CMD_RULE=""
SUITE_GATE="disabled"

# Value of <key> in a `key=value` file, empty when the file or the key is
# absent. Blank lines and `#` comments are skipped, unknown keys are ignored,
# the value is everything after the first `=` with the surrounding blanks
# trimmed, and it is never expanded. Deliberately readable with the shell
# alone: `jq` is an optional dependency and may not be required here.
conf_value() {
  cv_key="$1"
  cv_file="$2"
  [ -f "$cv_file" ] || return 0
  while IFS= read -r cv_line || [ -n "$cv_line" ]; do
    cv_line=$(trim "$cv_line")
    case "$cv_line" in
      '' | '#'*) continue ;;
      *=*) ;;
      *) continue ;;
    esac
    [ "$(trim "${cv_line%%=*}")" = "$cv_key" ] || continue
    cv_value=$(trim "${cv_line#*=}")
    if [ -n "$cv_value" ]; then
      printf '%s' "$cv_value"
      return 0
    fi
  done < "$cv_file"
  return 0
}

# One clause of a fallback-table probe: `exists <path>` or
# `contains <path> <extended-regexp>`. The path is matched against the
# INVOCATION DIRECTORY only — a path carrying a `/` is a malformed rule and
# never matches, which is what keeps a probe from descending into a
# subdirectory or climbing to a parent (RF-17).
probe_clause_matches() {
  pcm_clause="$1"
  case "$pcm_clause" in
    'exists '*)
      pcm_path=$(trim "${pcm_clause#exists }")
      [ -n "$pcm_path" ] || return 1
      case "$pcm_path" in */*) return 1 ;; esac
      [ -f "$pcm_path" ]
      ;;
    'contains '*)
      pcm_rest=$(trim "${pcm_clause#contains }")
      pcm_path="${pcm_rest%% *}"
      pcm_re="${pcm_rest#* }"
      [ -n "$pcm_path" ] && [ "$pcm_path" != "$pcm_rest" ] || return 1
      case "$pcm_path" in */*) return 1 ;; esac
      [ -f "$pcm_path" ] || return 1
      grep -qE "$pcm_re" "$pcm_path"
      ;;
    *) return 1 ;;
  esac
}

# A probe is an alternation: its clauses are separated by ` || ` and any one of
# them matching matches the rule. One ecosystem with two possible manifests
# therefore stays ONE rule, and so one candidate.
probe_matches() {
  pm_rest="$1"
  while [ -n "$pm_rest" ]; do
    case "$pm_rest" in
      *' || '*)
        pm_clause="${pm_rest%%' || '*}"
        pm_rest="${pm_rest#*' || '}"
        ;;
      *)
        pm_clause="$pm_rest"
        pm_rest=""
        ;;
    esac
    if probe_clause_matches "$(trim "$pm_clause")"; then
      return 0
    fi
  done
  return 1
}

# EVERY fallback-table rule whose probe matches, one `<probe> :: <command>` per
# line — never the first match. The caller needs all of them: more than one
# match disables the gate (RF-19) instead of letting this file's order pick a
# winner, and the order of this file is documented as carrying no meaning.
TABLE_MATCHES=""
TABLE_MATCH_COUNT=0

scan_fallback_table() {
  TABLE_MATCHES=""
  TABLE_MATCH_COUNT=0
  [ -f "$FALLBACK_TABLE" ] || return 0

  while IFS= read -r sft_line || [ -n "$sft_line" ]; do
    case "$(trim "$sft_line")" in
      '' | '#'*) continue ;;
    esac
    case "$sft_line" in
      *' :: '*) ;;
      *) continue ;;
    esac
    sft_probe=$(trim "${sft_line%% :: *}")
    sft_cmd=$(trim "${sft_line#* :: }")
    [ -n "$sft_probe" ] && [ -n "$sft_cmd" ] || continue
    if probe_matches "$sft_probe"; then
      TABLE_MATCHES="$TABLE_MATCHES$sft_probe :: $sft_cmd
"
      TABLE_MATCH_COUNT=$((TABLE_MATCH_COUNT + 1))
    fi
  done < "$FALLBACK_TABLE"
}

resolve_test_command() {
  TEST_CMD=""
  TEST_CMD_RULE=""
  SUITE_GATE="disabled"
  TABLE_MATCHES=""
  TABLE_MATCH_COUNT=0

  if [ -n "$TEST_CMD_FLAG" ]; then
    TEST_CMD="$TEST_CMD_FLAG"
    TEST_CMD_RULE="the --test-cmd flag"
  elif [ -n "${MS_LOOP_TEST_CMD:-}" ]; then
    TEST_CMD="$MS_LOOP_TEST_CMD"
    TEST_CMD_RULE="the MS_LOOP_TEST_CMD environment variable"
  else
    rtc_declared=$(conf_value 'test_cmd' "$CONSUMER_CONF")
    if [ -n "$rtc_declared" ]; then
      TEST_CMD="$rtc_declared"
      TEST_CMD_RULE="the test_cmd key of $CONSUMER_CONF"
    else
      scan_fallback_table
      if [ "$TABLE_MATCH_COUNT" -eq 1 ]; then
        rtc_rule=$(printf '%s' "$TABLE_MATCHES" | sed '/^$/d')
        TEST_CMD=$(trim "${rtc_rule#* :: }")
        TEST_CMD_RULE="the fallback table $FALLBACK_TABLE, rule '${rtc_rule%% :: *}'"
      fi
    fi
  fi

  if [ -n "$TEST_CMD" ]; then
    SUITE_GATE="enabled"
    log "Suite gate: '$TEST_CMD' — resolved by $TEST_CMD_RULE"
    return 0
  fi

  if [ "$TABLE_MATCH_COUNT" -gt 1 ]; then
    warn "Suite gate DISABLED: the fallback table matched $TABLE_MATCH_COUNT rules in $(pwd) and the loop never picks one."
    printf '%s\n' "$TABLE_MATCHES" | sed '/^$/d; s/^/    matched: /' >&2
    warn "Letting the table's order break this tie would be a precedence between stacks, which is exactly what the table must not have."
    warn "Declare the command yourself to re-enable the gate: --test-cmd, MS_LOOP_TEST_CMD, or 'test_cmd=' in $CONSUMER_CONF."
  else
    warn "Suite gate DISABLED: no test command resolved. Searched, in this order:"
    warn "    1. the --test-cmd flag                       (not given)"
    warn "    2. the MS_LOOP_TEST_CMD environment variable (not set)"
    warn "    3. the test_cmd key of $CONSUMER_CONF        (absent or empty)"
    warn "    4. $FALLBACK_TABLE (no rule matched $(pwd))"
    warn "Declare the command to re-enable the gate: --test-cmd, MS_LOOP_TEST_CMD, or 'test_cmd=' in $CONSUMER_CONF."
  fi
  warn "The run continues on the verifier gate alone: an unresolved test command never aborts the loop."
  return 0
}

# RF-20: with both mechanical gates off, nothing left in the run can tell a
# finished issue from an unfinished one. Said out loud BEFORE the first engine
# session, never after the fact.
warn_when_no_mechanical_validation() {
  [ "$SUITE_GATE" = "disabled" ] || return 0
  [ "$VERIFY_MODE" = "off" ] || return 0
  warn "NO MECHANICAL VALIDATION IS ACTIVE — the suite gate and the verifier gate are both disabled."
  warn "Nothing in this run can tell a finished issue from an unfinished one."
  warn "Every issue executed will be recorded 'unverified', never 'done', and the run will exit non-zero."
}

# ---------------------------------------------------------------------------
# Dependency graph (RF-11, RF-34 a, b)
#
# Built EXCLUSIVELY from the `- **Blocked by**:` field of each slice. The
# `## Bloqueado por` heading of an issue body is prose and is never read here;
# a divergence between the two is not an error. Readiness comes from this
# document plus the progress record and from nothing else — GitHub is never
# asked, so the graph resolves identically with `gh` absent from PATH.
# ---------------------------------------------------------------------------

all_slice_numbers() {
  asn_out=""
  # shellcheck disable=SC2034  # positional fields of the record; a reader
  # only uses the ones it needs, but every field has to be named to be skipped.
  while IFS='|' read -r asn_num asn_head asn_issue asn_bline asn_braw asn_title; do
    [ -n "$asn_num" ] || continue
    asn_out="$asn_out $asn_num"
  done <<EOF
$SLICE_INDEX
EOF
  printf '%s' "$(trim "$asn_out")"
}

# The blockers of a slice that ARE slices of this same document, as slice
# numbers: the edges of the graph.
slice_blockers() {
  blockers_as_slice_numbers "$(slice_field "$1" 5)"
}

# The `#<n>` blockers of a slice that match no slice of this same document:
# external blocks, which are not edges and can never be satisfied here.
external_blockers_of() {
  ebo_raw=$(trim "$1")
  ebo_out=""
  [ "$ebo_raw" = "nenhum" ] && return 0

  ebo_rest="$ebo_raw"
  while [ -n "$ebo_rest" ]; do
    ebo_item="${ebo_rest%%,*}"
    if [ "$ebo_item" = "$ebo_rest" ]; then
      ebo_rest=""
    else
      ebo_rest="${ebo_rest#*,}"
    fi
    ebo_item=$(trim "$ebo_item")
    case "$ebo_item" in
      '#'*)
        if [ -z "$(slice_number_for_issue "${ebo_item#\#}")" ]; then
          ebo_out="$ebo_out $ebo_item"
        fi
        ;;
    esac
  done
  printf '%s' "$(trim "$ebo_out")"
}

slice_external_blockers() {
  external_blockers_of "$(slice_field "$1" 5)"
}

# Kahn over the `- **Blocked by**:` graph, emitting one slice at a time and
# breaking a tie between equally ready slices on the lower slice number, so the
# order is deterministic and stays as close to the document as the declared
# dependencies allow. TOPO_ORDER is the slice numbers in dependency order;
# TOPO_STALLED holds the slices no traversal can ever reach, which in a finite
# graph ARE a cycle.
TOPO_ORDER=""
TOPO_STALLED=""

compute_topological_order() {
  TOPO_ORDER=""
  TOPO_STALLED=""
  cto_remaining=$(all_slice_numbers)

  while [ -n "$cto_remaining" ]; do
    cto_pick=""
    for cto_num in $cto_remaining; do
      cto_ready=true
      for cto_dep in $(slice_blockers "$cto_num"); do
        # A slice listed as its own blocker is still in $cto_remaining, so the
        # membership test below already reports it as a cycle.
        if in_list "$cto_dep" "$cto_remaining"; then
          cto_ready=false
          break
        fi
      done
      [ "$cto_ready" = true ] || continue
      if [ -z "$cto_pick" ] || [ "$cto_num" -lt "$cto_pick" ]; then
        cto_pick="$cto_num"
      fi
    done

    if [ -z "$cto_pick" ]; then
      TOPO_STALLED="$cto_remaining"
      break
    fi

    TOPO_ORDER="$TOPO_ORDER $cto_pick"
    cto_next=""
    for cto_num in $cto_remaining; do
      [ "$cto_num" = "$cto_pick" ] || cto_next="$cto_next $cto_num"
    done
    cto_remaining=$(trim "$cto_next")
  done

  TOPO_ORDER=$(trim "$TOPO_ORDER")
}

validate_acyclic() {
  compute_topological_order
  [ -n "$TOPO_STALLED" ] || return 0

  va_lines=""
  for va_num in $TOPO_STALLED; do
    va_bline=$(slice_field "$va_num" 4)
    va_braw=$(slice_field "$va_num" 5)
    va_lines="$va_lines$va_bline: Slice $va_num — - **Blocked by**: $va_braw
"
  done
  abort_format "the '- **Blocked by**:' graph has a cycle; these slices block each other:" "$va_lines"
}

# The slices that name <n> among their blockers.
direct_dependents() {
  dd_target="$1"
  dd_out=""
  for dd_num in $(all_slice_numbers); do
    for dd_dep in $(slice_blockers "$dd_num"); do
      if [ "$dd_dep" = "$dd_target" ]; then
        dd_out="$dd_out $dd_num"
        break
      fi
    done
  done
  printf '%s' "$(trim "$dd_out")"
}

# The whole downstream cone of <n>, at any depth. The graph is a graph and not
# the mirrored harness's linear phase chain, so propagation has to be
# transitive: a dependent of a dependent is just as unreachable (RF-34b).
transitive_dependents() {
  td_seen=""
  td_queue="$1"
  while [ -n "$td_queue" ]; do
    td_next=""
    for td_num in $td_queue; do
      for td_dep in $(direct_dependents "$td_num"); do
        if ! in_list "$td_dep" "$td_seen"; then
          td_seen="$td_seen $td_dep"
          td_next="$td_next $td_dep"
        fi
      done
    done
    td_queue=$(trim "$td_next")
  done
  printf '%s' "$(trim "$td_seen")"
}

# Record every slice downstream of <n> as `blocked`, and echo the ones marked.
# Called when a slice can no longer reach `done` — it ended `failed` (RF-34b)
# or it is blocked externally — because from that moment no traversal will ever
# record its dependents' blockers `done`. None of them ever reaches an engine.
# A slice already recorded `blocked-external` keeps that state: its own
# blocker lives outside this document and that is the more precise report.
mark_blocked_transitively() {
  mbt_root="$1"
  mbt_cause="$2"
  mbt_marked=""
  for mbt_num in $(transitive_dependents "$mbt_root"); do
    mbt_hash=$(manifest_hash_for "$mbt_num")
    [ "$(progress_state "$mbt_num" "$mbt_hash")" = "blocked-external" ] && continue
    progress_put "$mbt_num" "$mbt_hash" "blocked" "disabled" "disabled" "$mbt_cause"
    mbt_marked="$mbt_marked $mbt_num"
  done
  printf '%s' "$(trim "$mbt_marked")"
}

# RF-34a/b: the run loop calls this the moment a slice ends `failed`. From that
# moment nothing downstream of it can ever have its blockers recorded `done`,
# so the whole cone goes down with it — transitively, and with zero engine
# sessions for any of them. The failed slice itself is recorded by its own
# outcome; this marks only what it took with it, and echoes the slice numbers
# marked so the caller can report them.
mark_dependents_of_failure() {
  mark_blocked_transitively "$1" "blocked by Slice $1, which failed"
}

# The next slice to execute: the first one in topological order that still has
# to run and whose every blocker is RECORDED `done`. That record is the only
# readiness signal there is — RF-11 forbids asking GitHub, and the loop must
# work with `gh` off the PATH. A slice with an external block is never
# selected, at any point of the run.
#
# `--only-slice` is an explicit human override and skips the blocker check; it
# does not override an external block, which can never be satisfied here.
select_next_ready() {
  for snr_num in $TOPO_ORDER; do
    if [ -n "$ONLY_SLICE" ] && [ "$ONLY_SLICE" != "$snr_num" ]; then
      continue
    fi
    snr_hash=$(manifest_hash_for "$snr_num")
    progress_should_run "$snr_num" "$snr_hash" || continue
    [ -z "$(slice_external_blockers "$snr_num")" ] || continue

    snr_ready=true
    if [ -z "$ONLY_SLICE" ]; then
      for snr_dep in $(slice_blockers "$snr_num"); do
        snr_dhash=$(manifest_hash_for "$snr_dep")
        if ! progress_is_done "$snr_dep" "$snr_dhash"; then
          snr_ready=false
          break
        fi
      done
    fi
    [ "$snr_ready" = true ] || continue

    printf '%s' "$snr_num"
    return 0
  done
  return 0
}

# ---------------------------------------------------------------------------
# Run plan
# ---------------------------------------------------------------------------

validate_only_slice() {
  [ -n "$ONLY_SLICE" ] || return 0
  if ! is_positive_int "$ONLY_SLICE"; then
    fail "--only-slice expects a slice number, got: $ONLY_SLICE"
    exit 1
  fi
  if [ -z "$(manifest_hash_for "$ONLY_SLICE")" ]; then
    fail "--only-slice $ONLY_SLICE: no such slice in $INPUT_FILE"
    exit 1
  fi
}

PENDING_SLICES=""
EXTERNALLY_BLOCKED=""
BLOCKED_SLICES=""

# The slices the graph rules out before the run starts. An external block is
# recorded and reported `blocked-external` and never fails the run (RF-11);
# everything downstream of it is `blocked`, transitively, because a blocker
# living outside this document can never be recorded `done` here (RF-34b).
classify_blocked_slices() {
  EXTERNALLY_BLOCKED=""
  BLOCKED_SLICES=""

  for cbs_num in $(all_slice_numbers); do
    cbs_ext=$(slice_external_blockers "$cbs_num")
    [ -n "$cbs_ext" ] || continue
    EXTERNALLY_BLOCKED="$EXTERNALLY_BLOCKED $cbs_num"
    cbs_hash=$(manifest_hash_for "$cbs_num")
    progress_put "$cbs_num" "$cbs_hash" "blocked-external" "disabled" "disabled" \
      "waiting on $cbs_ext, which matches no slice of $INPUT_FILE"
  done
  EXTERNALLY_BLOCKED=$(trim "$EXTERNALLY_BLOCKED")

  for cbs_num in $EXTERNALLY_BLOCKED; do
    for cbs_dep in $(mark_blocked_transitively "$cbs_num" \
      "blocked by Slice $cbs_num, which is blocked externally"); do
      in_list "$cbs_dep" "$BLOCKED_SLICES" || BLOCKED_SLICES="$BLOCKED_SLICES $cbs_dep"
    done
  done
  BLOCKED_SLICES=$(trim "$BLOCKED_SLICES")
}

print_run_plan() {
  classify_blocked_slices

  PENDING_SLICES=""
  log "Run plan ($INPUT_FILE):"
  # shellcheck disable=SC2034  # positional fields of the record; a reader
  # only uses the ones it needs, but every field has to be named to be skipped.
  while IFS='|' read -r prp_file prp_num prp_title prp_hash prp_braw; do
    [ -n "$prp_num" ] || continue
    prp_state=$(progress_state "$prp_num" "$prp_hash")
    [ -n "$prp_state" ] || prp_state="pending"

    if in_list "$prp_num" "$EXTERNALLY_BLOCKED"; then
      prp_action="skip: blocked externally by $(slice_external_blockers "$prp_num")"
    elif in_list "$prp_num" "$BLOCKED_SLICES"; then
      prp_action="skip: $(progress_cause "$prp_num" "$prp_hash")"
    elif [ -n "$ONLY_SLICE" ] && [ "$ONLY_SLICE" != "$prp_num" ]; then
      prp_action="skip: --only-slice $ONLY_SLICE"
    elif progress_should_run "$prp_num" "$prp_hash"; then
      prp_action="run"
      PENDING_SLICES="$PENDING_SLICES $prp_num"
    else
      prp_action="skip"
    fi

    printf '    Slice %s — %s (%s): %s\n' "$prp_num" "$prp_state" "$prp_action" "$prp_title"
  done <<EOF
$(manifest_entries)
EOF

  # The queue is kept in topological order, so the slices leave the plan in the
  # order their `- **Blocked by**:` fields declare.
  prp_ordered=""
  for prp_num in $TOPO_ORDER; do
    in_list "$prp_num" "$PENDING_SLICES" && prp_ordered="$prp_ordered $prp_num"
  done
  PENDING_SLICES=$(trim "$prp_ordered")

  prp_order_line=""
  for prp_num in $TOPO_ORDER; do
    if [ -z "$prp_order_line" ]; then
      prp_order_line="Slice $prp_num"
    else
      prp_order_line="$prp_order_line -> Slice $prp_num"
    fi
  done
  log "Execution order, from '- **Blocked by**:' alone: $prp_order_line"

  if [ -n "$EXTERNALLY_BLOCKED" ]; then
    warn "Blocked externally — never selected, and never a reason for the run to fail:"
    for prp_num in $EXTERNALLY_BLOCKED; do
      warn "    Slice $prp_num — waiting on $(slice_external_blockers "$prp_num"), which matches no slice of $INPUT_FILE"
    done
  fi

  prp_pending=0
  for prp_num in $PENDING_SLICES; do
    prp_pending=$((prp_pending + 1))
  done
  log "$prp_pending slice(s) to execute, $((SLICE_COUNT - prp_pending)) skipped"

  prp_next=$(select_next_ready)
  if [ -n "$prp_next" ]; then
    log "Next ready slice: Slice $prp_next — $(slice_field "$prp_next" 6)"
  else
    log "No slice is ready to execute."
  fi
}

# ---------------------------------------------------------------------------
# Prompts (T09, RF-09) — one self-contained file per session
#
# Every issue AND every correction cycle gets its OWN prompt file and its OWN
# engine session: a session is never reused, so nothing carries over from
# another issue or from another cycle. The prompt is therefore the only context
# a session has, and it has to stand on its own.
#
# The preamble names no language, framework or runtime: it tells the session
# where to LOOK for the project's conventions instead of assuming them.
#
# Nothing here ever reads .env or any credential file, and nothing here ever
# copies an environment value into a prompt or a log (RNF-07).
# ---------------------------------------------------------------------------

slice_path() { printf '%s/%s' "$SLICES_DIR" "$(slice_file_name "$1")"; }
slice_stem() { printf 'slice-%02d' "$1"; }

impl_prompt_path()   { printf '%s/%s.cycle-%s.txt'  "$PROMPT_DIR" "$(slice_stem "$1")" "$2"; }
verify_prompt_path() { printf '%s/%s.verify-%s.txt' "$PROMPT_DIR" "$(slice_stem "$1")" "$2"; }
impl_log_path()      { printf '%s/%s.cycle-%s.log'  "$LOG_DIR" "$(slice_stem "$1")" "$2"; }
verify_log_path()    { printf '%s/%s.verify-%s.log' "$LOG_DIR" "$(slice_stem "$1")" "$2"; }
suite_log_path()     { printf '%s/%s.suite-%s.log'  "$LOG_DIR" "$(slice_stem "$1")" "$2"; }

context_preamble() {
  cat <<'PREAMBLE'
## Discover the stack and the conventions before writing code
This project may be written in ANY language or framework. Do NOT assume a
stack. Before you start, READ whichever of these exist, in this order:
1. AGENTS.md or CLAUDE.md — the project's conventions, commands and rules
2. .spec/init/project-description.md — the general project description
3. .spec/init/user-stories.md — the user stories
4. .spec/init/database-schema.md — the user-facing data model
5. the documents the issue itself names (the feature's SPEC.md and PLAN.md)
Use the build, test and run commands those documents and the tooling already
present in the repository define. If the project has a memory or context tool
configured, use it to understand the history.
PREAMBLE

  # The suite gate runs THIS command. A session that validates itself with a
  # different runner sees green while the gate sees red, so the command the
  # loop resolved is stated in the prompt.
  if [ -n "$TEST_CMD" ]; then
    echo
    echo "## The test command of this project"
    echo "Always run the suite with:"
    echo
    echo "    $TEST_CMD"
    echo
    echo "This is the exact command used to validate the issue. Do not use another"
    echo "runner and do not run the tests outside it."
  fi
}

# The implementation prompt of a fresh issue.
build_impl_prompt() {
  bip_num="$1"
  bip_cycle="$2"
  bip_file=$(impl_prompt_path "$bip_num" "$bip_cycle")

  {
    echo "You are a senior developer implementing one issue of this project."
    echo
    context_preamble
    cat <<'TASK'

## Your task now
Implement the issue below COMPLETELY.

For each acceptance criterion:
1. Write the complete code (leave no TODO and no placeholder)
2. Write the tests the criterion calls for, in the project's test framework
3. Run the tests with the project's test command
4. If a test fails, fix the code and run it again
5. Only move to the next criterion once the tests pass

## Mandatory rules
- Always use the commands, the test runner and the tooling the project has
  already adopted; never introduce a new stack or tool on your own
- Tests and fixtures/factories must create every dependency they need
- Class, file and method names must follow EXACTLY what the issue describes
- Do not skip any checkbox of the acceptance criteria
- At the end, make sure the project's whole test suite passes

## Issue to implement
TASK
    cat "$(slice_path "$bip_num")"
  } > "$bip_file"

  printf '%s' "$bip_file"
}

# The correction prompt. Self-contained like the first one, and carrying the
# REAL cause of the red gate — never a generic "the tests failed", which tells
# a fresh session nothing it can act on.
build_fix_prompt() {
  bfp_num="$1"
  bfp_cycle="$2"
  bfp_gate="$3"
  bfp_cause="$4"
  bfp_file=$(impl_prompt_path "$bfp_num" "$bfp_cycle")

  {
    echo "You are a senior developer finishing a partially implemented issue."
    echo
    context_preamble
    cat <<'INTRO'

## Situation
An earlier session tried to implement the issue below and did NOT pass the
mechanical verification. You are in a NEW session: you have no memory of what
was done. Read the current code before changing anything.

## Mandatory rules
- Fix ONLY what is missing. Do not reimplement what is already correct and tested.
- Leave no TODO, no placeholder and no skipped test.
- Run the project's test suite at the end and make sure it passes.
INTRO
    echo
    echo "## Why the previous session was rejected ($bfp_gate)"
    echo '```'
    printf '%s\n' "$bfp_cause"
    echo '```'
    echo
    echo "## Issue to complete"
    cat "$(slice_path "$bfp_num")"
  } > "$bfp_file"

  printf '%s' "$bfp_file"
}

# The checkbox lines of the issue body's `## Critérios de aceite` section —
# the PT-BR heading is the literal of CT-02 and is what the verifier judges,
# one line of verdict per checkbox (CT-07).
criteria_checkboxes() {
  awk '
    /^##[[:space:]]+Critérios de aceite[[:space:]]*$/ { inside = 1; next }
    /^##[[:space:]]/ { inside = 0 }
    inside && /^[[:space:]]*- \[[ xX]\]/ { print }
  ' "$1"
}

# The verifier prompt embeds the checkboxes it must judge and the CT-07 verdict
# protocol verbatim. The same literals are duplicated in the verifier agent
# specification on purpose (each file must stand alone at runtime) and the
# drift check is what keeps the two copies identical.
build_verify_prompt() {
  bvp_num="$1"
  bvp_cycle="$2"
  bvp_file=$(verify_prompt_path "$bvp_num" "$bvp_cycle")

  {
    cat <<'VERIFY'
You are an INDEPENDENT VERIFIER. Do NOT write, edit or create any file. Your
only job is to read the real code and say what is done and what is not.

For EACH checkbox of the issue's `## Critérios de aceite` section, in the order
they appear, check the criterion against the real code — files, classes, tests,
routes, migrations, whatever the criterion demands — and emit EXACTLY ONE line
per checkbox, in this format:

CRITERION <n>: DONE|INCOMPLETE — <arquivo:linha ou saída real de comando>

Rules:
- <n> is the index of the checkbox, starting at 1.
- One CRITERION line per checkbox, no exception, never grouped.
- Emit no other text besides the CRITERION lines.
- The evidence is either `file:line` or the REAL output of a command you ran.
  "Not verifiable" does not exist: no evidence means the criterion is not met.
- Missing code, a TODO, a placeholder or a missing test means INCOMPLETE.
- When in doubt, INCOMPLETE.

## Checkboxes to judge
VERIFY
    criteria_checkboxes "$(slice_path "$bvp_num")"
    echo
    echo "## Issue under verification"
    cat "$(slice_path "$bvp_num")"
  } > "$bvp_file"

  printf '%s' "$bvp_file"
}

# ---------------------------------------------------------------------------
# Usage limit (RNF-06) — looked for at the END of the log, with per-engine
# patterns. Scanning the whole log would make a project's own test output
# ("429", "too many requests") trigger a half-hour sleep.
# ---------------------------------------------------------------------------

LIMIT_WAITS=0
LIMIT_WAIT_DEFAULT="${MS_LOOP_LIMIT_WAIT_DEFAULT:-1800}"
LIMIT_BUFFER="${MS_LOOP_LIMIT_BUFFER:-60}"

# Echoes the reset epoch when it finds one, `0` for a limit without a time.
# Returns 0 when a usage limit was detected, 1 when there is none.
detect_usage_limit() {
  dul_tail=$(tail -n 20 "$1" 2> /dev/null || true)

  if [ "$ENGINE" = "claude" ]; then
    dul_pattern='usage limit reached'
  else
    dul_pattern='rate limit reached|quota exceeded|usage limit reached'
  fi

  printf '%s\n' "$dul_tail" | grep -qiE "$dul_pattern" || return 1

  dul_epoch=$(printf '%s\n' "$dul_tail" | grep -oiE 'usage limit reached[^0-9]*[0-9]{10,13}' \
    | grep -oE '[0-9]{10,13}' | tail -1 || true)
  if [ -z "$dul_epoch" ]; then
    dul_epoch=$(printf '%s\n' "$dul_tail" | grep -oiE 'reset[a-z ]*[0-9]{10,13}' \
      | grep -oE '[0-9]{10,13}' | tail -1 || true)
  fi

  printf '%s' "${dul_epoch:-0}"
  return 0
}

# Waits for the reset and returns, so the caller re-runs the SAME issue on the
# SAME cycle: a usage limit is not a failed attempt and never consumes a
# correction cycle. The number of consecutive waits is capped so a permanently
# limited account ends the run instead of sleeping forever.
wait_for_reset() {
  wfr_epoch="$1"
  wfr_now=$(date +%s)

  LIMIT_WAITS=$((LIMIT_WAITS + 1))
  if [ "$LIMIT_WAITS" -gt "$MAX_LIMIT_WAITS" ]; then
    fail "Usage limit hit $LIMIT_WAITS times in a row on this issue (cap: $MAX_LIMIT_WAITS)."
    fail "Aborting instead of sleeping indefinitely."
    exit 1
  fi

  case "$wfr_epoch" in
    '' | *[!0-9]*) wfr_epoch=0 ;;
  esac
  if [ "$wfr_epoch" -gt 0 ]; then
    if [ "${#wfr_epoch}" -ge 13 ]; then
      wfr_epoch=$((wfr_epoch / 1000))
    fi
    wfr_secs=$((wfr_epoch - wfr_now + LIMIT_BUFFER))
    [ "$wfr_secs" -lt "$LIMIT_BUFFER" ] && wfr_secs=$LIMIT_BUFFER
    warn "Usage limit reached. Reset announced by the engine; waiting for it."
  else
    wfr_secs=$LIMIT_WAIT_DEFAULT
    warn "Usage limit reached. No reset time in the output; waiting the fallback interval."
  fi

  warn "Wait $LIMIT_WAITS/$MAX_LIMIT_WAITS — sleeping $(format_duration "$wfr_secs") before re-running the SAME issue (no correction cycle is consumed)."

  wfr_left=$wfr_secs
  while [ "$wfr_left" -gt 0 ]; do
    wfr_chunk=60
    [ "$wfr_left" -lt 60 ] && wfr_chunk=$wfr_left
    sleep "$wfr_chunk"
    wfr_left=$((wfr_left - wfr_chunk))
    [ "$wfr_left" -gt 0 ] && log "Resuming in $(format_duration "$wfr_left")..."
  done

  success "Reset window elapsed. Re-running the same issue."
}

# ---------------------------------------------------------------------------
# Engine (T09)
#
# Every invocation has its stdin REDIRECTED, never inherited: the prompt file
# for one engine, /dev/null for the other. A body command that reads stdin when
# it is not a TTY would otherwise swallow the loop's own stream, and the run
# would silently stop after the first issue. The manifest is read over fd 3 for
# the same reason (UI-05: the loop asks nothing and blocks on nothing).
# ---------------------------------------------------------------------------

VERIFY_MODEL="${MS_LOOP_VERIFY_MODEL:-}"

resolve_verify_model() {
  [ -z "$VERIFY_MODEL" ] || return 0
  # A read-only verdict is cheap work; the expensive model buys nothing here.
  [ "$ENGINE" = "claude" ] && VERIFY_MODEL="haiku"
  return 0
}

# run_engine <prompt file> <log file> <impl|verify>
run_engine() {
  re_prompt="$1"
  re_log="$2"
  re_mode="$3"

  export MS_LOOP_ENGINE="$ENGINE"
  export MS_LOOP_MAX_CYCLES="$MAX_CYCLES"

  while true; do
    re_rc=0

    if [ "$ENGINE" = "codex" ]; then
      if [ "$re_mode" = "verify" ]; then
        if [ -n "$VERIFY_MODEL" ]; then
          codex exec --sandbox read-only --model "$VERIFY_MODEL" - \
            < "$re_prompt" > "$re_log" 2>&1 || re_rc=$?
        else
          codex exec --sandbox read-only - < "$re_prompt" > "$re_log" 2>&1 || re_rc=$?
        fi
      else
        codex exec --sandbox danger-full-access - < "$re_prompt" > "$re_log" 2>&1 || re_rc=$?
      fi
    else
      if [ "$re_mode" = "verify" ]; then
        if [ -n "$VERIFY_MODEL" ]; then
          env -u CLAUDECODE claude --dangerously-skip-permissions \
            --model "$VERIFY_MODEL" \
            -p "$(cat "$re_prompt")" \
            --allowedTools "Read,Glob,Grep" \
            --output-format text < /dev/null > "$re_log" 2>&1 || re_rc=$?
        else
          env -u CLAUDECODE claude --dangerously-skip-permissions \
            -p "$(cat "$re_prompt")" \
            --allowedTools "Read,Glob,Grep" \
            --output-format text < /dev/null > "$re_log" 2>&1 || re_rc=$?
        fi
      else
        # JSON output: the CLI exit code is a weak signal here, and the
        # engine-finished gate reads is_error out of this stream.
        env -u CLAUDECODE claude --dangerously-skip-permissions \
          -p "$(cat "$re_prompt")" \
          --output-format json < /dev/null > "$re_log" 2>&1 || re_rc=$?
      fi
    fi

    if re_epoch=$(detect_usage_limit "$re_log"); then
      wait_for_reset "$re_epoch"
      continue
    fi

    return "$re_rc"
  done
}

# ---------------------------------------------------------------------------
# Gates (T10, RF-10)
#
# The engine exit code is NEVER a verdict of completion, on any path: it only
# tells whether the session ended at all. What decides an issue is the set of
# ACTIVE mechanical gates — the project's own suite, run by the loop outside
# the agent session, and an independent read-only verifier session judging the
# acceptance criteria one by one under the CT-07 protocol.
# ---------------------------------------------------------------------------

GATE_CAUSE=""
LAST_GATE=""
SUITE_RESULT="disabled"
VERIFY_RESULT="disabled"

# Did the session end at all? A signal about the RUN, never about the work.
gate_engine_finished() {
  gef_log="$1"
  gef_rc="$2"

  if [ "$ENGINE" = "claude" ]; then
    if ! grep -qF '"type":"result"' "$gef_log" && ! grep -qF '"type": "result"' "$gef_log"; then
      GATE_CAUSE="The engine session ended without emitting a result. Tail of its output:
$(tail -n 40 "$gef_log")"
      return 1
    fi
    if grep -qE '"is_error"[[:space:]]*:[[:space:]]*true' "$gef_log"; then
      GATE_CAUSE="The engine reported is_error=true. Tail of its output:
$(tail -n 40 "$gef_log")"
      return 1
    fi
  fi

  if [ "$gef_rc" -ne 0 ]; then
    GATE_CAUSE="The engine exited with code $gef_rc. Tail of its output:
$(tail -n 40 "$gef_log")"
    return 1
  fi

  return 0
}

# A signature of the work tree: tracked changes plus the content of everything
# untracked. Never mutates the index.
tree_signature() {
  ts_tmp="$STATE_DIR/.treesig.$$"
  {
    git status --porcelain 2> /dev/null || true
    git diff HEAD 2> /dev/null || true
    git ls-files --others --exclude-standard 2> /dev/null | while IFS= read -r ts_path; do
      printf '%s\n' "$ts_path"
      cat "$ts_path" 2> /dev/null || true
    done
  } > "$ts_tmp" 2> /dev/null || true
  ts_hash=$(hash_file "$ts_tmp")
  rm -f "$ts_tmp"
  printf '%s' "$ts_hash"
}

# Did THIS session write anything? A SIGNAL, never a verdict: an issue already
# implemented in HEAD makes a correct session write nothing at all, and failing
# it here would be a false negative. Only the suite gate and the verifier gate
# know whether the work is complete. The signal feeds the correction cause and
# the `auto` mode of the verifier gate.
session_wrote_something() {
  [ "$(tree_signature)" != "$1" ]
}

# SUITE GATE — the consumer project's own suite, run BY THE LOOP, outside the
# agent session, with stdin redirected, and its REAL output captured as the
# cause handed to the next correction cycle.
gate_suite() {
  gs_log="$1"

  if [ -z "$TEST_CMD" ]; then
    SUITE_RESULT="disabled"
    return 0
  fi

  log "Suite gate — running the project's suite: $TEST_CMD"
  gs_rc=0
  bash -c "$TEST_CMD" < /dev/null > "$gs_log" 2>&1 || gs_rc=$?

  if [ "$gs_rc" -ne 0 ]; then
    SUITE_RESULT="failed"
    GATE_CAUSE="The project's test command ('$TEST_CMD') failed with code $gs_rc. Real output:
$(tail -n 200 "$gs_log")"
    return 1
  fi

  SUITE_RESULT="passed"
  success "Suite gate — green"
  return 0
}

# VERIFIER GATE — a FRESH, READ-ONLY engine session judging the issue's
# acceptance criteria one by one, under the CT-07 protocol. Its report is
# consumed by the loop and grows with the number of criteria; the 200-byte
# handoff ceiling applies to router summaries, not to this.
gate_verifier() {
  gv_num="$1"
  gv_cycle="$2"
  gv_wrote="$3"
  gv_log=$(verify_log_path "$gv_num" "$gv_cycle")

  VERIFY_RESULT="disabled"

  case "$VERIFY_MODE" in
    off)
      log "Verifier gate disabled (--no-verify / MS_LOOP_VERIFY=off)"
      return 0
      ;;
    auto)
      if [ "$gv_cycle" -eq 1 ] && [ "$gv_wrote" = true ] && [ -n "$TEST_CMD" ]; then
        log "Verifier gate skipped: the session wrote code and the suite gate is green (MS_LOOP_VERIFY=always to run it every time)"
        return 0
      fi
      ;;
  esac

  gv_expected=$(criteria_checkboxes "$(slice_path "$gv_num")" | grep -c '' | tr -d ' ')
  if [ "$gv_expected" -eq 0 ]; then
    warn "Verifier gate disabled for Slice $gv_num: its body declares no '## Critérios de aceite' checkbox to judge."
    return 0
  fi

  log "Verifier gate — independent read-only session ($gv_expected criteria${VERIFY_MODEL:+, model: $VERIFY_MODEL})"
  gv_prompt=$(build_verify_prompt "$gv_num" "$gv_cycle")
  run_engine "$gv_prompt" "$gv_log" verify || true

  gv_lines=$(sed 's/^[[:space:]]*//' "$gv_log" | grep -E '^CRITERION [0-9]+: (DONE|INCOMPLETE)' || true)
  gv_parsed=$(printf '%s' "$gv_lines" | grep -c '' | tr -d ' ')
  [ -n "$gv_lines" ] || gv_parsed=0

  if [ "$gv_parsed" -eq 0 ]; then
    VERIFY_RESULT="failed"
    GATE_CAUSE="The independent verifier emitted no 'CRITERION <n>: DONE|INCOMPLETE' line at all, so nothing confirms the issue is complete. Tail of the verifier output:
$(tail -n 40 "$gv_log")"
    return 1
  fi

  # Anti-gaming: a verdict that does not cover exactly one line per checkbox is
  # RED even when every line it did emit says DONE. A prolix or a truncated
  # verifier must never be able to approve an incomplete issue.
  if [ "$gv_parsed" -ne "$gv_expected" ]; then
    VERIFY_RESULT="failed"
    GATE_CAUSE="The verifier emitted $gv_parsed verdict line(s) for $gv_expected acceptance criteria — the coverage does not match, so the verdict is rejected. Lines emitted:
$gv_lines"
    return 1
  fi

  gv_incomplete=$(printf '%s\n' "$gv_lines" | grep 'INCOMPLETE' || true)
  if [ -n "$gv_incomplete" ]; then
    VERIFY_RESULT="failed"
    GATE_CAUSE="The independent verifier found unmet acceptance criteria:
$gv_incomplete"
    return 1
  fi

  VERIFY_RESULT="passed"
  success "Verifier gate — $gv_parsed/$gv_expected criteria confirmed in the real code"
  return 0
}

# ---------------------------------------------------------------------------
# Issue execution (T11, RF-34 a, RF-35 c/d/e)
#
# One issue end to end: a fresh implementation session, the gates, up to
# --max-cycles correction cycles fed by the REAL red cause, then the outcome.
# The commit is created ONLY after every active gate is green, never before,
# and `failed` and `blocked` never produce one.
# ---------------------------------------------------------------------------

commit_slice() {
  cs_num="$1"
  cs_title="$2"
  git add -A
  if git diff --cached --quiet; then
    fail "Nothing to commit after the gates went green — unexpected state."
    return 1
  fi
  git commit -q -m "feat(issue-${cs_num}): ${cs_title}"
  log "Commit created: feat(issue-${cs_num}): ${cs_title}"
  return 0
}

# run_slice <number> <title> <hash> <seq> <total>
# Records the outcome in the progress record, which is the single place the
# report and the exit code read it from. Returns 0 for done/unverified, 1 for
# failed.
run_slice() {
  rs_num="$1"
  rs_title="$2"
  rs_hash="$3"
  rs_seq="$4"
  rs_total="$5"
  rs_started=$(date +%s)

  # Per-issue context for the consumer project's own hooks. No secret, token
  # or connection string is ever exported, written to a prompt or logged.
  export MS_LOOP_ISSUE_NUM="$rs_num"
  export MS_LOOP_ISSUE_TITLE="$rs_title"
  export MS_LOOP_ISSUE_TOTAL="$rs_total"

  LIMIT_WAITS=0
  GATE_CAUSE=""
  LAST_GATE=""

  echo ""
  log "[$rs_seq/$rs_total] Slice $rs_num: $rs_title"

  rs_cycle=1
  while [ "$rs_cycle" -le "$MAX_CYCLES" ]; do
    export MS_LOOP_ISSUE_ATTEMPT="$rs_cycle"
    [ "$rs_cycle" -gt 1 ] && warn "Correction cycle $rs_cycle/$MAX_CYCLES..."

    rs_log=$(impl_log_path "$rs_num" "$rs_cycle")
    if [ "$rs_cycle" -eq 1 ]; then
      rs_prompt=$(build_impl_prompt "$rs_num" "$rs_cycle")
    else
      rs_prompt=$(build_fix_prompt "$rs_num" "$rs_cycle" "$LAST_GATE" "$GATE_CAUSE")
    fi

    rs_sig_before=$(tree_signature)
    rs_rc=0
    run_engine "$rs_prompt" "$rs_log" impl || rs_rc=$?

    GATE_CAUSE=""
    SUITE_RESULT="disabled"
    VERIFY_RESULT="disabled"

    rs_wrote=true
    rs_note=""
    if ! session_wrote_something "$rs_sig_before"; then
      rs_wrote=false
      rs_note="The previous session ended without changing a single file. "
      warn "The session wrote nothing; validating the code that is already there"
    fi

    if ! gate_engine_finished "$rs_log" "$rs_rc"; then
      LAST_GATE="engine session did not finish"
      fail "Engine session gate red"
    elif ! gate_suite "$(suite_log_path "$rs_num" "$rs_cycle")"; then
      LAST_GATE="suite gate — the project's test command"
      GATE_CAUSE="${rs_note}${GATE_CAUSE}"
      fail "Suite gate red — the project's tests failed"
    elif ! gate_verifier "$rs_num" "$rs_cycle" "$rs_wrote"; then
      LAST_GATE="verifier gate — independent verification"
      GATE_CAUSE="${rs_note}${GATE_CAUSE}"
      fail "Verifier gate red — the issue is not complete"
    else
      finish_green_slice "$rs_num" "$rs_title" "$rs_hash" "$rs_started"
      return 0
    fi

    rs_cycle=$((rs_cycle + 1))
  done

  progress_put "$rs_num" "$rs_hash" "failed" "$SUITE_RESULT" "$VERIFY_RESULT" \
    "$LAST_GATE: $(printf '%s' "$GATE_CAUSE" | head -n 3)"

  fail "Slice $rs_num: $rs_title — FAILED after $MAX_CYCLES cycle(s) ($(format_duration "$(($(date +%s) - rs_started))"))"
  fail "Last cause ($LAST_GATE):"
  printf '%s\n' "$GATE_CAUSE" | head -n 20 | sed 's/^/    /' >&2
  fail "Logs: $LOG_DIR/$(slice_stem "$rs_num").*"
  if [ -n "$(git status --porcelain)" ]; then
    warn "A failed issue never produces a commit, so its partial work is still in the work tree."
    warn "Commit it (the loop re-validates the issue and moves on) or 'git checkout -- . && git clean -fd' to drop it."
  fi
  return 1
}

# Every active gate is green. What is left to decide is whether there is work
# to commit and whether ANY gate was actually active.
finish_green_slice() {
  fgs_num="$1"
  fgs_title="$2"
  fgs_hash="$3"
  fgs_started="$4"

  fgs_active=0
  [ "$SUITE_RESULT" = "disabled" ]  || fgs_active=$((fgs_active + 1))
  [ "$VERIFY_RESULT" = "disabled" ] || fgs_active=$((fgs_active + 1))

  fgs_state="done"
  fgs_cause=""
  if [ "$fgs_active" -eq 0 ]; then
    # RF-10, zero-gates clause: the work is executed and committed, but nothing
    # in this run could tell a finished issue from an unfinished one, so it is
    # NEVER declared done. Absence of validation never yields a silent success.
    fgs_state="unverified"
    fgs_cause="no mechanical gate was active: the suite gate and the verifier gate are both disabled"
    warn "Slice $fgs_num: $fgs_title — UNVERIFIED (no active gate); the run will exit non-zero"
  fi

  if [ -z "$(git status --porcelain)" ]; then
    # Gates green and nothing to commit: the issue was already implemented in
    # HEAD (an earlier committed run, code written by hand). Not a failure.
    if [ "$fgs_state" = "done" ]; then
      success "Slice $fgs_num: $fgs_title — ALREADY IMPLEMENTED in HEAD (nothing to commit)"
      log "The active gates are green against the code in HEAD; no commit created."
    fi
    progress_put "$fgs_num" "$fgs_hash" "$fgs_state" "$SUITE_RESULT" "$VERIFY_RESULT" "$fgs_cause"
    return 0
  fi

  # The commit happens HERE and nowhere else: after the gates, never before.
  if ! commit_slice "$fgs_num" "$fgs_title"; then
    progress_put "$fgs_num" "$fgs_hash" "failed" "$SUITE_RESULT" "$VERIFY_RESULT" "the commit could not be created"
    return 1
  fi

  progress_put "$fgs_num" "$fgs_hash" "$fgs_state" "$SUITE_RESULT" "$VERIFY_RESULT" "$fgs_cause"
  [ "$fgs_state" = "done" ] && success "Slice $fgs_num: $fgs_title — COMPLETE ($(format_duration "$(($(date +%s) - fgs_started))"))"
  return 0
}

# ---------------------------------------------------------------------------
# Selection loop (T12, RF-34 c)
#
# The manifest is read over fd 3, in topological order: an engine session or a
# suite command that reads stdin cannot swallow the rest of the queue.
# ---------------------------------------------------------------------------

ordered_manifest_entries() {
  for ome_want in $TOPO_ORDER; do
    # shellcheck disable=SC2034  # every field must be named to be skipped
    while IFS='|' read -r ome_file ome_num ome_title ome_hash ome_braw; do
      [ -n "$ome_num" ] || continue
      [ "$ome_num" = "$ome_want" ] || continue
      printf '%s|%s|%s|%s|%s\n' "$ome_file" "$ome_num" "$ome_title" "$ome_hash" "$ome_braw"
    done <<EOF
$(manifest_entries)
EOF
  done
}

blockers_all_done() {
  for bad_dep in $(slice_blockers "$1"); do
    progress_is_done "$bad_dep" "$(manifest_hash_for "$bad_dep")" || return 1
  done
  return 0
}

execute_run() {
  er_seq=0
  er_ran=0

  # shellcheck disable=SC2034  # every field must be named to be skipped
  while IFS='|' read -r -u 3 er_file er_num er_title er_hash er_braw; do
    [ -n "$er_num" ] || continue
    er_seq=$((er_seq + 1))

    if [ -n "$ONLY_SLICE" ] && [ "$ONLY_SLICE" != "$er_num" ]; then
      continue
    fi

    # Only `done` is skipped from the record (RF-12). A recorded `blocked` or
    # `blocked-external` from an EARLIER run never skips anything: both are
    # recomputed for this run from the document itself, and RF-34d says they
    # are always re-executed.
    if progress_is_done "$er_num" "$er_hash"; then
      log "Skipping Slice $er_num: $er_title (already recorded done)"
      continue
    fi

    if in_list "$er_num" "$EXTERNALLY_BLOCKED" || in_list "$er_num" "$BLOCKED_SLICES"; then
      log "Skipping Slice $er_num: $er_title ($(progress_state "$er_num" "$er_hash") — $(progress_cause "$er_num" "$er_hash"))"
      continue
    fi

    if [ -z "$ONLY_SLICE" ] && ! blockers_all_done "$er_num"; then
      progress_put "$er_num" "$er_hash" "blocked" "disabled" "disabled" \
        "blocked by an unfinished blocker among: $(slice_field "$er_num" 5)"
      warn "Skipping Slice $er_num: $er_title (a blocker is not recorded done)"
      continue
    fi

    er_ran=$((er_ran + 1))
    if run_slice "$er_num" "$er_title" "$er_hash" "$er_seq" "$SLICE_COUNT"; then
      continue
    fi

    # RF-34 b: from here nothing downstream can ever have its blockers recorded
    # done, so the whole cone goes down with it, transitively and with zero
    # engine sessions.
    er_cone=$(mark_dependents_of_failure "$er_num")
    if [ -n "$er_cone" ]; then
      warn "Blocked by the failure of Slice $er_num (no engine session for any of them): $er_cone"
      for er_dep in $er_cone; do
        in_list "$er_dep" "$BLOCKED_SLICES" || BLOCKED_SLICES="$BLOCKED_SLICES $er_dep"
      done
    fi

    if [ "$KEEP_GOING" = true ]; then
      warn "--keep-going: moving on to the other branches of the graph"
    else
      warn "Stopping at the first failed issue (use --keep-going to carry on)"
      break
    fi
  done 3< <(ordered_manifest_entries)

  log "$er_ran issue(s) executed in this run"
}

# ---------------------------------------------------------------------------
# Final report and exit code (T12, RF-34 e)
#
# Non-zero if and only if some issue ended `failed` OR some issue ended
# `unverified`. `blocked`, `blocked-external` and a skipped publication never
# change it.
# ---------------------------------------------------------------------------

REPORT_FAILED=0
REPORT_UNVERIFIED=0

report_group() {
  rg_label="$1"
  rg_items="$2"
  rg_colour="$3"
  [ -n "$rg_items" ] || return 0
  rg_count=$(printf '%s\n' "$rg_items" | sed '/^$/d' | grep -c '' | tr -d ' ')
  echo ""
  printf '%b%s (%s):%b\n' "$rg_colour" "$rg_label" "$rg_count" "$NC"
  printf '%s\n' "$rg_items" | sed '/^$/d; s/^/    /'
}

final_report() {
  fr_done=""; fr_unverified=""; fr_failed=""; fr_blocked=""; fr_external=""; fr_untouched=""
  REPORT_FAILED=0
  REPORT_UNVERIFIED=0

  # shellcheck disable=SC2034  # every field must be named to be skipped
  while IFS='|' read -r fr_file fr_num fr_title fr_hash fr_braw; do
    [ -n "$fr_num" ] || continue
    fr_state=$(progress_state "$fr_num" "$fr_hash")
    fr_line="Slice $fr_num — $fr_title  (logs: $LOG_DIR/$(slice_stem "$fr_num").*)"
    case "$fr_state" in
      done)       fr_done="$fr_done$fr_line
" ;;
      unverified) fr_unverified="$fr_unverified$fr_line
"; REPORT_UNVERIFIED=$((REPORT_UNVERIFIED + 1)) ;;
      failed)     fr_failed="$fr_failed$fr_line
"; REPORT_FAILED=$((REPORT_FAILED + 1)) ;;
      blocked)    fr_blocked="$fr_blocked$fr_line
" ;;
      blocked-external) fr_external="$fr_external$fr_line
" ;;
      *)          fr_untouched="$fr_untouched$fr_line
" ;;
    esac
  done <<EOF
$(manifest_entries)
EOF

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "FINAL REPORT (engine: $ENGINE, input: $INPUT_FILE)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  report_group "done" "$fr_done" "$GREEN"
  report_group "unverified" "$fr_unverified" "$YELLOW"
  report_group "failed" "$fr_failed" "$RED"
  report_group "blocked" "$fr_blocked" "$YELLOW"
  report_group "blocked-external" "$fr_external" "$YELLOW"
  report_group "not reached" "$fr_untouched" "$BLUE"

  echo ""
  if [ "$REPORT_UNVERIFIED" -gt 0 ]; then
    warn "$REPORT_UNVERIFIED issue(s) recorded 'unverified': executed with no active mechanical gate, so never declared done."
  fi
  if [ "$REPORT_FAILED" -gt 0 ]; then
    fail "$REPORT_FAILED issue(s) recorded 'failed'."
  fi
  if [ -n "$fr_external" ]; then
    log "Externally blocked issues never change the exit code."
  fi
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

preflight() {
  case "$ENGINE" in
    codex | claude) ;;
    *)
      fail "Unknown engine: '$ENGINE'. Use --engine codex or --engine claude."
      exit 1
      ;;
  esac
  if ! is_positive_int "$MAX_CYCLES"; then
    fail "--max-cycles expects a positive integer, got: $MAX_CYCLES"
    exit 1
  fi
  if ! is_positive_int "$MAX_LIMIT_WAITS"; then
    fail "MS_LOOP_MAX_LIMIT_WAITS expects a positive integer, got: $MAX_LIMIT_WAITS"
    exit 1
  fi
  case "$VERIFY_MODE" in
    always | auto | off) ;;
    *)
      fail "MS_LOOP_VERIFY expects always, auto or off, got: $VERIFY_MODE"
      exit 1
      ;;
  esac

  require_git_worktree
  resolve_input_file
  scan_input
  resolve_state_dir
  exclude_state_dir
  require_clean_worktree

  success "Preflight OK (engine: $ENGINE, input: $INPUT_FILE, state: $STATE_DIR)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  m_started=$(date +%s)

  preflight
  split_slices
  validate_only_slice
  resolve_test_command
  resolve_verify_model
  warn_when_no_mechanical_validation
  print_run_plan

  execute_run
  final_report

  m_elapsed=$(($(date +%s) - m_started))
  log "Total time: $(format_duration "$m_elapsed")"

  if [ "$REPORT_FAILED" -gt 0 ] || [ "$REPORT_UNVERIFIED" -gt 0 ]; then
    fail "Run finished with $REPORT_FAILED failed and $REPORT_UNVERIFIED unverified issue(s)."
    exit 1
  fi

  success "Run finished: every executed issue is recorded done."
}

main
