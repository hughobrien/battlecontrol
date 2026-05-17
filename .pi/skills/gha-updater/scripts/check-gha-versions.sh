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

# Cache resolved tags: owner_repo -> latest_tag
declare -A TAG_CACHE

get_latest_tag() {
  local owner_repo="$1"
  local tag

  # Return cached value if available
  if [ -n "${TAG_CACHE[$owner_repo]:-}" ]; then
    echo "${TAG_CACHE[$owner_repo]}"
    return
  fi

  # Query GitHub API
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    tag=$(curl -sL --connect-timeout 5 -H "Authorization: Bearer $GITHUB_TOKEN" \
      "https://api.github.com/repos/$owner_repo/releases/latest" 2>/dev/null | \
      python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null || echo "")
  else
    tag=$(curl -sL --connect-timeout 5 \
      "https://api.github.com/repos/$owner_repo/releases/latest" 2>/dev/null | \
      python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null || echo "")
  fi

  # Fallback to releases list
  if [ -z "$tag" ]; then
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      tag=$(curl -sL --connect-timeout 5 -H "Authorization: Bearer $GITHUB_TOKEN" \
        "https://api.github.com/repos/$owner_repo/releases?per_page=1" 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin)[0]['tag_name'])" 2>/dev/null || echo "")
    else
      tag=$(curl -sL --connect-timeout 5 \
        "https://api.github.com/repos/$owner_repo/releases?per_page=1" 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin)[0]['tag_name'])" 2>/dev/null || echo "")
    fi
  fi

  if [ -n "$tag" ]; then
    TAG_CACHE[$owner_repo]="$tag"
  fi
  echo "$tag"
}

HAD_STALE=false

for workflow in "$WORKFLOW_DIR"/*.yml; do
  name=$(basename "$workflow")
  echo "=== $name ==="

  # Collect unique owner/repo from this file
  declare -A FILE_ACTIONS
  while IFS= read -r line; do
    uses=$(echo "$line" | sed -n 's/.*uses: *//p' | xargs)
    [ -z "$uses" ] && continue
    case "$uses" in *@*) ;; *) continue ;; esac

    owner_repo="${uses%@*}"
    current_ver="${uses#*@}"

    case "$owner_repo" in */*) ;; *) continue ;; esac
    case "$owner_repo" in ./*|docker://*) continue ;; esac

    # Track current version in this file
    FILE_ACTIONS["$owner_repo"]="${FILE_ACTIONS[$owner_repo]:-$current_ver}"
  done < <(grep -rn "uses:" "$workflow" || true)

  for owner_repo in "${!FILE_ACTIONS[@]}"; do
    current_ver="${FILE_ACTIONS[$owner_repo]}"
    latest_tag=$(get_latest_tag "$owner_repo")

    if [ -z "$latest_tag" ]; then
      echo "  ? $owner_repo (could not fetch latest)"
      continue
    fi

    if [ "$latest_tag" != "$current_ver" ]; then
      echo "  $owner_repo: $current_ver → $latest_tag"
      HAD_STALE=true

      if $UPDATE; then
        if [[ "$(uname)" == "darwin" ]]; then
          sed -i "" "s|uses: $owner_repo@$current_ver|uses: $owner_repo@$latest_tag|g" "$workflow"
        else
          sed -i "s|uses: $owner_repo@$current_ver|uses: $owner_repo@$latest_tag|g" "$workflow"
        fi
        echo "    ✓ updated"
      fi
    else
      echo "  $owner_repo: $current_ver (up to date)"
    fi
  done

  unset FILE_ACTIONS
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
