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
#   MS_LOOP_LABEL            triage label used when publishing issues
#                            (default: ready-for-agent)
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
  warn_when_no_mechanical_validation
  print_run_plan

  m_elapsed=$(($(date +%s) - m_started))
  success "Preflight and split complete in $(format_duration "$m_elapsed")"
}

main
