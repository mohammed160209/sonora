# Sonora for iPhone — development beta

Native SwiftUI iPhone port using the desktop-pinned Rust YouTube client. Requires iOS 26+.
The compatibility review runs on an iPhone 13 simulator with iOS 27.2.

## Implemented

- System Liquid Glass floating tabs, mini-player, glass actions and native player sheet.
- Files audio import, persistent local library, search and deletion.
- Guest YouTube Music search, artwork and native AAC stream resolution.
- AVPlayer queue, seeking, shuffle/repeat, lock-screen commands and background audio configuration.
- Persistent background download queue with progress, cancellation/retry, fresh stream URLs,
  byte-count/playability validation and downloaded-file preference during playback.
- Plain YouTube lyrics where the provider supplies them.
- Initial account verification, isolated sign-in window, existing-session import and device Keychain storage.

These are implemented capabilities, not a claim that every path has passed device testing.
See STATUS.md for evidence and outstanding checks. Account sign-in validation/renewal, account library, playlist mutations,
other providers, scrobbling and equalizer remain unfinished.

## Build from Linux using GitHub's Mac runner

The fork is https://github.com/mohammed160209/sonora. The **iPhone IPA** workflow builds the
native libraries, device app and simulator app. Download **Sonora-iPhone-unsigned**, extract the
IPA, then sign/install it with iLoader. No Apple certificate or account credential is stored here.
The separate simulator-review artifact contains screenshots and optional live-download evidence,
never the downloaded audio. A passing build cannot prove physical-device playback correctness.

Artifacts expire after seven days. Public repository macOS runner usage follows GitHub's plan
terms; artifact storage has quotas. Sideload signing is handled by the installation tool.

## Local preparation

Run `python3 ios/scripts/prepare.py` to regenerate the project, icon and English iOS resources.
Strings originate in `assets/i18n/en-US/main.ftl`; generated files must not be edited directly.
`Core/` is isolated from GPUI. On a Mac, install the two arm64 iOS Rust targets and run
`python3 ios/scripts/build_native.py` before Xcode. The workflow performs these steps automatically.

Downloads remain inside the app sandbox with iOS data protection. Cellular downloads default to
off. iOS owns suspended transfers; unresolved requests resume when the app returns to foreground.
Force-quitting and expiring provider URLs can interrupt transfers; failed entries support retry.
