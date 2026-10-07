#!/usr/bin/env bash
# Install a pre-commit hook that runs scripts/check-obi.sh whenever patches/ or
# obi/ are part of the commit, so a stale or hand-edited obi/ never gets committed.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
hook="$(git -C "$ROOT" rev-parse --git-path hooks)/pre-commit"
cat > "$hook" <<'EOF'
#!/usr/bin/env bash
if git diff --cached --name-only | grep -q -E '^(patches|obi)/'; then
  root=$(git rev-parse --show-toplevel)
  # checks the working tree: stage everything you changed in patches/ and obi/
  "$root/scripts/check-obi.sh" || exit 1
fi
EOF
chmod +x "$hook"
echo "installed $hook"
