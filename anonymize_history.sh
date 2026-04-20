#!/usr/bin/env bash
# anonymize_history.sh
# Rewrites all commits in every repo from repos.txt to use the new account's
# identity, then force-pushes to the new account.
#
# USAGE:
#   ./anonymize_history.sh <repos_file> <old_owner> <new_owner> <new_name> <new_email>
#
# EXAMPLE:
#   ./anonymize_history.sh repos.txt theb0b12 theb0b "Bob" "bob@example.com"
#
# REQUIREMENTS:
#   - gh CLI authenticated as the NEW account
#   - git installed

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# ── Args ───────────────────────────────────────────────────────────────────────
if [[ $# -lt 5 ]]; then
  echo "Usage: $0 <repos_file> <old_owner> <new_owner> <new_name> <new_email>"
  exit 1
fi

REPOS_FILE="$1"
OLD_OWNER="$2"
NEW_OWNER="$3"
NEW_NAME="$4"
NEW_EMAIL="$5"

if [[ ! -f "$REPOS_FILE" ]]; then
  error "Repos file not found: $REPOS_FILE"
  exit 1
fi

for cmd in git gh; do
  if ! command -v "$cmd" &>/dev/null; then
    error "'$cmd' is not installed or not in PATH."
    exit 1
  fi
done

if ! gh auth status &>/dev/null; then
  error "gh CLI is not authenticated. Run: gh auth login"
  exit 1
fi

CURRENT_USER=$(gh api user --jq '.login')
info "Authenticated as: $CURRENT_USER"
info "Rewriting commits to: \"$NEW_NAME\" <$NEW_EMAIL>"
echo ""
read -rp "$(echo -e "${YELLOW}This will rewrite ALL commit history on the new account's repos. Continue? [y/N]:${NC} ")" confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }

GH_TOKEN=$(gh auth token)
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
info "Working directory: $WORKDIR"

TOTAL=0; PASSED=0; FAILED=0
FAILED_REPOS=()

while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -z "$line" || "$line" == \#* ]] && continue

  # Repo name from the source URL — same name on new account
  REPO_NAME=$(basename "$line" .git)
  DEST_REPO="${NEW_OWNER}/${REPO_NAME}"
  CLONE_URL="https://${NEW_OWNER}:${GH_TOKEN}@github.com/${DEST_REPO}.git"

  TOTAL=$(( TOTAL + 1 ))
  echo ""
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info "Processing: $DEST_REPO"

  CLONE_DIR="$WORKDIR/$REPO_NAME"

  # 1. Clone the repo from the new account
  info "Cloning from new account…"
  if ! git clone --no-local "$CLONE_URL" "$CLONE_DIR" 2>&1; then
    error "Clone failed — skipping."
    FAILED=$(( FAILED + 1 )); FAILED_REPOS+=("$REPO_NAME"); continue
  fi

  cd "$CLONE_DIR"

  # 2. Fetch all remote branches so we rewrite everything
  git fetch --all 2>&1

  # 3. Rewrite every branch and tag using git filter-branch
  #    Replaces author + committer name/email on all commits across all refs
  info "Rewriting commit history…"
  if ! git filter-branch --force \
    --env-filter "
      export GIT_AUTHOR_NAME=\"${NEW_NAME}\"
      export GIT_AUTHOR_EMAIL=\"${NEW_EMAIL}\"
      export GIT_COMMITTER_NAME=\"${NEW_NAME}\"
      export GIT_COMMITTER_EMAIL=\"${NEW_EMAIL}\"
    " \
    --msg-filter "
      sed -E \"s|'[^']*${OLD_OWNER}[^']*'|'|g; s|https://github\\.com/${OLD_OWNER}/[^ ]+||g\"
    " \
    --tag-name-filter cat -- --all 2>&1; then
    error "History rewrite failed — skipping."
    cd "$WORKDIR"
    FAILED=$(( FAILED + 1 )); FAILED_REPOS+=("$REPO_NAME"); continue
  fi

  # 4. Force-push all refs back to the new account
  info "Force-pushing rewritten history…"
  if ! git push --force --all "$CLONE_URL" 2>&1; then
    error "Push (branches) failed — skipping."
    cd "$WORKDIR"
    FAILED=$(( FAILED + 1 )); FAILED_REPOS+=("$REPO_NAME"); continue
  fi

  # Push rewritten tags too
  git push --force --tags "$CLONE_URL" 2>&1 || warn "Tag push failed (non-fatal)."

  success "Done: $REPO_NAME ✓"
  PASSED=$(( PASSED + 1 ))
  cd "$WORKDIR"

done < "$REPOS_FILE"

echo ""
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "All done."
echo -e "  Total : $TOTAL"
echo -e "  ${GREEN}Passed${NC}: $PASSED"
echo -e "  ${RED}Failed${NC}: $FAILED"
if [[ ${#FAILED_REPOS[@]} -gt 0 ]]; then
  echo ""
  error "Failed repos:"
  for r in "${FAILED_REPOS[@]}"; do
    echo -e "    ${RED}✗${NC} $r"
  done
  exit 1
fi