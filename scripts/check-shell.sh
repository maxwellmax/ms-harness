#!/usr/bin/env bash
#
# check-shell.sh — shell sanity for the harness scripts.
#
#   1. bash -n over every target script (always runs; needs bash only)
#   2. shellcheck when available (dev-only; its absence NEVER fails the check)
#   3. portability audit: rejects bash-4-only and GNU-only constructs, because
#      the supported hosts are Linux and macOS as they ship, and the macOS
#      factory bash is 3.2 with a BSD userland.
#
# Usage: scripts/check-shell.sh [file.sh ...]
#        With no argument it checks scripts/*.sh from the repository root.
#        Exit 0 = clean.
#
# This script obeys its own audit and excludes itself from the literal scan of
# step 3: it carries the forbidden constructs as data in the audit table below,
# so scanning itself would report its own rule table as violations.

set -u

canonical_path() {
  cp_dir=$(dirname "$1")
  cp_base=$(basename "$1")
  if cd "$cp_dir" 2>/dev/null; then
    printf '%s/%s\n' "$(pwd -P)" "$cp_base"
    cd - > /dev/null 2>&1 || true
  else
    printf '%s\n' "$1"
  fi
}

SELF=$(canonical_path "$0")

FILES=""
FILE_COUNT=0
add_file() {
  FILES="$FILES$1
"
  FILE_COUNT=$((FILE_COUNT + 1))
}

if [ "$#" -gt 0 ]; then
  for arg in "$@"; do
    add_file "$(canonical_path "$arg")"
  done
else
  cd "$(dirname "$0")/.." || exit 1
  for f in scripts/*.sh; do
    [ -e "$f" ] || continue
    add_file "$f"
  done
fi

if [ "$FILE_COUNT" -eq 0 ]; then
  echo "FAIL: no shell script to check."
  exit 1
fi

FAIL=0

echo "== bash -n ($FILE_COUNT files)"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if [ ! -f "$f" ]; then
    echo "  ERROR $f  <- file not found"
    FAIL=1
    continue
  fi
  if bash -n "$f" 2> /dev/null; then
    echo "  ok    $f"
  else
    echo "  ERROR $f"
    bash -n "$f" 2>&1 | sed 's/^/        /'
    FAIL=1
  fi
done <<EOF
$FILES
EOF

echo
if command -v shellcheck > /dev/null 2>&1; then
  echo "== shellcheck"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    if shellcheck -x -S warning "$f"; then
      echo "  ok    $f"
    else
      FAIL=1
    fi
  done <<EOF
$FILES
EOF
else
  echo "== shellcheck ABSENT — skipped (never fails the check)"
fi

# ---------------------------------------------------------------------------
# Portability audit.
#
# Table format, one rule per line: <label> :: <violation ERE> [:: <allowed ERE>]
# A line matching the violation ERE fails, unless it also matches the optional
# allowed ERE. Kept as data so the forbidden construct list is auditable by
# reading it, not by reading a chain of conditionals.
# ---------------------------------------------------------------------------
audit_file() {
  af_file=$1
  af_found=0
  while IFS= read -r rule; do
    case "$rule" in
      '' | '#'*) continue ;;
    esac
    af_label=${rule%% :: *}
    af_rest=${rule#* :: }
    af_pat=${af_rest%% :: *}
    af_allow=${af_rest#* :: }
    if [ "$af_allow" = "$af_rest" ]; then
      af_allow=""
    fi
    if [ -n "$af_allow" ]; then
      af_hits=$(grep -nE "$af_pat" "$af_file" | grep -vE "$af_allow")
    else
      af_hits=$(grep -nE "$af_pat" "$af_file")
    fi
    if [ -n "$af_hits" ]; then
      af_found=1
      printf '%s\n' "$af_hits" | sed "s|^|        $af_file:|; s|\$|  <- $af_label|"
    fi
  done <<'RULES'
declare -A (bash 4 associative array) :: (^|[^[:alnum:]_./-])(declare|typeset|local)[[:space:]]+-[A-Za-z]*A([[:space:]]|$)
mapfile (bash 4 builtin) :: (^|[^[:alnum:]_./-])mapfile([^[:alnum:]_]|$)
readarray (bash 4 builtin) :: (^|[^[:alnum:]_./-])readarray([^[:alnum:]_]|$)
${var,,} (bash 4 case expansion) :: \$\{[^}]*,,[^}]*\}
${var^^} (bash 4 case expansion) :: \$\{[^}]*\^\^[^}]*\}
date -d (GNU-only date) :: (^|[^[:alnum:]_./-])date[[:space:]]+-d([[:space:]]|$)
date --date (GNU-only date) :: (^|[^[:alnum:]_./-])date[[:space:]]+--date
sed -i without a backup suffix (GNU-only form) :: (^|[^[:alnum:]_./-])sed[[:space:]]+-i([[:space:]]|$) :: sed[[:space:]]+-i[[:space:]]+(''|"")([[:space:]]|$)
grep -P (GNU-only PCRE) :: (^|[^[:alnum:]_./-])grep[[:space:]]+-[A-Za-z]*P
xargs -r (GNU-only no-run-if-empty) :: (^|[^[:alnum:]_./-])xargs[[:space:]]+-[A-Za-z]*r([[:space:]]|$)
RULES
  return "$af_found"
}

echo
echo "== portability audit (bash 3.2 / BSD userland)"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  if [ "$(canonical_path "$f")" = "$SELF" ]; then
    echo "  skip  $f  <- self-excluded from the literal scan"
    continue
  fi
  if af_out=$(audit_file "$f"); then
    echo "  ok    $f"
  else
    echo "  ERROR $f"
    printf '%s\n' "$af_out"
    FAIL=1
  fi
done <<EOF
$FILES
EOF

echo
if [ "$FAIL" -eq 0 ]; then
  echo "OK: shell clean."
else
  echo "FAIL: fix the problems above."
fi
exit "$FAIL"
