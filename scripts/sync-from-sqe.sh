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

# No default: this repo is public, and the real path discloses internal
# usernames/group layout. A missing SQE_DIR fails loudly instead.
SQE_DIR="${SQE_DIR:?set SQE_DIR to your local sqe checkout}"

# Resolve the repo root as the script's parent dir's parent, so this works
# regardless of the caller's working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SRC_BOOK="$SQE_DIR/docs/site/book"

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

# Overlay the curated OVERVIEW.md onto each per-quickstart book page (single
# source of truth). Index + Quack reference pages are left as authored.
echo "→ overlaying quickstart OVERVIEW pages"
for ov in "$SQE_DIR"/quickstart/*/OVERVIEW.md; do
  n="$(basename "$(dirname "$ov")")"
  [[ -f "$REPO_ROOT/src/quickstart/$n.md" ]] && cp "$ov" "$REPO_ROOT/src/quickstart/$n.md"
done

# mermaid assets at repo root
cp "$SRC_BOOK/mermaid.min.js" "$REPO_ROOT/mermaid.min.js"
cp "$SRC_BOOK/mermaid-init.js" "$REPO_ROOT/mermaid-init.js"

# De-brand the copied book.toml (BSD/macOS sed: use -i '' with explicit ext).
sed -i '' \
  -e 's#build-dir = "../../target/book"#build-dir = "./book"#' \
  -e 's#git-repository-url = "https://github.com/schuberg/sqe"#git-repository-url = "https://github.com/getsqe/docs"#' \
  -e 's#authors = \["VPF Data & AI"\]#authors = ["The SQE Project"]#' \
  "$REPO_ROOT/book.toml"

# --- Cosmetic normalization of the synced src/ tree (deterministic, re-run safe) -
# COSMETIC ONLY. Secrets/PII (account ids, personal IAM names, the internal
# GitLab host, the monorepo path) are now fixed at SOURCE in docs/site/book --
# the SQE repo's scripts/leak-scan-site.sh enforces that -- so the security
# redaction rules (incl. the 12-digit account-id rule and its 13+-digit ordering
# guard) were retired here. What remains is presentation normalization that keeps
# internal traceability out of the public copies: internal crate paths lose their
# `crates/` prefix (the public sqe-cli / sqe-coordinator keep theirs via a
# sentinel), regions/endpoints become placeholders, and MR/branch refs become
# generic phrasing. (MR/branch rewrites retire once design-note MR refs are
# backfilled to permalinks.) The leak-scan gate below stays as the publish guard.
echo "→ normalizing synced src/ copies"
SANITIZE_FILES=()
while IFS= read -r -d '' f; do SANITIZE_FILES+=("$f"); done < <(
  find "$REPO_ROOT/src" -type f -name '*.md' -print0
)
sed -E -i '' \
  -e 's#crates/(sqe-cli|sqe-coordinator)#@@KEEP@@\1#g' \
  -e 's#crates/(sqe-[a-z-]*)#\1#g' \
  -e 's#@@KEEP@@(sqe-cli|sqe-coordinator)#crates/\1#g' \
  -e 's#eu-central(-[0-9])?#eu-example-1#g' \
  -e 's#eu-west(-[0-9])?#eu-example-2#g' \
  -e 's#amazonaws\.com#aws-endpoint#g' \
  -e 's#amazonaws#aws#g' \
  -e 's#MR ![0-9]+#an earlier change#g' \
  -e 's#feat/[A-Za-z0-9._-]+#a feature branch#g' \
  -e 's#chore/[A-Za-z0-9._-]+#a maintenance branch#g' \
  "${SANITIZE_FILES[@]}"

# Leak-scan gate over the synced src/ tree.
if ! hits="$(bash "$SCRIPT_DIR/leak-scan.sh" "$REPO_ROOT/src" '*.md')"; then
  echo "LEAK-SCAN FAILED — offending file:line:content below:" >&2
  printf '%s\n' "$hits" >&2
  exit 1
fi

echo "sync OK"
