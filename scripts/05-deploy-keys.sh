#!/usr/bin/env bash
# Sets up read-only deploy keys so this host can clone the private app repos.
#
# GitHub accepts a given deploy key on exactly one repository, so this makes
# one key per repo rather than a single shared key. Deploy keys are preferred
# over a personal access token here: they are scoped to one repo, read-only,
# and revoking one does not disturb anything else the account can reach.
#
#   bash scripts/05-deploy-keys.sh          # generate keys + print them
#   bash scripts/05-deploy-keys.sh --verify # test auth after registering them
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$(dirname "$DEPLOY_DIR")/src"
OWNER="${GITHUB_OWNER:-akneerajsharma}"
REPOS=(nirvana-backend nirvana-frontend)

mkdir -p ~/.ssh && chmod 700 ~/.ssh
touch ~/.ssh/config && chmod 600 ~/.ssh/config

if [[ "${1:-}" == "--verify" ]]; then
  fail=0
  for repo in "${REPOS[@]}"; do
    out=$(ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -T "git@github-$repo" 2>&1 || true)
    if grep -q "successfully authenticated" <<< "$out"; then
      echo "  OK   $repo"
    else
      echo "  FAIL $repo — $out"; fail=1
    fi
  done
  [[ $fail -eq 0 ]] && echo "All deploy keys working." || { echo "Register the keys above on GitHub first." >&2; exit 1; }
  exit 0
fi

for repo in "${REPOS[@]}"; do
  key=~/.ssh/${repo}_deploy
  [[ -f "$key" ]] || ssh-keygen -t ed25519 -f "$key" -C "$repo deploy key ($(hostname))" -N "" -q
  chmod 600 "$key"

  if ! grep -q "^Host github-$repo\$" ~/.ssh/config; then
    cat >> ~/.ssh/config <<CFG

Host github-$repo
    HostName github.com
    User git
    IdentityFile $key
    IdentitiesOnly yes
CFG
  fi
done

# .env drives which URL 20-deploy.sh clones from.
sed -i "s|^BACKEND_REPO=.*|BACKEND_REPO=git@github-nirvana-backend:$OWNER/nirvana-backend.git|" "$DEPLOY_DIR/.env"
sed -i "s|^WEB_REPO=.*|WEB_REPO=git@github-nirvana-frontend:$OWNER/nirvana-frontend.git|"      "$DEPLOY_DIR/.env"

# Repoint any clone that was already made over HTTPS.
for d in backend:nirvana-backend web:nirvana-frontend; do
  dir="$SRC_DIR/${d%%:*}"; repo="${d##*:}"
  [[ -d "$dir/.git" ]] && git -C "$dir" remote set-url origin "git@github-$repo:$OWNER/$repo.git"
done

echo
echo "════════════════════════════════════════════════════════════════════"
echo " Register each key below as a DEPLOY KEY on its own repo."
echo " Leave 'Allow write access' UNCHECKED — the server only ever reads."
echo "════════════════════════════════════════════════════════════════════"
for repo in "${REPOS[@]}"; do
  echo
  echo "── https://github.com/$OWNER/$repo/settings/keys/new"
  echo "   Title: $(hostname) deploy"
  cat ~/.ssh/${repo}_deploy.pub
done
echo
echo "════════════════════════════════════════════════════════════════════"
echo "Then verify:  bash scripts/05-deploy-keys.sh --verify"
