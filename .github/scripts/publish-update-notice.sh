#!/usr/bin/env bash
# Called by .github/workflows/publish-update-notice.yml. Needs gh, curl, jq, sha256sum (all on ubuntu-latest).
set -euo pipefail

REPO="${GITHUB_REPOSITORY:-Osense/Sense_chalk_release}"
SITE_URL="https://wsns.studio/products/sense-chalk"

if [ -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]; then
  echo "::error::SUPABASE_SERVICE_ROLE_KEY secret is not set; the update notice was not recorded."
  exit 1
fi

# 2026-11-24: PC 0.5.3.7+ installs only releases signed with the update signing key (ECDSA P-256, PEM), kept as the
# repository secret UPDATE_SIGNING_KEY. The app checks the signature with its built-in public key.
sign_release() { # platform version sha256 -> base64 DER signature
  local keyfile
  keyfile=$(mktemp)
  chmod 600 "$keyfile"
  printf '%s\n' "$UPDATE_SIGNING_KEY" > "$keyfile"
  printf 'SENSECHALK-UPDATE-1\n%s\n%s\n%s\n' "$1" "$2" "$3" | openssl dgst -sha256 -sign "$keyfile" | base64 -w0
  rm -f "$keyfile"
}

# New secret keys (sb_secret_...) go only in the apikey header; a legacy service_role JWT also as Bearer.
AUTH=(-H "apikey: $SUPABASE_SERVICE_ROLE_KEY")
case "$SUPABASE_SERVICE_ROLE_KEY" in eyJ*) AUTH+=(-H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY");; esac

# Highest version of each kind of file currently in the repository root.
latest() { { ls -1 $1 2>/dev/null || true; } | sed -E "s/$2/\1/" | sort -V | tail -n1; }
# Fixed-name release (SenseChalk.zip + version.txt) wins; the old versioned file name is the fallback.
WIN_FILE=""
if [ -f SenseChalk.zip ] && [ -f version.txt ]; then
  WIN_VER=$(head -n1 version.txt | tr -d '[:space:]')
  WIN_FILE=SenseChalk.zip
else
  WIN_VER=$(latest 'SenseChalk-*-win-x64.zip' '^SenseChalk-(.*)-win-x64\.zip$')
  [ -n "$WIN_VER" ] && WIN_FILE="SenseChalk-$WIN_VER-win-x64.zip"
fi
if [ -n "$WIN_FILE" ] && [ -z "${UPDATE_SIGNING_KEY:-}" ]; then
  echo "::error::UPDATE_SIGNING_KEY secret is not set; Windows releases cannot be signed."
  exit 1
fi

publish() { # platform version file tag
  local platform=$1 version=$2 file=$3 tag=$4 name
  if ! [[ "$version" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]; then
    echo "::warning::$file: '$version' is not a version number, skipped"; return 0
  fi
  name=$(basename "$file")
  local sha size
  sha=$(sha256sum "$file" | cut -d' ' -f1)
  size=$(stat -c %s "$file")

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
  # PC rows record the version with 9 added to the first number (0.5.3.1 -> 9.5.3.1): PCs still on 5.x (before
  # the 0.x renumbering of 2026-11-22) compare only this field and must see it as newer. 0.5.3.1 and later read
  # the real number from the tag in download_url (.../releases/download/v<version>/...).
  local recorded="$version"
  if [ "$platform" = windows ]; then recorded="$(( ${version%%.*} + 9 )).${version#*.}"; fi
  local signature=""
  if [ "$platform" = windows ]; then
    signature=$(sign_release "$platform" "$version" "$sha")
    [ -n "$signature" ] || { echo "::error::signing failed"; exit 1; }
  fi
  local body
  body=$(jq -n --arg sig "$signature" --arg p "$platform" --arg v "$recorded" --arg t "$title" --arg m "$message" --arg l "$link" \
    --arg d "$download" --arg s "$sha" --argjson z "$size" --arg by "${GITHUB_SHA:-manual}" \
    '{p_platform:$p, p_version:$v, p_title:$t, p_message:$m, p_link_url:$l, p_download_url:$d, p_sha256:$s, p_file_size:$z, p_published_by:$by} + (if $sig == "" then {} else {p_signature:$sig} end)')

  # The release must carry this file under its own name even when the notice itself is unchanged:
  # releases/latest/download/SenseChalk.zip (the site's download link) depends on it.
  if gh release view "$tag" -R "$REPO" >/dev/null 2>&1 && \
     ! gh release view "$tag" -R "$REPO" --json assets -q '.assets[].name' | grep -qx "$name"; then
    gh release upload "$tag" "$file" -R "$REPO" --clobber
  fi
  if [ "$platform" = windows ] && gh release view "$tag" -R "$REPO" >/dev/null 2>&1; then
    gh release edit "$tag" -R "$REPO" --latest >/dev/null
  fi

  # Skip if this exact file is already the active notice (re-runs, README-only commits).
  local current
  current=$(curl -fsS "$SUPABASE_URL/rest/v1/rpc/latest_app_release" \
    "${AUTH[@]}" \
    -H "Content-Type: application/json" -d "{\"p_platform\":\"$platform\"}" | jq -r '(.[0].sha256 // "") + "|" + (.[0].title // "") + "|" + (.[0].message // "") + "|" + (if .[0].signature then "signed" else "" end)')
  local expected_signed=""
  [ "$platform" = windows ] && expected_signed="signed"
  if [ "$current" = "$sha|$title|$message|$expected_signed" ]; then
    echo "$platform $version is already the active notice"; return 0
  fi

  # GitHub release with the file attached (the PC app only installs from .../releases/download/...).
  if gh release view "$tag" -R "$REPO" >/dev/null 2>&1; then
    gh release upload "$tag" "$file" -R "$REPO" --clobber
  else
    gh release create "$tag" "$file" -R "$REPO" --title "SenseChalk $([ "$platform" = android ] && echo 'Android ')$version" \
      --notes "$( [ -f "notes/${name%.*}.md" ] && cat "notes/${name%.*}.md"; printf '\n\n파일: %s\nsha256: %s\n' "$name" "$sha")"
  fi
  # Versions restarted at 0.x after 5.5.2, so "Latest" must follow the newest release, not the highest number:
  # the site links to releases/latest/download/... .
  [ "$platform" = windows ] && gh release edit "$tag" -R "$REPO" --latest >/dev/null
  curl -fsS "$SUPABASE_URL/rest/v1/rpc/publish_app_release" \
    "${AUTH[@]}" \
    -H "Content-Type: application/json" -d "$body" | jq '{platform, latest_version, download_url, sha256}'
  echo "::notice::$platform $version recorded ($download)"
}

[ -n "$WIN_FILE" ] && publish windows "$WIN_VER" "$WIN_FILE" "v$WIN_VER"
# The installer rides along in the same release; the app itself always updates from SenseChalk.zip.
# Site link: https://github.com/$REPO/releases/latest/download/SenseChalkSetup.exe
if [ -n "$WIN_FILE" ] && [ -f SenseChalkSetup.exe ] && gh release view "v$WIN_VER" -R "$REPO" >/dev/null 2>&1; then
  gh release upload "v$WIN_VER" SenseChalkSetup.exe -R "$REPO" --clobber
  echo "::notice::SenseChalkSetup.exe attached to v$WIN_VER"
fi
exit 0
