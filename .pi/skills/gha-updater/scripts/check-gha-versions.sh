#!/usr/bin/env bash
# Check GitHub Actions versions against latest releases.
# Usage: check-gha-versions.sh [--update]
set -euo pipefail

UPDATE=false
if [ "${1:-}" = "--update" ]; then
  UPDATE=true
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
WORKFLOW_DIR="$REPO_ROOT/.github/workflows"

if [ ! -d "$WORKFLOW_DIR" ]; then
  echo "No .github/workflows directory found"
  exit 1
fi

get_latest_tag() {
  local owner_repo="$1"  # e.g. "actions/checkout"
  local api_url="https://api.github.com/repos/$owner_repo/releases/latest"
  local tag

  if [ -n "${GITHUB_TOKEN:-}" ]; then
    tag=$(curl -sL -H "Authorization: Bearer $GITHUB_TOKEN" "$api_url" | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null || echo "")
  else
    tag=$(curl -sL "$api_url" | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null || echo "")
  fi

  if [ -z "$tag" ]; then
    # Fallback: try list endpoint
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      tag=$(curl -sL -H "Authorization: Bearer $GITHUB_TOKEN" "https://api.github.com/repos/$owner_repo/releases?per_page=1" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['tag_name'])" 2>/dev/null || echo "")
    else
      tag=$(curl -sL "https://api.github.com/repos/$owner_repo/releases?per_page=1" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['tag_name'])" 2>/dev/null || echo "")
    fi
  fi

  echo "$tag"
}

HAD_STALE=false

for workflow in "$WORKFLOW_DIR"/*.yml; do
  name=$(basename "$workflow")
  echo "=== $name ==="

  # Extract all uses: lines with @version
  while IFS= read -r line; do
    # Parse: owner/repo@version or path
    uses=$(echo "$line" | sed -n 's/.*uses: *//p' | xargs)
    [ -z "$uses" ] && continue

    # Skip local path actions (they don't have @)
    case "$uses" in
      *@*) ;;
      *) continue ;;
    esac

    owner_repo="${uses%@*}"
    current_ver="${uses#*@}"

    # Skip non-GitHub actions (./path or docker://)
    case "$owner_repo" in
      */*) ;;
      *) continue ;;
    esac
    case "$owner_repo" in
      ./*|docker://*) continue ;;
    esac

    latest_tag=$(get_latest_tag "$owner_repo")

    if [ -z "$latest_tag" ]; then
      echo "  ? $owner_repo@$current_ver (could not fetch latest)"
      continue
    fi

    if [ "$latest_tag" != "$current_ver" ]; then
      echo "  outdated: $owner_repo@$current_ver → $latest_tag"
      HAD_STALE=true

      if $UPDATE; then
        # Replace in file
        if [[ "$(uname)" == "darwin" ]]; then
          sed -i "" "s|uses: $owner_repo@$current_ver|uses: $owner_repo@$latest_tag|g" "$workflow"
        else
          sed -i "s|uses: $owner_repo@$current_ver|uses: $owner_repo@$latest_tag|g" "$workflow"
        fi
        echo "    ✓ updated"
      fi
    else
      echo "  up to date: $owner_repo@$current_ver"
    fi
  done < <(grep -rn "uses:" "$workflow" || true)

  echo ""
done

if $HAD_STALE; then
  if ! $UPDATE; then
    echo "Run with --update to apply updates, or check individual releases for breaking changes."
  fi
  exit 0
else
  echo "All actions up to date."
fi
