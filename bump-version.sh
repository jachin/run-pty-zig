#!/usr/bin/env bash
#
# bump-version.sh — bump the run-pty-zig version everywhere it is set, then
# offer to commit, push, tag, and push the tag.
#
# Usage:
#   ./bump-version.sh major   # 0.1.2 -> 1.0.0
#   ./bump-version.sh minor   # 0.1.2 -> 0.2.0
#   ./bump-version.sh bug     # 0.1.2 -> 0.1.3   ("patch" also accepted)
#
# The version is updated in:
#   - src/root.zig                    (pub const version + the version test)
#   - build.zig.zon                   (.version field)
#   - README.md                       (**Version X.Y.Z**)
#   - homebrew/run-pty.rb             (formula url + version)
#   - homebrew-run-pty-zig/run-pty.rb (Homebrew tap formula — separate repo)
#
# Flow:
#   1. If there are uncommitted changes, ask whether to continue (recommends no).
#   2. Update the version in the files above.
#   3. Ask to commit the main repo  -> "Bump version to X.Y.Z"
#   4. Ask to push the main repo
#   5. Ask to create tag vX.Y.Z
#   6. Ask to push the tag
#   7. If the tap repo is present: ask to commit -> "Bump run-pty to X.Y.Z",
#      then ask to push it.

set -euo pipefail

# --- Resolve the repo root (the directory containing this script) ---
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

TAP_DIR="homebrew-run-pty-zig"

# --- Terminal colors (only when stdout is a TTY) ---
if [ -t 1 ]; then
  GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  GREEN=""; RED=""; YELLOW=""; BOLD=""; RESET=""
fi

info() { printf '%s\n' "${BOLD}${*}${RESET}"; }
ok()   { printf '%s\n' "${GREEN}  ✓ ${*}${RESET}"; }
warn() { printf '%s\n' "${YELLOW}  ⚠ ${*}${RESET}"; }
err()  { printf '%s\n' "${RED}  ✗ ${*}${RESET}" >&2; }

# --- Ask a yes/no question. Returns 0 for yes, 1 for no. ---
# Usage: ask "question" [default]   (default: "y" or "n")
ask() {
  local prompt="$1" default="${2:-n}" answer suffix
  if [ "$default" = "y" ]; then suffix=" [Y/n]"; else suffix=" [y/N]"; fi
  printf '%s%s: ' "$prompt" "$suffix"
  read -r answer || answer=""
  answer="${answer:-$default}"
  case "$answer" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# --- Literal in-file replacement (old -> new, all occurrences). ---
# perl's \Q...\E treats the old string literally (so dots are not wildcards).
replace_in_file() {
  local file="$1" old="$2" new="$3"
  if [ ! -f "$file" ]; then
    err "missing file: $file"
    return 1
  fi
  perl -i -pe "s/\Q${old}\E/${new}/g" "$file"
}

# --- Set the .version field in build.zig.zon to a specific value, regardless
# --- of its current value (it may still be the 0.0.0 placeholder). Only the
# --- .version line is touched; .minimum_zig_version and comments are left alone.
set_zon_version() {
  local file="$1" new="$2"
  if [ ! -f "$file" ]; then
    err "missing file: $file"
    return 1
  fi
  NEW_VERSION="$new" perl -i -pe 's/(\.version = ")[^"]*(")/.version = "$ENV{NEW_VERSION}"/' "$file"
}

# --- 1. Argument ---
if [ "$#" -ne 1 ]; then
  err "Usage: $0 {major|minor|bug}"
  err "  major  -> next major   (0.1.2 -> 1.0.0)"
  err "  minor  -> next minor   (0.1.2 -> 0.2.0)"
  err "  bug    -> next patch   (0.1.2 -> 0.1.3)   [\"patch\" also accepted]"
  exit 1
fi
KIND="$1"
case "$KIND" in
  major|minor) ;;
  bug|patch) KIND="bug" ;;
  *) err "Unknown bump kind '$KIND' (expected: major, minor, or bug)"; exit 1 ;;
esac

# --- 2. Read the current version from src/root.zig (source of truth) ---
CURRENT="$(grep -oE 'pub const version = "[0-9]+\.[0-9]+\.[0-9]+"' src/root.zig \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
if [ -z "$CURRENT" ]; then
  err "Could not find 'pub const version = \"X.Y.Z\"' in src/root.zig"
  exit 1
