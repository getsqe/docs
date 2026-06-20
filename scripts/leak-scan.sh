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
GLOB="${2:-*.md}"

# Case-insensitive leak regex (shared spec). jacobadmin/jacobbuilder matched
# specifically (NOT bare "jacob") to avoid false hits on an author byline.
# The 12-digit account-id rule is boundary-anchored so it does not substring-match
# inside longer digit runs (e.g. 19-digit Iceberg snapshot ids). The canonical
# placeholder account ids 123456789012 / 000000000000 are allowlisted below.
REGEX='(^|[^0-9])[0-9]{12}([^0-9]|$)|chore/|feat/|crates/sqe-|eu-(central|west)|amazonaws|MR !|sbp\.gitlab|gitlab\.schubergphilis|vpf-data-ai|jacobadmin|jacobbuilder'

# Collect hits. grep exits 1 when it finds nothing, which under `pipefail`
# would abort the script on the (desired) clean case, so guard with `|| true`.
hits=""
while IFS= read -r -d '' f; do
  file_hits="$(
    sed 's#crates/sqe-cli##g; s#crates/sqe-coordinator##g; s#123456789012##g; s#000000000000##g' "$f" \
      | grep -Ein "$REGEX" \
      | sed "s#^#${f}:#" \
      || true
  )"
  if [ -n "$file_hits" ]; then
    hits="${hits}${file_hits}"$'\n'
  fi
done < <(find "$DIR" -type f -name "$GLOB" -print0)

if [ -n "$hits" ]; then
  printf '%s' "$hits"
  exit 1
fi

exit 0
