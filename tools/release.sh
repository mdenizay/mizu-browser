#!/bin/bash
# Builds the app, notarizes it, publishes it as a GitHub release and updates
# the Homebrew cask in the tap repository. Needs `gh auth login`, an existing
# mdenizay/homebrew-tap repository, and notarization credentials stored in the
# keychain (xcrun notarytool store-credentials <profile> ...); the profile is
# named by NOTARY_PROFILE.
# Usage: tools/release.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="mdenizay/mizu-browser"
TAP="mdenizay/homebrew-tap"
PROFILE="${NOTARY_PROFILE:-whatsapp-zen}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/app/Info.plist")"
ZIP="$ROOT/dist/Mizu-$VERSION.zip"

"$ROOT/build.sh"
rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$ROOT/dist/Mizu.app" "$ZIP"

# Notarize when the app is Developer ID signed and credentials are stored.
# The ticket is stapled to the app, so the zip is made again afterwards.
NOTARIZED=no
# (Read into a variable first: with pipefail, `codesign | grep -q` fails when
# grep exits early.)
SIGNATURE="$(codesign -dvv "$ROOT/dist/Mizu.app" 2>&1 || true)"
if [[ "$SIGNATURE" == *"Authority=Developer ID Application"* ]]; then
    if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
        xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
        xcrun stapler staple "$ROOT/dist/Mizu.app"
        rm -f "$ZIP"
        ditto -c -k --norsrc --noextattr --noqtn --keepParent "$ROOT/dist/Mizu.app" "$ZIP"
        NOTARIZED=yes
    fi
fi
echo "Notarized: $NOTARIZED"
if [ "$NOTARIZED" != yes ]; then
    echo "Refusing to publish a build Gatekeeper would block." >&2
    exit 1
fi
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

# Release notes: this version's section of the change log.
NOTES="$(mktemp)"
awk -v v="## $VERSION" '$0 == v {on = 1; next} /^## / {on = 0} on' "$ROOT/CHANGELOG.md" > "$NOTES"
if [ -s "$NOTES" ]; then
    gh release create "v$VERSION" "$ZIP" --repo "$REPO" --title "v$VERSION" --notes-file "$NOTES"
else
    gh release create "v$VERSION" "$ZIP" --repo "$REPO" --title "v$VERSION" --generate-notes
fi
rm -f "$NOTES"

WORK="$(mktemp -d)"
gh repo clone "$TAP" "$WORK/tap"
mkdir -p "$WORK/tap/Casks"
sed -e "s/VERSION/$VERSION/" -e "s/SHA256/$SHA/" "$ROOT/packaging/mizu.rb" \
    | grep -v '^# ' > "$WORK/tap/Casks/mizu.rb"
git -C "$WORK/tap" add Casks/mizu.rb
git -C "$WORK/tap" commit -m "mizu $VERSION"
git -C "$WORK/tap" push
rm -rf "$WORK"
echo "Released v$VERSION"
