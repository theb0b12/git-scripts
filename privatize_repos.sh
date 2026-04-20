#!/usr/bin/env bash
# privatize_repos.sh
# Sets all repos from a list to private on their current account.
#
# USAGE:
#   ./privatize_repos.sh <repos_file>
#
# ARGS:
#   repos_file - Same file used for migration (one GitHub URL per line)
#
# REQUIREMENTS:
#   - gh CLI authenticated as the OLD account (theb0b12)

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <repos_file>"
  exit 1
fi

REPOS_FILE="$1"

if [[ ! -f "$REPOS_FILE" ]]; then
  error "Repos file not found: $REPOS_FILE"
  exit 1
fi

if ! gh auth status &>/dev/null; then
  error "gh CLI is not authenticated. Run: gh auth login"
  exit 1
fi

CURRENT_USER=$(gh api user --jq '.login')
info "Authenticated as: $CURRENT_USER"
echo ""
read -rp "$(echo -e "${YELLOW}Make sure you are logged in as the OLD account. Continue? [y/N]:${NC} ")" confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }

TOTAL=0; PASSED=0; FAILED=0
FAILED_REPOS=()

while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -z "$line" || "$line" == \#* ]] && continue

  # Extract owner/repo from URL
  REPO_PATH=$(echo "$line" | sed 's|https://github.com/||;s|\.git$||')

  TOTAL=$(( TOTAL + 1 ))
  info "Privatizing: $REPO_PATH"

  if ! gh repo edit "$REPO_PATH" --visibility private --accept-visibility-change-consequences 2>&1; then
    error "Failed to privatize $REPO_PATH"
    FAILED=$(( FAILED + 1 )); FAILED_REPOS+=("$REPO_PATH"); continue
  fi

  success "$REPO_PATH is now private ✓"
  PASSED=$(( PASSED + 1 ))

done < "$REPOS_FILE"

echo ""
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "Done."
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