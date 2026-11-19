# Releasing Lanes

Lanes is free and distributed as a notarized disk image on GitHub Releases. It is not on the Mac App Store (see "Why not the App Store" below).

## One-time setup (about an hour, plus Apple's approval)

1. **Join the Apple Developer Program** at https://developer.apple.com/programs ($99 a year). Approval usually takes 1–2 days.
2. **Create a Developer ID certificate.** In Xcode: Settings › Accounts › your team › Manage Certificates › **+** › **Developer ID Application**. It lands in your login keychain.
3. **Create an App Store Connect API key** at https://appstoreconnect.apple.com › Users and Access › Integrations › **Individual Keys**. Download the `.p8` file (Apple lets you download it once) and note its Key ID.
4. **Save the notarization login** in your keychain:

   ```sh
   xcrun notarytool store-credentials lanes-notary --key ~/Downloads/ApiKey_KEYID.p8 --key-id KEYID
   ```

   An individual key has no Issuer ID: press Return when asked. If Apple answers "A required agreement is missing or has expired" (403), accept the pending agreement under App Store Connect › Business, wait a few minutes and try again.

Keychain items are unreadable while the screen is locked, and the first `codesign` asks for your Mac password: choose **Always Allow** so later releases run unattended.

## Every release (about 15 minutes)

1. Bump `CFBundleShortVersionString` (for example 1.0.1) and `CFBundleVersion` (one higher) in `Info.plist`.
2. Run the checks: `./test.sh`
3. Build, sign, notarize and staple: `./release.sh`

   The disk image opens to Lanes, an arrow, and Applications. The script uses your Developer ID certificate and prepares the signed update feed. For a manual-download build without Sparkle, set `LANES_UPDATE_FEED_URL=` and `LANES_UPDATE_PUBLIC_KEY=` on the command line.
4. Check it the way a stranger would: copy the disk image to another Mac (or another user account), open it, drag Lanes to Applications and open it. macOS should show only the normal "downloaded from the internet" question.
5. Push the exact source commit that built the disk image and tag that commit. Publish with `gh release create --verify-tag --repo lanesmacapp/Lanes v<version> dist/Lanes-<version>.dmg --title "Lanes <version>" --notes "…"`, then update README.md.

## Before the first public release

Lanes has only run on one Mac with a 5120 × 1440 display. Try these on a second Mac or with a friend before announcing:

- A 14" or 16" MacBook screen on its own, and a MacBook plus an external display.
- A fresh user account: first launch, the permission step, Organize, Restore, Quit.
- Full-screen apps, several Spaces, and Stage Manager on.
- Open at login on and off.
- Uninstall steps in README.md.

## In-app updates

Builds get **Check for Updates…** and optional automatic checks when configured with a Sparkle feed and public key. People using an older build need to install the first updater-enabled DMG manually.

1. The public feed URL and key are in `Tools/sparkle-release.conf`. The matching private key is stored in the release Mac’s login Keychain under Sparkle account `lanes-updates`.
2. Bump the version and build number, then run `./release.sh`. The script prepares a notarized DMG and signed `dist/appcast.xml`, with the download URL pointing to the versioned GitHub Release asset.
3. Publish the versioned DMG to GitHub Releases first. Then place the signed `appcast.xml` at the root of the public repository’s `updates` branch. Publish the generated XML byte for byte, since editing it breaks the signature.
4. On a separate Mac or test account, install one updater-enabled build and then check for a newer signed release. Verify the new build launches, Accessibility still works, and existing layouts and preferences survive.

The first Sparkle release is Lanes 1.0.1 (build 102) under the GitHub tag `v1`. Use `LANES_UPDATE_DOWNLOAD_BASE_URL=https://github.com/lanesmacapp/Lanes/releases/download/v1/` if regenerating its appcast.

Automatic checking is off until the user enables it, and installing an update requires their action. Lanes has no analytics or crash reporting.

## Why not the App Store

App Store apps must run in Apple's sandbox. Lanes watches windows of every app, reacts when they open, and listens for a double tap of Right Command, so it would need rework and might not pass review. Every update would also wait for review. A notarized download avoids both. You can revisit this once Lanes is stable.
