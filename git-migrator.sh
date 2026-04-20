#!/usr/bin/env bash
# git-migrator.sh
# Migrates a list of GitHub repos to a new account/org.
#
# USAGE:
#   ./git-migrator.sh <repos_file> <new_owner>
#
# ARGS:
#   repos_file   - Path to a file with one repo URL per line
#   new_owner    - New GitHub username or org to migrate repos into
#
# REQUIREMENTS:
#   - gh CLI installed and authenticated (gh auth login)
#   - git installed
#
# EXAMPLE repos.txt:
#   https://github.com/old-account/repo-one
#   https://github.com/old-account/repo-two

set -euo pipefail

# Colors ────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# Arg validation ─────────────────────────────────────────────────────────────
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <repos_file> <new_owner>"
  exit 1
fi

REPOS_FILE="$1"
NEW_OWNER="$2"

if [[ ! -f "$REPOS_FILE" ]]; then
  error "Repos file not found: $REPOS_FILE"
  exit 1
fi

# Dependency check
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

# Grab auth token from gh CLI 
GH_TOKEN=$(gh auth token)
if [[ -z "$GH_TOKEN" ]]; then
  error "Could not retrieve GitHub token from gh CLI."
  exit 1
fi
info "Auth token retrieved from gh CLI."

# Scratch dir 
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
info "Working directory: $WORKDIR"

# Counters
TOTAL=0; PASSED=0; FAILED=0
FAILED_REPOS=()

# Main loop 
while IFS= read -r line || [[ -n "$line" ]]; do
  # Strip whitespace, skip blanks and comments
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -z "$line" || "$line" == \#* ]] && continue

  SOURCE_URL="$line"
  REPO_NAME=$(basename "$SOURCE_URL" .git)
  # Authenticated push URL — embeds the token so git doesn't prompt
  DEST_URL="https://${NEW_OWNER}:${GH_TOKEN}@github.com/${NEW_OWNER}/${REPO_NAME}.git"
  DEST_DISPLAY="https://github.com/${NEW_OWNER}/${REPO_NAME}"

  TOTAL=$(( TOTAL + 1 ))
  echo ""
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info "Migrating: $REPO_NAME"
  info "  From : $SOURCE_URL"
  info "  To   : $DEST_DISPLAY"

  CLONE_DIR="$WORKDIR/$REPO_NAME"

  # 1. Mirror-clone the source (gets all branches, tags, refs)
  info "Cloning (mirror)…"
  if ! git clone --mirror "$SOURCE_URL" "$CLONE_DIR" 2>&1; then
    error "Clone failed for $REPO_NAME — skipping."
    FAILED=$(( FAILED + 1 )); FAILED_REPOS+=("$REPO_NAME"); continue
  fi

  # 2. Detect default branch
  DEFAULT_BRANCH=$(git -C "$CLONE_DIR" symbolic-ref HEAD 2>/dev/null | sed 's|refs/heads/||' || echo "main")
  info "Default branch detected: $DEFAULT_BRANCH"

  # 3. Create the new repo on GitHub (private by default; change to --public if needed)
  info "Creating GitHub repo: ${NEW_OWNER}/${REPO_NAME}…"
  if gh repo view "${NEW_OWNER}/${REPO_NAME}" &>/dev/null; then
    warn "Repo already exists on GitHub — will still push."
  else
    if ! gh repo create "${NEW_OWNER}/${REPO_NAME}" \
        --private \
        --description "Migrated from ${SOURCE_URL}" 2>&1; then
      error "Failed to create repo ${NEW_OWNER}/${REPO_NAME} — skipping."
      FAILED=$(( FAILED + 1 )); FAILED_REPOS+=("$REPO_NAME"); continue
    fi
    success "Repo created."
  fi

  # 4. Push everything (all refs) to the new remote using authenticated URL
  info "Pushing all refs…"
  if ! git -C "$CLONE_DIR" push --mirror "$DEST_URL" 2>&1; then
    error "Push failed for $REPO_NAME."
    FAILED=$(( FAILED + 1 )); FAILED_REPOS+=("$REPO_NAME"); continue
  fi

  # 5. Set the default branch on the new repo
  info "Setting default branch to '$DEFAULT_BRANCH'…"
  gh repo edit "${NEW_OWNER}/${REPO_NAME}" --default-branch "$DEFAULT_BRANCH" 2>/dev/null \
    || warn "Could not set default branch (may not exist yet if repo was empty)."

  success "Migrated $REPO_NAME ✓"
  PASSED=$(( PASSED + 1 ))

done < "$REPOS_FILE"

# Summary
echo ""
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "Migration complete."
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