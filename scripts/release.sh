#!/bin/bash
# Cut a release: build, package, publish the asset, refresh the cask.
#
# Everything a user needs to run `brew install --cask <tap>/<name>` comes from
# here, so the checksum in the cask and the file on the release can never drift
# apart: both are produced in one pass.
set -euo pipefail

REPO="${REPO:-alialhawas/Language-changer}"
TAP_REPO="${TAP_REPO:-}"          # e.g. alialhawas/homebrew-harf
APP_NAME="${APP_NAME:-Dodoma}"
CASK_TOKEN="${CASK_TOKEN:-dodoma}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
TAG="v${VERSION}"
DMG="build/${APP_NAME}-${VERSION}.dmg"

echo "==> Building ${APP_NAME} ${VERSION}"
make build bundle sign >/dev/null
./scripts/make-dmg.sh >/dev/null
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "    $DMG"
echo "    sha256 $SHA"

echo "==> Publishing $TAG to $REPO"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG" --repo "$REPO" --clobber
else
  gh release create "$TAG" "$DMG" --repo "$REPO" \
    --title "${APP_NAME} ${VERSION}" \
    --notes "Not notarised. macOS refuses unsigned downloads, so open it once from
System Settings > Privacy & Security, or install with
\`brew install --cask --no-quarantine ${CASK_TOKEN}\`."
fi

echo "==> Refreshing the cask"
python3 - "$SHA" "$VERSION" <<'PY'
import re, sys
sha, version = sys.argv[1], sys.argv[2]
path = "Casks/%s.rb" % __import__("os").environ.get("CASK_TOKEN", "dodoma")
body = open(path).read()
body = re.sub(r'version "[^"]+"', 'version "%s"' % version, body)
body = re.sub(r'sha256 "[a-f0-9]+"', 'sha256 "%s"' % sha, body)
open(path, "w").write(body)
print("    Casks updated to %s" % version)
PY

if [ -n "$TAP_REPO" ]; then
  echo "==> Pushing the cask to $TAP_REPO"
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  gh repo clone "$TAP_REPO" "$TMP/tap" -- --depth 1 >/dev/null 2>&1
  mkdir -p "$TMP/tap/Casks"
  cp "Casks/${CASK_TOKEN}.rb" "$TMP/tap/Casks/"
  git -C "$TMP/tap" add -A
  git -C "$TMP/tap" commit -q -m "${CASK_TOKEN} ${VERSION}" || echo "    (nothing to commit)"
  git -C "$TMP/tap" push -q
  echo "    users can now run: brew install --cask ${TAP_REPO%%/*}/${TAP_REPO##*homebrew-}/${CASK_TOKEN}"
else
  echo "==> TAP_REPO not set; the cask was refreshed locally but not published"
fi
