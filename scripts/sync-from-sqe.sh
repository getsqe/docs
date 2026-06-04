#!/usr/bin/env bash
#
# Sync the public docs.getsqe.com mdBook site from the private SQE source repo.
#
# Copies book.toml, src/, and the mermaid assets out of the source repo,
# de-brands the copied book.toml, then runs the leak-scan gate over the synced
# src/ tree. If any leak remains the sync aborts (nothing is publishable).
#
# The source repo is treated as read-only and is never modified. Sanitization
# of leaks happens in the synced (local) copy, not here — re-running this script
# performs a destructive rsync --delete and would overwrite manual edits.
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

# Leak-scan gate over the synced src/ tree.
if ! hits="$(bash "$SCRIPT_DIR/leak-scan.sh" "$REPO_ROOT/src" '*.md')"; then
  echo "LEAK-SCAN FAILED — offending file:line:content below:" >&2
  printf '%s\n' "$hits" >&2
  exit 1
fi

echo "sync OK"