fi
MAJOR="${CURRENT%%.*}"
REST="${CURRENT#*.}"
MINOR="${REST%%.*}"
PATCH="${REST#*.}"

# --- 3. Compute the new version ---
case "$KIND" in
  major) NEW="$((MAJOR + 1)).0.0" ;;
  minor) NEW="${MAJOR}.$((MINOR + 1)).0" ;;
  bug)   NEW="${MAJOR}.${MINOR}.$((PATCH + 1))" ;;
esac

info "Bumping ${CURRENT} -> ${NEW}  (${KIND})"
echo

# --- 4. Pre-flight: uncommitted changes? (main repo and, if present, the tap) ---
dirty=""
if [ -n "$(git status --porcelain)" ]; then
  dirty="the main repo"
fi
if [ -d "$TAP_DIR/.git" ] && [ -n "$(git -C "$TAP_DIR" status --porcelain)" ]; then
  if [ -n "$dirty" ]; then dirty="$dirty and the tap repo"; else dirty="the tap repo"; fi
fi
if [ -n "$dirty" ]; then
  warn "Uncommitted changes detected in: ${dirty}"
  warn "It is recommended to commit or stash them first so the version bump stays a clean commit."
  if ! ask "Continue anyway?" "n"; then
    info "Aborting — no changes were made."
    exit 0
  fi
  echo
fi

# --- 5. Update the version in every place it is set ---
info "Updating version:"
replace_in_file "src/root.zig" "$CURRENT" "$NEW"
ok "src/root.zig"
set_zon_version "build.zig.zon" "$NEW"
ok "build.zig.zon"
replace_in_file "README.md" "$CURRENT" "$NEW"
ok "README.md"
replace_in_file "homebrew/run-pty.rb" "$CURRENT" "$NEW"
ok "homebrew/run-pty.rb"
if [ -f "$TAP_DIR/run-pty.rb" ]; then
  replace_in_file "$TAP_DIR/run-pty.rb" "$CURRENT" "$NEW"
  ok "$TAP_DIR/run-pty.rb"
fi
echo

# --- 6. Main repo: commit -> push -> tag -> push tag ---
if ask "Commit the version bump to git?" "y"; then
  if git add src/root.zig build.zig.zon README.md homebrew/run-pty.rb \
     && git commit -m "Bump version to ${NEW}"; then
    ok "Committed: Bump version to ${NEW}"
  else
    warn "Commit failed (check 'git status')."
  fi
else
  warn "Skipped commit — changes are left in the working tree."
fi

if ask "Push the changes?" "y"; then
  if git push origin HEAD; then ok "Pushed."; else warn "Push failed (you can retry later)."; fi
else
  warn "Skipped push."
fi

TAG="v${NEW}"
TAG_EXISTS=0
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null 2>&1; then TAG_EXISTS=1; fi

if ask "Create tag ${TAG}?" "y"; then
  if [ "$TAG_EXISTS" = "1" ]; then
    warn "Tag ${TAG} already exists."
  elif git tag "${TAG}"; then
    ok "Created tag ${TAG}"
    TAG_EXISTS=1
  else
    warn "Failed to create tag ${TAG}."
  fi
fi

if [ "$TAG_EXISTS" = "1" ]; then
  if ask "Push tag ${TAG}?" "y"; then
    if git push origin "${TAG}"; then ok "Pushed tag ${TAG}."; else warn "Failed to push tag ${TAG}."; fi
  else
    warn "Skipped pushing tag."
  fi
fi

# --- 7. Homebrew tap (a separate git repo): commit -> push ---
if [ -d "$TAP_DIR/.git" ]; then
  echo
  info "The Homebrew tap (${TAP_DIR}) is a separate repo."
  if ask "Commit the tap formula update?" "y"; then
    if git -C "$TAP_DIR" add run-pty.rb && git -C "$TAP_DIR" commit -m "Bump run-pty to ${NEW}"; then
      ok "Committed tap: Bump run-pty to ${NEW}"
    else
      warn "Tap commit failed (check 'git -C ${TAP_DIR} status')."
    fi
  else
    warn "Skipped tap commit — changes are left in the tap's working tree."
  fi
  if ask "Push the tap?" "y"; then
    if git -C "$TAP_DIR" push origin HEAD; then ok "Pushed tap."; else warn "Tap push failed (you can retry later)."; fi
  else
    warn "Skipped tap push."
  fi
fi

echo
ok "Done. New version: ${NEW}"
