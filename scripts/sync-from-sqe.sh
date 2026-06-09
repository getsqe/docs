#!/usr/bin/env bash
#
# Sync the public docs.getsqe.com mdBook site from the private SQE source repo.
#
# Copies book.toml, src/, and the mermaid assets out of the source repo,
# de-brands the copied book.toml, runs a deterministic sanitizer over the
# synced src/ tree, then runs the leak-scan gate. If any leak remains the sync
# aborts (nothing is publishable).
#
# The source repo is treated as read-only and is never modified. The rsync is
# destructive (--delete), so sanitization MUST be deterministic and live in
# this script — never hand-edit a synced file, it is clobbered on re-sync. If
# the gate trips on a new pattern, add a redaction rule below, never bypass it.
set -euo pipefail

SQE_DIR="${SQE_DIR:-/Users/jjverhoeks/git/schuberg/vpf-data-ai/chameleon/Applications/sqlengine}"

# Resolve the repo root as the script's parent dir's parent, so this works
# regardless of the caller's working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SRC_BOOK="$SQE_DIR/docs/book"

if [ ! -d "$SRC_BOOK" ]; then
  echo "error: source book dir not found: $SRC_BOOK" >&2
  exit 1
fi

echo "syncing from: $SRC_BOOK"
echo "into:         $REPO_ROOT"

# book.toml
cp "$SRC_BOOK/book.toml" "$REPO_ROOT/book.toml"

# src/ tree (mirror with delete so removed files do not linger)
rsync -a --delete "$SRC_BOOK/src/" "$REPO_ROOT/src/"

# mermaid assets at repo root
cp "$SRC_BOOK/mermaid.min.js" "$REPO_ROOT/mermaid.min.js"
cp "$SRC_BOOK/mermaid-init.js" "$REPO_ROOT/mermaid-init.js"

# De-brand the copied book.toml (BSD/macOS sed: use -i '' with explicit ext).
sed -i '' \
  -e 's#build-dir = "../../target/book"#build-dir = "./book"#' \
  -e 's#git-repository-url = "https://github.com/schuberg/sqe"#git-repository-url = "https://github.com/getsqe/docs"#' \
  -e 's#authors = \["VPF Data & AI"\]#authors = ["The SQE Project"]#' \
  "$REPO_ROOT/book.toml"

# --- Sanitize the synced src/ tree (deterministic, re-run safe) -------------
# Redacts internal detail from the SYNCED COPIES only (source untouched) so the
# leak gate below passes without hand-edits that the next rsync would clobber.
# Order matters: the 13+-digit example snapshot-id rule MUST run before the
# 12-digit account-id rule, or a 19-digit snapshot id gets mangled into
# "ACCOUNT_ID...". Internal crate paths lose only their `crates/` prefix
# (smallest diff, keeps useful file refs). The two PUBLIC crates that the gate
# allowlists — sqe-cli and sqe-coordinator — keep their full `crates/...` path
# verbatim (e.g. the `cargo install --path crates/sqe-cli` quick-start command
# must stay correct); they are protected with a sentinel across the strip.
#
# These are HEURISTICS, tuned to current source. They prefix-match and
# over-redact by design (fail safe): `[0-9]{13,}` rewrites ANY 13+-digit number
# to one fixed example snapshot id; `eu-central`/`eu-west` match any such prefix;
# the sentinel preserves only the two public crate prefixes. None over-match in
# today's source — but if a future re-sync mangles something unexpected, this is
# the first place to look.
echo "→ sanitizing synced src/ copies"
SANITIZE_FILES=()
while IFS= read -r -d '' f; do SANITIZE_FILES+=("$f"); done < <(
  find "$REPO_ROOT/src" -type f -name '*.md' -print0
)
sed -E -i '' \
  -e 's#crates/(sqe-cli|sqe-coordinator)#@@KEEP@@\1#g' \
  -e 's#crates/(sqe-[a-z-]*)#\1#g' \
  -e 's#@@KEEP@@(sqe-cli|sqe-coordinator)#crates/\1#g' \
  -e 's#[0-9]{13,}#8472810294#g' \
  -e 's#[0-9]{12}#ACCOUNT_ID#g' \
  -e 's#eu-central(-[0-9])?#eu-example-1#g' \
  -e 's#eu-west(-[0-9])?#eu-example-2#g' \
  -e 's#amazonaws\.com#aws-endpoint#g' \
  -e 's#amazonaws#aws#g' \
  -e 's#MR ![0-9]+#an earlier change#g' \
  -e 's#feat/[A-Za-z0-9._-]+#a feature branch#g' \
  -e 's#chore/[A-Za-z0-9._-]+#a maintenance branch#g' \
  -e 's#https?://sbp\.gitlab\.schubergphilis\.com[A-Za-z0-9._/-]*#https://github.com/schubergphilis/sqe#g' \
  -e 's#sbp\.gitlab\.schubergphilis\.com#github.com#g' \
  -e 's#vpf-data-ai/chameleon/applications/sqlengine#schubergphilis/sqe#g' \
  -e 's#jacobadmin#quickstart-admin#g' \
  -e 's#jacobbuilder#quickstart-builder#g' \
  "${SANITIZE_FILES[@]}"

# Leak-scan gate over the synced src/ tree.
if ! hits="$(bash "$SCRIPT_DIR/leak-scan.sh" "$REPO_ROOT/src" '*.md')"; then
  echo "LEAK-SCAN FAILED — offending file:line:content below:" >&2
  printf '%s\n' "$hits" >&2
  exit 1
fi

echo "sync OK"
