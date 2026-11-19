# Sourced by the local and release builds. An updater-enabled bundle needs a
# feed URL and its public key. The private key stays in the release Keychain.
sparkle_distribution=""
sparkle_swift_flags=()

lanes_prepare_sparkle() {
  if [[ -z ${LANES_UPDATE_FEED_URL:-} && -z ${LANES_UPDATE_PUBLIC_KEY:-} ]]; then
    return
  fi

  python3 - <<'PY'
import base64
import binascii
import os
from urllib.parse import urlsplit

def https_url(value):
    url = urlsplit(value)
    return url.scheme == "https" and url.hostname and url.username is None and not url.query and not url.fragment

feed = os.environ.get("LANES_UPDATE_FEED_URL", "")
if not https_url(feed) or not urlsplit(feed).path.endswith("/appcast.xml"):
    raise SystemExit("LANES_UPDATE_FEED_URL must be an HTTPS URL ending in /appcast.xml.")
assets = os.environ.get("LANES_UPDATE_DOWNLOAD_BASE_URL")
if assets and not https_url(assets):
    raise SystemExit("LANES_UPDATE_DOWNLOAD_BASE_URL must be an HTTPS URL.")
try:
    public_key = base64.b64decode(os.environ.get("LANES_UPDATE_PUBLIC_KEY", ""), validate=True)
except binascii.Error:
    raise SystemExit("LANES_UPDATE_PUBLIC_KEY must be a base64 Sparkle public key.")
if len(public_key) != 32:
    raise SystemExit("LANES_UPDATE_PUBLIC_KEY must be a 32-byte Sparkle public key encoded in base64.")
PY

  local version=2.10.0
  local digest=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
  local vendor="$PWD/build/vendor"
  local archive="$vendor/Sparkle-$version.tar.xz"
  sparkle_distribution="$vendor/Sparkle-$version"
  mkdir -p "$vendor"
  if [[ ! -f "$archive" ]] || ! printf '%s  %s\n' "$digest" "$archive" | shasum -a 256 -c --status; then
    local download
    download=$(mktemp "$vendor/.Sparkle-$version.XXXXXXXX")
    curl --fail --show-error --silent --location --retry 2 --proto '=https' --proto-redir '=https' \
      "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" -o "$download"
    if ! printf '%s  %s\n' "$digest" "$download" | shasum -a 256 -c --status; then
      rm -f "$download"
      print -u2 "Sparkle archive does not match the pinned release checksum."
      return 1
    fi
    mv -f "$download" "$archive"
  fi
  if [[ ! -f "$sparkle_distribution/Sparkle.framework/Sparkle" || ! -x "$sparkle_distribution/bin/generate_appcast" ]]; then
    local extracted
    extracted=$(mktemp -d "$vendor/.Sparkle-$version.XXXXXXXX")
    tar -xJf "$archive" -C "$extracted"
    rm -rf "$sparkle_distribution"
    mv "$extracted" "$sparkle_distribution"
  fi
  sparkle_swift_flags=(-F "$sparkle_distribution" -framework Sparkle -Xlinker -rpath -Xlinker '@loader_path/../Frameworks')
}

lanes_embed_sparkle() {
  local app=$1
  local framework="$app/Contents/Frameworks/Sparkle.framework"
  # A previous configured local build may have left a framework in this bundle.
  rm -rf "$framework"
  if [[ -z "$sparkle_distribution" ]]; then return; fi
  mkdir -p "$app/Contents/Frameworks"
  ditto "$sparkle_distribution/Sparkle.framework" "$framework"
  local plist="$app/Contents/Info.plist"
  plutil -insert SUFeedURL -string "$LANES_UPDATE_FEED_URL" "$plist"
  plutil -insert SUPublicEDKey -string "$LANES_UPDATE_PUBLIC_KEY" "$plist"
  plutil -insert SUEnableAutomaticChecks -bool NO "$plist"
  plutil -insert SUAllowsAutomaticUpdates -bool NO "$plist"
  plutil -insert SUEnableSystemProfiling -bool NO "$plist"
  plutil -insert SUVerifyUpdateBeforeExtraction -bool YES "$plist"
  plutil -insert SURequireSignedFeed -bool YES "$plist"
}

lanes_sign_sparkle() {
  local app=$1
  shift
  if [[ -z "$sparkle_distribution" ]]; then return; fi
  local framework="$app/Contents/Frameworks/Sparkle.framework"
  local version="$framework/Versions/Current"
  local item
  for item in "$version/Autoupdate" "$version/Updater.app" "$version"/XPCServices/*.xpc; do
    codesign --force "$@" --preserve-metadata=entitlements "$item"
  done
  codesign --force "$@" "$framework"
}

lanes_verify_sparkle_key() {
  if [[ -z "$sparkle_distribution" ]]; then return; fi
  local account=${LANES_UPDATE_KEY_ACCOUNT:-lanes-updates}
  local found
  found=$("$sparkle_distribution/bin/generate_keys" --account "$account" -p)
  if [[ "$found" != "$LANES_UPDATE_PUBLIC_KEY" ]]; then
    print -u2 "The Sparkle public key does not match the release Keychain account ($account)."
    return 1
  fi
}

lanes_make_appcast() {
  local version=$1
  if [[ -z "$sparkle_distribution" ]]; then return; fi
  local prefix=${LANES_UPDATE_DOWNLOAD_BASE_URL:-https://github.com/lanesmacapp/Lanes/releases/download/v$version/}
  "$sparkle_distribution/bin/generate_appcast" \
    --account "${LANES_UPDATE_KEY_ACCOUNT:-lanes-updates}" \
    --download-url-prefix "${prefix%/}/" --maximum-deltas 0 -o dist/appcast.xml dist
  [[ -s dist/appcast.xml ]]
  print "Ready to publish after uploading the DMG: dist/appcast.xml"
}
