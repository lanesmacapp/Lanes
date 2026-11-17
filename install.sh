#!/bin/zsh
# Installs the newest Lanes on this Mac and leaves exactly one copy:
#   1. test and build the current source
#   2. sign it with the same Developer ID as the installed app (Accessibility access carries over)
#   3. quit every running Lanes, replace /Applications/Lanes.app in place
#   4. delete every other Lanes.app on this Mac
#   5. open the new one (it re-points "Open at login" at /Applications on first launch)
# The previous install is kept as Backups/previous-Lanes.zip. A zip is not an app,
# so Spotlight, Launch Services and the login item can never open it by mistake.
#
#   ./install.sh               test, build, install
#   ./install.sh --skip-tests  build and install only
set -euo pipefail
cd "${0:A:h}"

ID=com.lanes-mac.Lanes
DEST=/Applications/Lanes.app
STAGE=build/install-stage/Lanes.app
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

[[ ${1:-} == --skip-tests ]] || ./test.sh
./build.sh

rm -rf build/install-stage; mkdir -p build/install-stage
ditto build/Lanes.app $STAGE
IDENTITY=${LANES_DEVELOPER_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}
if [[ -n $IDENTITY ]]; then
  # Apple's timestamp server is not always reachable; a local install does not need one.
  codesign --force --options runtime --timestamp --sign "$IDENTITY" $STAGE 2>/dev/null \
    || codesign --force --options runtime --timestamp=none --sign "$IDENTITY" $STAGE
else
  print "No Developer ID certificate: installing the local build. macOS may ask for Accessibility again." >&2
fi
codesign --verify --deep --strict $STAGE

# Quit the normal way so each running Lanes restores the windows it moved.
osascript -l JavaScript -e "ObjC.import('AppKit'); const a = \$.NSRunningApplication.runningApplicationsWithBundleIdentifier('$ID'); for (let i = 0; i < a.count; i++) a.objectAtIndex(i).terminate" >/dev/null
for _ in {1..300}; do pgrep -xq Lanes || break; sleep 0.1; done
pkill -x Lanes 2>/dev/null || true

mkdir -p Backups
[[ -d $DEST ]] && { rm -f Backups/previous-Lanes.zip; ditto -c -k --keepParent $DEST Backups/previous-Lanes.zip; }
# macOS App Management blocks writing inside an installed bundle, so swap whole
# bundles: copy the new one next to it, move the old one out, move the new one in.
NEW=/Applications/.Lanes-installing.app OLD=build/replaced-Lanes.app
rm -rf $NEW $OLD
ditto $STAGE $NEW
[[ -d $DEST ]] && mv $DEST $OLD
mv $NEW $DEST
rm -rf $OLD build/install-stage build/Lanes.app

# Every other Lanes.app is deleted, so nothing can open an old build.
# (Deleted, not trashed: this shell may not have access to ~/.Trash.)
trash_copy() {
  $LSREGISTER -u "$1" 2>/dev/null || true
  rm -rf "$1" && print "Deleted $1"
}
typeset -U candidates
candidates=(
  ${(f)"$(mdfind "kMDItemCFBundleIdentifier == '$ID'" 2>/dev/null)"}
  ${(f)"$($LSREGISTER -dump 2>/dev/null | sed -n 's/^path: *\(.*\.app\)\( (0x[0-9a-f]*)\)\{0,1\}$/\1/p')"}
  ${(f)"$(find "$PWD" -name '*.app' -type d -prune 2>/dev/null)"}
)
for app in $candidates; do
  [[ -d $app && $app != $DEST && $app != $HOME/.Trash/* && $app != */Contents/* ]] || continue
  [[ $(defaults read "$app/Contents/Info" CFBundleIdentifier 2>/dev/null) == $ID ]] || continue
  trash_copy "$app"
done

$LSREGISTER -f $DEST
open $DEST
print "Installed Lanes $(defaults read $DEST/Contents/Info CFBundleShortVersionString) ($(defaults read $DEST/Contents/Info CFBundleVersion)) in $DEST"
