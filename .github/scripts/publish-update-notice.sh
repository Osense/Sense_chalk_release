#!/usr/bin/env bash
# Called by .github/workflows/publish-update-notice.yml. Needs gh, curl, jq, sha256sum (all on ubuntu-latest).
set -euo pipefail

REPO="${GITHUB_REPOSITORY:-Osense/Sense_chalk_release}"
SITE_URL="https://wsns.studio/products/sense-chalk"

if [ -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]; then
  echo "::error::SUPABASE_SERVICE_ROLE_KEY secret is not set; the update notice was not recorded."
  exit 1
fi

# Highest version of each kind of file currently in the repository root.
latest() { { ls -1 $1 2>/dev/null || true; } | sed -E "s/$2/\1/" | sort -V | tail -n1; }
WIN_VER=$(latest 'SenseChalk-*-win-x64.zip' '^SenseChalk-(.*)-win-x64\.zip$')
AND_VER=$(latest 'SenseChalk-Android-*.apk' '^SenseChalk-Android-(.*)\.apk$')

publish() { # platform version file tag
  local platform=$1 version=$2 file=$3 tag=$4 name
  if ! [[ "$version" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]; then
    echo "::warning::$file: '$version' is not a version number, skipped"; return 0
  fi
  name=$(basename "$file")
  local sha size
  sha=$(sha256sum "$file" | cut -d' ' -f1)
  size=$(stat -c %s "$file")

  # 1) GitHub release with the file attached (the PC app only installs from .../releases/download/...).
  if gh release view "$tag" -R "$REPO" >/dev/null 2>&1; then
    gh release upload "$tag" "$file" -R "$REPO" --clobber
  else
    gh release create "$tag" "$file" -R "$REPO" --title "SenseChalk $([ "$platform" = android ] && echo 'Android ')$version" \
      --notes "$( [ -f "notes/${name%.*}.md" ] && cat "notes/${name%.*}.md"; printf '\n\n파일: %s\nsha256: %s\n' "$name" "$sha")"
  fi
  local download="https://github.com/$REPO/releases/download/$tag/$name"
  local link="https://github.com/$REPO/releases/tag/$tag"
  [ "$platform" = android ] && link="$SITE_URL"

  # 2) Record the notice. The RPC deactivates older notices of the same platform.
  # Release notes: notes/<file name without extension>.md, e.g. notes/SenseChalk-5.4.0-win-x64.md.
  # The first line "# ..." (optional) becomes the popup title, the rest the popup text.
  local notes_file="notes/${name%.*}.md" title="새로운 버전이 출시되었어요." message="${NOTICE_MESSAGE:-}"
  if [ -z "$message" ] && [ -f "$notes_file" ]; then
    if head -n1 "$notes_file" | grep -q '^# '; then
      title=$(head -n1 "$notes_file" | sed 's/^# *//')
      message=$(tail -n +2 "$notes_file" | sed '/./,$!d')
    else
      message=$(cat "$notes_file")
    fi
  fi
  if [ -z "$message" ]; then
    if [ "$platform" = android ]; then message="쎈스 초크 안드로이드 최신 버전(v$version)에서 향상된 기능과 안정성을 만나보세요."
    else message="쎈스 초크 최신 버전(v$version)에서 향상된 기능과 안정성을 만나보세요."; fi
  fi
  local body
  body=$(jq -n --arg p "$platform" --arg v "$version" --arg t "$title" --arg m "$message" --arg l "$link" \
    --arg d "$download" --arg s "$sha" --argjson z "$size" --arg by "${GITHUB_SHA:-manual}" \
    '{p_platform:$p, p_version:$v, p_title:$t, p_message:$m, p_link_url:$l, p_download_url:$d, p_sha256:$s, p_file_size:$z, p_published_by:$by}')

  # Skip if this exact file is already the active notice (re-runs, README-only commits).
  local current
  current=$(curl -fsS "$SUPABASE_URL/rest/v1/rpc/latest_app_release" \
    -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
    -H "Content-Type: application/json" -d "{\"p_platform\":\"$platform\"}" | jq -r '(.[0].sha256 // "") + "|" + (.[0].title // "") + "|" + (.[0].message // "")')
  if [ "$current" = "$sha|$title|$message" ]; then
    echo "$platform $version is already the active notice"; return 0
  fi

  curl -fsS "$SUPABASE_URL/rest/v1/rpc/publish_app_release" \
    -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
    -H "Content-Type: application/json" -d "$body" | jq '{platform, latest_version, download_url, sha256}'
  echo "::notice::$platform $version recorded ($download)"
}

[ -n "$WIN_VER" ] && publish windows "$WIN_VER" "SenseChalk-$WIN_VER-win-x64.zip" "v$WIN_VER"
[ -n "$AND_VER" ] && publish android "$AND_VER" "SenseChalk-Android-$AND_VER.apk" "android-v$AND_VER"
exit 0
