#!/usr/bin/env bash
#
# Shared leak-scan gate for docs.getsqe.com.
#
# Scans a directory tree for strings that must never appear in the public
# docs: AWS account ids (12-digit numbers), internal branch names, internal
# crate paths, AWS region strings and amazonaws hostnames, and merge-request
# references.
#
# Usage:
#   leak-scan.sh <dir> [glob]
#     <dir>   directory to scan (required)
#     [glob]  file name pattern to scan (default: *.md)
#
# Allowlist: the public crate paths `crates/sqe-cli` and `crates/sqe-coordinator`
# legitimately appear in public docs and are stripped from each line before the
# regex is applied, so they never count as leaks.
#
# Prints offending "file:line:content" hits to stdout and exits 1 if any are
# found; prints nothing and exits 0 when the tree is clean.
set -euo pipefail

DIR="${1:?usage: leak-scan.sh <dir> [glob]}"
GLOB="${2:-}"

# Text extensions that reach the published output, used when no explicit glob
# is given. Keep in sync across the three site gates; a gap here is silent.
#
# .js is the one that matters most here and was the original gap: mdBook emits
# `searchindex-<hash>.js`, a multi-megabyte full-text index of every page. The
# deploy workflow used to pass '*.html', so that index was never scanned — a
# leaked string would have been invisible to the gate and still retrievable
# through the docs search box.
SCAN_EXTS=(md mdx json html svg js mjs xml txt yml yaml css toml sh)

# Case-insensitive leak regex (shared spec). jacobadmin/jacobbuilder matched
# specifically (NOT bare "jacob") to avoid false hits on an author byline.
# The 12-digit account-id rule is boundary-anchored so it does not substring-match
# inside longer digit runs (e.g. 19-digit Iceberg snapshot ids). The canonical
# placeholder account ids 123456789012 / 000000000000 are allowlisted below.
REGEX='(^|[^0-9])[0-9]{12}([^0-9]|$)|chore/|feat/|crates/sqe-|eu-(central|west)|amazonaws|MR !|sbp\.gitlab|gitlab\.schubergphilis|vpf-data-ai|jacobadmin|jacobbuilder'

# .sh files get a NARROWER rule set: only internal-identifier/path rules, not
# content rules (eu-region, amazonaws, crate paths). Sync scripts legitimately
# describe those redaction TARGETS in their own sed commands and comments,
# which would otherwise self-trigger the moment .sh became scannable. The
# identifier rules below have no such legitimate occurrence — they exist to
# catch exactly the hardcoded-checkout-path class of leak this rule set was
# widened for. `/Users/[a-z]+/git` is .sh-ONLY: it would false-positive on
# ordinary published prose (e.g. a quickstart line showing a local checkout
# path) that has nothing to do with the maintainer's own machine.
SH_REGEX='(^|[^0-9])[0-9]{12}([^0-9]|$)|sbp\.gitlab|gitlab\.schubergphilis|vpf-data-ai|jacobadmin|jacobbuilder|/Users/[a-z]+/git'

# The gate's own pattern-definition file is exempt by its OWN PATH (not a bare
# basename match, which would also skip any synced file that happened to be
# named identically): its entire purpose is to contain the literal strings
# above as regex source, which is not a real disclosure — no different from a
# scanner's own signature file containing its signatures. Nothing else is
# exempt.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# Collect hits. grep exits 1 when it finds nothing, which under `pipefail`
# would abort the script on the (desired) clean case, so guard with `|| true`.
if [ -n "$GLOB" ]; then
  find_expr=(-name "$GLOB")
else
  find_expr=()
  for ext in "${SCAN_EXTS[@]}"; do
    [ ${#find_expr[@]} -eq 0 ] || find_expr+=(-o)
    find_expr+=(-name "*.${ext}")
  done
  find_expr=(\( "${find_expr[@]}" \))
fi

hits=""
scanned=0
while IFS= read -r -d '' f; do
  resolved_f="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
  [ "$resolved_f" = "$SELF" ] && continue
  scanned=$((scanned + 1))
  re="$REGEX"
  case "$f" in
    *.sh) re="$SH_REGEX" ;;
  esac
  file_hits="$(
    sed 's#crates/sqe-cli##g; s#crates/sqe-coordinator##g; s#123456789012##g; s#000000000000##g' "$f" \
      | grep -Ein "$re" \
      | sed "s#^#${f}:#" \
      || true
  )"
  if [ -n "$file_hits" ]; then
    hits="${hits}${file_hits}"$'\n'
  fi
done < <(find "$DIR" -type f "${find_expr[@]}" -print0)

if [ -n "$hits" ]; then
  printf '%s' "$hits"
  exit 1
fi

# A scan that matched nothing looks exactly like a clean one here (this gate is
# silent on success by design), and a wrong path is an easy mistake. Fail loudly
# on stderr instead, so a caller capturing stdout still sees the non-zero exit.
if [ "$scanned" -eq 0 ]; then
  echo "leak-scan: matched 0 files under '$DIR'${GLOB:+ (glob $GLOB)} — refusing to report clean" >&2
  exit 2
fi

exit 0
