#!/bin/bash
# Development helper used through the build watcher (./build.sh --git <action>).
#   fetch   — fetch origin and show what's on GitHub
#   merge   — merge origin/main (unrelated histories allowed; local files win on conflicts)
#   commit  — commit all changes with the message in build/.commit-msg
#   amend   — fold current changes into the last (unpushed) commit
#   push    — push main to origin
#   identity, squash-onto-remote — one-time setup helpers
#   status  — local status and recent log
set -o pipefail
cd "$(dirname "$0")/.."
action="$1"
case "$action" in
  fetch)
    git fetch origin 2>&1
    echo "== remote log"; git log --oneline -5 origin/main 2>&1
    echo "== remote files"; git ls-tree -r --name-only origin/main 2>&1 | head -50
    ;;
  merge)
    git merge origin/main --allow-unrelated-histories -X ours --no-edit \
      -m "Merge GitHub's initial commit" 2>&1
    ;;
  commit)
    git add -A 2>&1
    git commit -F build/.commit-msg 2>&1
    ;;
  amend)
    git add -A 2>&1 && git commit --amend --no-edit 2>&1 | tail -2
    ;;
  push)
    git push -u origin main 2>&1
    ;;
  identity)
    # Repo-local author = the GitHub account gh is logged in as, with its private noreply email.
    GH="$(command -v gh || echo /opt/homebrew/bin/gh)"
    [ -x "$GH" ] || GH="$HOME/.homebrew/bin/gh"
    login="$("$GH" api user --jq .login 2>&1)" || { echo "gh api failed: $login"; exit 1; }
    id="$("$GH" api user --jq .id)"
    name="$("$GH" api user --jq '.name // empty')"
    [ -n "$name" ] || name="$login"
    git config user.name "$name"
    git config user.email "${id}+${login}@users.noreply.github.com"
    echo "author: $(git config user.name) <$(git config user.email)>"
    ;;
  squash-onto-remote)
    # Replace unpushed local commits with one commit on top of origin/main (working tree unchanged).
    git reset --soft origin/main 2>&1 && git commit -F build/.commit-msg 2>&1
    ;;
  repo-info)
    GH="$(command -v gh || echo /opt/homebrew/bin/gh)"; [ -x "$GH" ] || GH="$HOME/.homebrew/bin/gh"
    "$GH" api users/millstonesolutions --jq '"account type: \(.type)"' 2>&1
    "$GH" api repos/millstonesolutions/Millstone-HX-Bridge --jq '"visibility: \(.visibility)  forking: \(.allow_forking)  permissions(me): \(.permissions)"' 2>&1
    "$GH" api repos/millstonesolutions/Millstone-HX-Bridge/collaborators --jq '.[] | "collaborator: \(.login) \(.role_name)"' 2>&1
    ;;
  status)
    git status --short 2>&1; echo "== log"; git log --oneline -8 2>&1
    ;;
  *) echo "unknown action: $action"; exit 2 ;;
esac
