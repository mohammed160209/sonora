# iPhone port status

Development beta, updated 10 November 2026. Build 26 is the latest verified simulator build. It includes six-digit YouTube Music Listening Sessions, chronological history replay, solid Queue and History previews, more resilient downloads and upstream lyrics improvements.

Build 26 source `cfc4a7ab` passed all 12 interaction checks on the iPhone 13 simulator with iOS 27.2 (24B8117) in [run 42767363425](https://github.com/mohammed160209/sonora/actions/runs/42767363425). The checks verified history order, selected-row previews, audio validation, and offline artwork and timed lyrics after relaunch. Two protocol clients exercised the official Sessions relay. A live public YouTube Music download decoded completely on Linux. Live transfer and cross-device audio on a physical iPhone, including iOS 27.2.1, still need verification.

## Verified

- Device and simulator SwiftUI builds pass Xcode compilation, including the linked Rust YouTube core.
- The native core builds for arm64 iPhone and simulator; Linux Clippy passes with warnings denied.
- Manual native-boundary calls returned live YouTube search results, AAC stream URLs and lyrics.
- A full AAC range transfer on Linux returned the expected byte count.
- IPA packaging validates arm64 iPhoneOS, minimum OS and archive contents.
- Native navigation light/dark/large-text screenshots were inspected. Empty accessory and large-text overflow fixes were confirmed.

## Integrated runtime results

Run 40211864427 passed compilation, launched the iPhone 13/iOS 26.5 simulator and returned live
YouTube search/artwork. Streaming and download resolution failed with the provider's
sign-in-required response. This is an observed runtime failure, not a passing playback check.
The same video resolved and served AAC bytes from Linux. Network/account differences must be
resolved; no network-verification bypass or proxy has been added.

Account verification, ephemeral sign-in, desktop-compatible session import, Keychain persistence,
account/page selection, cookie renewal and proof-of-origin support are in source. They have not
been accepted with a real account; a cookie verification result alone cannot establish complete
authenticated playback. The requested system Safari sign-in is still unimplemented.

## Remaining release gates

- Live search, full download, downloaded playback and relaunch in the simulator.
- Physical iPhone import, streaming, background/lock-screen playback, airplane-mode cold launch,
  interrupted transfer recovery, network changes, accessibility and long listening sessions.
- Complete and validate account sign-in/library, playlist mutations, other providers, scrobbling and equalizer.
- Complete the desktop parity inventory in PARITY.md before a final IPA handoff.

The app is a development beta, not a feature-complete replacement for the desktop app.

## Repair batch 49c5a68b (26 October 2026)

Home shelf/genre, album/artist/playlist, account-library and lyrics response shapes now match the
Swift decoder requirements. Local live checks returned populated Home and detail payloads with
none of the previously missing required fields. Native Rust build/Clippy and Swift syntax checks pass.
The player has bounded background geometry, available-space artwork sizing, larger touch regions,
accessibility scrolling and reduced-motion/transparency handling. Metadata review uses a real public
YouTube search result, without fabricated playback or exported audio. Version is 0.3.0 (4).

Apple run 40231715841 compiled both targets and verified populated Home (8 sections, 90 items,
40 genres) and decoded synced lyrics (37 lines) on the iPhone 13/iOS 26.5 simulator. Artwork, lyrics,
queue and large-text captures were inspected. The fixed guest test video was refused with a
sign-in-required response, so streaming/download acceptance still failed. The confirmation batch
fixes the yt3 artwork-host case and accessibility control sizing, and probes several actual search
candidates to distinguish a gated track from general guest failure. Guest playback remains an
acceptance gate. Commercial Safari/OAuth sign-in is not implemented; see References/AppleMusic/AUTHENTICATION.md.
The user selected Emil Kowalski's apple-design skill instead of Impeccable.

## Desktop-path confirmation 7c3aa2f2 (26 October 2026)

Apple run 40234634963 compiled device and simulator targets. Actual simulator Home returned
8 sections, 79 items and 40 genres; synced lyrics returned 37 decoded lines. The 01f5a62b captures
confirm that the yt3 display-sized artwork is sharp and large-text player controls no longer overlap.
These captures review metadata/layout; they do not establish working audio.

All four live search candidates failed Guest resolution with `network_verification_required`.
Sanitized provider diagnostics confirm Google's bot-verification response and LOGIN_REQUIRED,
without a decipher or audio-host refusal. No PO token stage was reached. This happens with
the same `open_audio_within` method used by desktop; changing the one-byte check was insufficient.
Linux resolved a public test track through that method, but this is not an iPhone playback pass.
The user also confirms that the older installed IPA requires sign-in when playing Search results;
the precise server response on their phone has not been captured.

The subsequent Search repair restores the catalog's `songs` field (Library continues to use
`liked_songs`). A live Linux boundary check returned 20 songs, albums, playlists and artists each.
Simulator acceptance now requires decoded Search results as well as Home/lyrics, real advancing
stream playback, complete download and advancing downloaded playback. IPA upload is after these
checks; a missing repository variable cannot silently skip the audio check. A failing build must
not be handed off as a working IPA. Authenticated playback, physical-device behavior and the
remaining feature inventory are still release gates.

## Font and appearance work (26 October 2026)

The full desktop feature goal remains active. The previous goal work made progress: it changed
source and produced simulator evidence, rather than only waiting. A two-hour heartbeat was previously active and has since been deleted at the user’s request.
Work continues in the active conversation; no account limit reset time is guaranteed.

The font system now supports native SF Pro Rounded, bundled Inter faces and user-imported
TTF/OTF/TTC files, with persistence, Dynamic Type text styles and removal of imported collections.
No separately supplied SF Pro Rounded file is currently in the project root. iOS supplies its
rounded system design without redistributing Apple's desktop font files. Shared text styles
across screens now resolve the user's font choice. Native system navigation keeps system styling.
Appearance also supports artwork-derived contrast-adjusted accent colors and named system accents.
Simulator checks for font registration, selection persistence and screenshots are added; their
Apple results are recorded below. This does not resolve Guest audio verification.

Apple run 40255941831 compiled device and simulator targets and passed font availability,
selection and relaunch checks for SF Pro Rounded and Inter (5 registered faces). The two captured
font settings screens were visually inspected: the selected font changes the preview and body
text, with no clipping. The run subsequently failed at the already-known Guest verification gate.

## Queue and local-file repair batch (26 October 2026)

Queue occurrences now carry distinct UUIDs, so repeated songs can be selected/removed/reordered
individually. Playing Next uses a native List with reorder handles and removal, and only shows
upcoming entries. Queue snapshots retain entry identity, the selected occurrence, original order,
shuffle and repeat, with migration from old track-only snapshots. Clear Upcoming retains the past.
Debug simulator checks exercise repeated entries, moves, removal, shuffle, restore without autoplay
and repeat persistence. These checks still need Apple runtime acceptance.

Local-file lyrics no longer validate an app UUID as a YouTube ID. A live Linux boundary request
without any video ID returned 37 synced LRCLIB lines. Disabled local lookup now clears stale lyrics.
Imported local files retain album and duration metadata. A generated WAV simulator check now
exercises actual import, advancing playback, pause, seek/resume and deletion before attempting
network-dependent Guest audio. Source syntax and Rust Clippy/build checks pass; Apple results pending.
Apple run 40256955207 is the exact queue/local repair snapshot at da48eede and must be checked
before making further acceptance claims. Inspect queue-review.json, local-playback-review.json
and local-lyrics-review.json, plus the actual duplicate-entry queue screenshot. The goal remains active.

Run 40256955207 passed all eight queue occurrence/order/restore checks. Its generated WAV test
passed actual import, duration metadata, playback clock advancement, pause, seek/resume and deletion.
Local metadata-only lyrics decoded 37 synced lines in the simulator. The duplicate-entry queue
screen was visually inspected: both rows, removal controls and native reorder handles render correctly.
The run then failed on the same Guest network-verification gate; no IPA was published.

## Shared desktop equalizer integration (26 October 2026)

The mobile core now compiles the existing `crates/music/src/equalizer/` source directly, without
GPUI, rodio output or copied filter implementations. A C boundary exposes one preallocated reader
per AVFoundation audio tap; render processing does not allocate, lock or use Tokio. Configuration
runs on Tokio and has revision ordering so an obsolete slider request cannot replace newer settings.
The native player installs a MediaToolbox audio tap before starting playback. Presets use the
desktop's actual ten-band curves and tone shelves, with automatic headroom/manual preamp, smooth
changes and normalization capable of positive gain. Unsupported processing is reported explicitly.

All six existing desktop DSP tests pass in the isolated core. The generated-PCM C-boundary check
passes exact finite-sample bypass, matching planar/interleaved stereo, frequency-selective bass
response, preset headroom, APO parsing, stale-request rejection and +6 dB normalization. These are
Linux DSP results. iPhone device/simulator compilation and actual AVFoundation tap processing
remain pending; the local playback check now requires a positive native processed-frame count.
Full parametric editing, named profiles/device rules and APO import/export UI are still missing.

Apple native-core run 40259560019 passed, including the six reused filter tests, generated-PCM
C-boundary checks on the Mac host, and both iPhone/simulator static-library builds. iPhone run
40259560062 has compiled the device app and is checking simulator/runtime behavior for snapshot
0c4607bd. Re-poll that same run rather than restarting it. Its positive tap-frame assertion is the
required evidence for actual AVFoundation integration; compilation and core tests alone are insufficient.

Run 40259560062 completed. Its local-playback-review.json confirms seven passed checks, including
positive native audio-tap processing, real clock advancement, pause and seek/resume. The iOS DSP
bridge is therefore exercised through AVFoundation, not only compiled. The run again failed later
at Guest verification, and did not publish an IPA.

## Named profiles and parametric filters (26 October 2026)

Native Sound settings now have profile creation from desktop presets, selection, renaming,
deletion, up to 20 editable/reorderable filters with all eight desktop types, Q/octave widths,
frequency/gain/enable controls and per-profile automatic/manual preamp. Files import/export uses
the actual desktop Equalizer APO parser/exporter; unsupported lines are reported rather than hidden.
Descriptions validate drafts without changing playback. Profile JSON writes are atomic, corrupt
saved files are preserved, and the selected profile survives relaunch. Sound-specific device rules
are still missing, and touch interaction/Files-picker acceptance remains separate from store checks.

The extended generated-PCM check passes valid profile edits/round-trip, rejected invalid shelves
and filter counts, import warnings, unchanged audio during preview, and a frequency-selective notch.
Swift syntax and canonical localization checks pass. Apple compilation and a new native profile-store
acceptance sequence (create, validate/edit/save, export, import/warnings, reload and delete) are pending.

The user explicitly cancelled two-hour scheduling. Automation `continue-sonora-iphone-feature-parity`
has been deleted; the full goal remains active for continuous work in this chat. Do not recreate it.

## Profile acceptance and shared lyrics (26 October 2026)

Apple run 40262750069 at 1c371e24 compiled device and simulator targets. All seven native profile
checks passed (create, validate/edit/save, export, import, unsupported-line reporting, restoration,
delete). Both settings screenshots were inspected. Guest verification still failed; no final IPA
was published.

Lyrics now reuse the desktop's models, six remote sources, matching/ranking, LRC/TTML readers and
romanization, with an optional Local sidecar source. All 53 shared Rust tests pass on Linux, as do
Clippy and native boundary checks for enhanced LRC words, repeated stamps and TTML backing vocals.
A live LRCLIB lookup returned 37 synced lines. The native screen adds source enable/reordering,
alternate sheets, word highlighting against AVPlayer's clock, backing lanes, lyric text sizing,
import/copy/refresh, manual-scroll interruption and a follow-current-line action. Saved sheets and
imported sidecars are serialized off the UI thread and remain readable without network lookups.

Swift syntax passes. Apple compilation and the new eight-check native import/cache/source sequence
are pending; word-highlight motion and touch-driven interactions still require runtime review.
Per-script romanization controls, exact Apple Music highlight effects and actual phone acceptance
are not complete. No two-hour automation remains; the user requested continuous active work.

## Listening and durable submissions (26 October 2026)

The fifteen-second playhead trigger has been replaced with listening-time accounting. Pauses,
buffering, restore positions and seeks do not earn listens. Tracks under thirty seconds do not
count; other tracks require half their duration or four minutes. Each repeat/queue occurrence has
its own listen ID and original start timestamp. History begins when native output starts.

ListenBrainz now-playing and completed-listen payloads and Maloja artists/length/time fields now
match the desktop protocol. A per-service durable outbox keeps unsuccessful submissions, applies
backoff, isolates changed accounts by credential digest, and retries on foreground/relaunch.
Credentials remain in Keychain; queue files contain no tokens. The settings screen shows pending
listens and offers retry. These changes and sixteen native acceptance checks are pending Apple
compilation/runtime evidence. Last.fm/Libre.fm linking and real-account acceptance remain missing.

## Local covers, embedded lyrics and albums (26 October 2026)

Local import now reads embedded covers, album artist, disc/track numbers and lyric tags.
Covers are stored with relative filenames, orientation corrected and bounded to 1600 pixels;
the shared artwork component supports local files in rows, player, background, lock-screen and
artwork accent calculation. Removing an import removes its cover and imported lyric sidecar.
Embedded lyrics use the existing parser and remain readable without a network request.

Library Albums now includes imported records. Album-artist grouping keeps compilations together,
and disc/track tags order local album playback. Existing native song rows, artwork cards and play/
shuffle controls are reused. A generated AAC fixture with actual AVFoundation tags, synthetic cover
and self-authored timed lyrics extends local acceptance with metadata, cover/sidecar restoration,
album grouping/order and cleanup checks. Swift syntax passes; Apple runtime results are pending.

Apple run 40267418409 at c058f44a compiled both targets and passed all eight initial native lyrics
store checks. The actual remote sheet had 38 lines, 203 timed words and three source choices.
The lyrics screen was inspected; the source-options button is being tightened to a native circle,
and inactive/active line typography now has a stable size. Actual generated-WAV playback including
the native DSP still passed all seven checks. Shared core run 40267418289 passed Apple host tests,
boundary checks and both release libraries. Guest resolution alone still failed with verification
required. This is not final IPA acceptance.

## Native listening acceptance and response preview (26 October 2026)

Run 40268417184 at fdab598b compiled both Apple targets and passed all sixteen listening/outbox
checks. Downloaded scrobble-review.json confirms actual timestamp preservation, correct payloads,
per-service acknowledgement, durable backoff/relaunch, account isolation and secret-free storage.
The expanded lyrics store passed nine checks, including keeping imported lyrics when clearing cache.
Guest verification still failed; service account authentication and actual scrobble delivery are
not established by the injectable transport checks.

Run 40269539723 at 71bc1938 compiled local artwork/albums changes and reached only the remaining
Guest-resolution failure after the extended native tagged-audio acceptance sequence. The count-only
artifacts are being retrieved for direct inspection. Shared-core run 40269539628 also passed.

Sound-profile editors now preview a logarithmic frequency-response chart. Points and preamp come
from the exact desktop Curve response, including filter centre frequencies. A Linux boundary check
compares the graph at the test filter's centre to actual rendered PCM within 0.02 dB; it passes,
along with Clippy and Swift syntax. Previewing still leaves playing audio unchanged. Apple graph
compilation, rendering and accessibility review remain pending.

## Request cancellation and sound observation (26 October 2026)

Native requests now have bounded IDs and explicit cancellation. Canceling a Swift task signals the
Tokio work, drops the request future and still returns exactly one owned callback. Start/cancel are
ordered by a small lock outside the audio thread; duplicate IDs and more than 256 simultaneous
registered requests are rejected. Cancellation does not abandon checked continuations. A host C
stress check passed 256 pending cancellations, 100 completion races, normal completion, duplicate
rejection and zero registrations remaining. All 53 shared tests, existing boundary checks, Clippy
and Swift syntax still pass. Swift early/in-flight/normal cancellation acceptance is pending Apple.

The player-menu EQ toggle previously lacked a direct apply handler. Sound configuration is now
observed once at app scope, covering preset, bypass, preamp, tone, normalization and profile edits
regardless of which screen changed them. Duplicate per-screen apply handlers have been removed.
Three native observation/latest-configuration checks are included; Apple results remain pending.

Directly downloaded local-playback-review.json from run 40269539723 confirms fifteen passing
checks, including actual tagged AAC export/import, cover/metadata restoration, embedded lyrics,
compilation grouping/order, native processed frames, real clock/pause/seek and media/cover removal.
The fixture is self-generated audio, cover and lyric text. Local album touch navigation and physical
phone behavior are still outstanding.

## Simulator fixture isolation repair (26 October 2026)

Run 40284403208 passed Apple host cancellation stress, all shared tests and both production iOS
libraries. Run 40284403215 compiled both app targets, but its Swift cancellation probe failed at
normal/in-flight calls while early cancellation passed. Direct artifact inspection confirms this
pattern. The simulator links an optimized Rust archive, where debug assertions had removed the
new delayed QA operation. This is a test-build mismatch, not evidence of passing wrapper behavior.

An explicit review-fixtures feature now enables that deterministic operation only for the simulator
archive staged by build_native.py. The iPhoneOS IPA archive keeps the feature off. Host CI also tests
that an optimized production archive rejects the fixture and that optimized QA cancellation passes.
Swift wrapper and sound-observation acceptance must still be rerun. The prior response graph was
visually inspected; its deep notch drew below the plot into the caption. Plot clipping is included
in 422e1bdf and awaits the new screenshot capture.

## User-requested current development IPA (26 October 2026)

The user explicitly requested an IPA with all current changes in ios/build/LATEST-VERSION.
Manual workflow dispatch can now publish an explicitly labeled development snapshot after the real
arm64 iPhone build and package integrity checks, while simulator acceptance still runs. Ordinary
push builds and the final unsigned artifact retain the existing full acceptance gate. Development
snapshots do not establish feature completeness. Package metadata now records source commit,
workflow run, build kind/time, build number and SHA-256. This snapshot increments the build to 10.

## Verified build 10 device archive and local library work (26 October 2026)

The user's requested development IPA is saved, unchanged, in build/LATEST-VERSION as
Sonora-0.3.0-build10-aad9b1de.ipa (6,927,846 bytes; SHA-256
82b2f2e2f85cf332ab92124591df692b300c8bb7b6e383c7ce891967b9bc4208).
Source aad9b1de; manual run 40287973238. Local validation checked archive CRC, source/hash, version,
and the actual arm64 Mach-O iPhoneOS platform (2), excluding Simulator platform (7).
Direct a6a322db artifacts confirm all three Swift cancellation and all three live sound-observation
checks passed. The clipped response graph was visually inspected; its notch no longer crosses
the caption. Guest verification remains failed and the full goal is active. This development
snapshot was explicitly requested; it is not a feature-complete release.

Build 11 work adds native local playlists, track/album/artist favorites and local artist pages.
The backend compiles the exact desktop local Store and storage crate, including SQLite schema,
with shared local ID namespaces. Bulk create/add/remove/delete/reorder operations are transactional;
stale/duplicate reorders are rejected. Deleted imports are cleaned out of playlists/favorites.
Sixteen native-boundary checks pass on Linux, including SQLite trigger-induced failure rollback,
NUL/Unicode IDs, duplicate prevention and damaged-file preservation. All 53 existing shared tests
and Clippy pass. Native state owns serialized writes; native drag ordering updates immediately and
rolls back/refetches on save failure. Canonically equivalent favorite names use a normalized ID.

Library Playlists combines account-independent local playlists and the existing YouTube collection.
Creation, selection/search, editing, add/remove/reorder, favorites, album/artist navigation and
player actions reuse shared song/artwork components. Local bootstrap now runs before remote account
restoration and the root no longer disables all local controls while sign-in is pending. Home is
refreshed after account restoration. Physical airplane-mode startup remains unverified.
Thirteen Swift state checks and four actual app-relaunch checks, using real imported generated AAC
files and a review-only database, passed on the iPhone 13 simulator at 9cabc6ce (run 40297091255).
Build 10 remains frozen for the user; these new changes belong to the next build.

Known next authentication issue: pinned ytmusic-rs persist_cookies explicitly replaces freshly
supplied headers when its cookie file exists. The current authenticate builder always enables that
file, so an old saved store can shadow a new login. Account restore/renewal also needs reliable
Keychain persistence of rotated cookies. This has been confirmed by source inspection, not fixed
or accepted with a real account. System Safari Google OAuth remains unimplemented.

## Build 12 user-reported playback and interface changes (26 October 2026)

The user reports that every YouTube song on build 11 has twice its normal duration, with a
silent second half, both downloaded and streaming. Desktop playback works. A CLI-resolved AAC
reference file reports 266.773333 seconds in ffprobe at 44.1 kHz; the old bridge truncated it to
266 seconds. The iPhone periodic observer unconditionally replaced provider duration with item
duration. A new timeline policy preserves precise source duration, reads native audio-track extent,
and sets AVPlayerItem.forwardPlaybackEndTime for both streaming and completed downloads. Legacy
downloads lacking source duration correct only a clearly doubled container against catalog data;
no blind divide-by-two or silence detection is used. Actual user recording/hardware acceptance is
still needed; the exact native cause of the doubled duration has not been independently reproduced.

Native regression checks now cover duration policies, a real AAC item reaching its bounded end,
persisted download source duration, old JSON decoding and saved playlist order. Apple runtime
results are pending. Shared Rust tests (53) pass locally. No user download is deleted for migration.

The inline tab accessory hides Next while the expanded accessory retains it. Queue removes the
segmented selector and edit-mode delete circles, keeps native reorder handles and swipe deletion,
provides Add Songs multi-selection, and reveals history above Queue by scrolling. The official
Apple queue screenshot and behavior source are recorded in References/AppleMusic/sources.json.
Sonora has no working AutoMix/Crossfade implementation, so no inert control was added for it.

Downloads now separates active transfers from completed categories (songs/albums/artists/playlists),
adds song search/sorting and recent tiles, and keeps retry/cancel accessible. Downloading a whole
playlist saves a separate atomic manifest of its name, cover and song order; existing individually
downloaded songs are preserved but cannot retroactively recover playlist membership. Detail pages
show only completed songs. Playlist, downloaded-collection and local-album heroes share responsive
cover sizing, title hierarchy and transport controls. Native visual and touch acceptance is pending;
this work does not establish an exact copy of every Apple Music page.

Follow-up interface review adds a simulator-only XCUITest target and real queue gestures (drag,
swipe removal, picker selection, clear). The target is excluded from device running/archive builds.
Queue uses ordinary List mode so swipe actions remain available; long-press reordering comes from
onMove, with an SF Symbol grip matching the reference. Actual touch acceptance remains pending.
The Library Recently Added section groups imported albums into covers; per-song deletion remains
available from the shared song menu. Local playlist titles collapse into the navigation bar on
scroll; Edit lives in its More menu. Online albums share the same collection header as playlists.

Run 40303761472 at 7132980a compiled both Apple targets and directly downloaded artifacts confirm
all 23 local/native playback checks, including precise source duration, legacy doubled-duration
handling and the real forward-playback end event. All four download duration/legacy-data/playlist
restore checks also pass. The run failed only at the pre-existing Guest Google verification gate.
The screenshots exposed opaque backgrounds on non-song queue rows and automatic List disclosure
chevrons inside recent cover tiles. Those are corrected by clearing individual row backgrounds
and using state-driven navigation from cover buttons. The collection cover uses one measured
artwork view rather than multiple asynchronously loaded ViewThatFits candidates.

A manual changed_ui review scope is available only with publish_development=true. It runs the
real playback/end, download migration, local playlist/relaunch, queue and XCUITest checks, plus
populated screenshots, and records review-scope.json with full_provider_acceptance=false. The
normal unsigned acceptance artifact is not uploaded by this scope. Default push and full manual
runs keep the complete existing acceptance gate. This avoids rerunning unchanged network lyrics,
fonts and Guest checks for visual repairs; it does not establish successful Guest playback.

Focused run 40307540029 at 8e25098f compiled device and simulator plus the XCUITest runner. Native
playback/download/local-store/relaunch checks passed again. Downloads category/song/album/playlist
touch navigation passed. Queue drag did not reorder; a grip nested inside the row's playback Button
was not a reliable independent drag target. It is now a separate native drag source with a private
app-only occurrence payload, drop-enter reordering through PlaybackController, and VoiceOver Move
Up/Down actions. Swipe removal remains in ordinary list mode. The rename test reached its real
alert but failed because the accessibility tree exposed two Save button wrappers; the test now
selects the first matching button. No claim of passing these two touch flows is made yet.

Run 40326174606 at 04e5f7cb built the production device app with the separate private-UTI drag
grip. Simulator test compilation failed only in the XCTest gesture call: XCUIElement.press expects
an element destination, while the intended target was an XCUICoordinate. The source grip is now
converted to a coordinate before the coordinate-to-coordinate press/drag call. App playback code
was not changed by that repair. Run 40327404338 at 836e89bc is queued for the corrected focused
review. No build 12 has been delivered to LATEST-VERSION yet. Builds 10 and 11 remain unchanged.

Review artifacts are now split: Sonora-iPhone-simulator-review contains top-level count JSON and
screenshots; Sonora-iPhone-touch-review contains the detailed xcresult bundle. The runner also
exports touch-review-summary.json using xcresulttool when available, including on test failure.
The former combined artifact could reach 75 MB and delayed simple screenshot retrieval.

The standard macos-26 run remained queued without an assigned runner. GitHub's official hosted
runner table lists xcode-27 as a standard free public-repository arm64 image, and the official
runner image manifest lists Xcode 27.1 plus iOS 27 runtimes. The fork is confirmed PUBLIC. A
separate codex/iphone-ios27-review branch adds an explicit runner choice so an iOS 27 review can
run without canceling the waiting main-branch job. Simulator selection now requires support for
iPhone 13 instead of blindly choosing the numerically newest runtime. No paid runner is selected.
Sources: https://docs.github.com/en/actions/reference/runners/github-hosted-runners and
https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md .

Run 40329068868 at 39c766f1 compiled with Xcode 27 and selected an actual iPhone 13/iOS 27.0
simulator (24A434). Native playback/end, download storage and local/relaunch checks passed.
Two of three real touch tests passed: Downloads navigation and local playlist rename. Dragging
still failed its order assertion. The next diagnostic run advertises the custom non-secret queue
occurrence representation to the system drag service, records bounded simulator-only drag events
and exports failure screenshots when xcresulttool supports that filter. No stream URL or account
token is in the drag payload. This distinguishes a rejected drag representation from a model or
accessibility-order problem. The revised collection cover was visually confirmed sharp and loaded.
Download playlist manifests are also removed when the user clears account downloads, so old
playlist names do not reappear if the same song is downloaded under another account.

Run 40332339702 at faaa7ce0 passed the same two UI tests but still failed queue order. Its bounded
drag evidence contains only provider-start callbacks for both visible rows, with no validate,
enter or drop callbacks. The accessibility snapshot confirms that both occurrences remained in
their old positions. Changing provider visibility did not fix the SwiftUI List drop path.

The queue's scrollable content now uses UICollectionView's native list layout, always-visible
UICellAccessory.reorder and diffable-data-source reordering handlers, in normal mode with native
trailing swipe actions. SwiftUI still renders the shared artwork/font labels and existing player
header/transport. PlaybackController commits complete upcoming UUID order only when it matches
the current set, so past/current entries and stale drag snapshots are protected. History and
Add Songs remain non-reorderable rows; proposed destinations are constrained to upcoming songs.
Initial queue scroll positioning waits for a real viewport. The discarded custom drag/drop type
and provider have been removed. Two model checks cover accepted and rejected native reorders.
Primary SDK references: https://developer.apple.com/documentation/uikit/uicellaccessory-swift.struct/reorder(displayed:options:)
and https://developer.apple.com/documentation/uikit/uicollectionviewdiffabledatasource-9tqpa/reorderinghandlers-swift.property .
Native touch acceptance for this replacement is still pending.

Run 40336060273 at 8e37d227 compiled the UIKit queue for device and simulator. Its simulator run
never reached any review route: installation took about a minute and the initial simctl launch
timed out after 120 seconds, followed by slow shutdown. This does not establish a queue pass or
a queue runtime failure. The next build allows 240 seconds for cold initial launch, retaining
existing bounded warm-route and test timeouts. Native labels now receive the selected appTypeface
environment and reconfigure on font changes. Bottom scroll inset keeps Queue initially at the
top even when only a couple of songs follow it; history stays above and is revealed by scrolling.

Run 40338448631 at 08f85276 again compiled both targets, but failed before app launch on the
cosmetic simctl status_bar override, which stalled for 120 seconds. That clock-normalization step
is removed entirely; it is unrelated to app functionality. Standard macos-15 is also selectable
with the officially installed Xcode 26.3 explicitly selected. Runner-specific concurrency groups
allow the same source to be checked in both free pools without canceling the other. iOS 27 remains
the preferred review target; the stable runner provides an independent iOS 26 compatibility check.

Runs 40350389659 (iPhone 13/iOS 27.0) and 40350397736 (iOS 26) compiled both targets and reached
real touch tests after removing the clock override. Both passed Downloads navigation, playlist
rename and the native queue reorder assertion. The iOS 27 test also removed the selected queue
occurrence, then failed by targeting the first app-wide cell behind the Add Songs sheet. The
iOS 26 assertion sampled row count immediately after the removal tap; animation timing remained
a possible cause of that failure. Tests now wait for actual
post-edit counts and target a hittable, explicitly identified picker song. No interaction check
has been removed or downgraded. New source retains the same native playback and queue logic.


## Current delivery policy (user update, 26 October 2026)

The user requested that visual review happen on their own iPhone, stopped iOS 26 testing and
asked not to spend time/tokens generating or inspecting more screenshots. Both active simulator
runs were canceled. The latest iOS 27 retry had failed on simulator installation before app
launch; that is infrastructure evidence, not an app feature result.

The default workflow now builds and packages the device app with Xcode 27, with no simulator
build, screenshots or touch review. Existing regression routes remain available through an
explicit manual full/changed_ui workflow. Those optional checks require an iOS 27 runtime and
cannot fall back to iOS 26. Deployment compatibility remains iOS 26+; it does not schedule tests.

Build 12 contains the duration/end correction, collapsed accessory controls, native UIKit queue,
Downloads categories and shared collection layouts. Prior iOS 27 evidence at df069025 passed
23 playback checks, four download checks, 13 local-library checks and four relaunch checks.
Downloads and playlist-rename touch tests passed; native queue drag and swipe removal reached
their assertions successfully. Complete Add Songs/Clear touch acceptance remains pending; the
last code change explicitly targets visible picker rows and awaits asynchronous count updates.
A build-only pass must not be called full feature acceptance. Account/Guest and desktop-parity
limitations in PARITY.md remain. The user's real-phone review is the next UI validation step.

## Build 13 functional verification (26 October 2026)

The user authorized live functionality verification and a replacement IPA if a defect is fixed;
visual screenshot review and iOS 26 testing remain excluded. A `functional` manual workflow
runs real iOS 27 state/Keychain/playback and touch checks, then attempts live Guest streaming,
full native download, seek/end controls and downloaded cold-launch playback with stream
resolution explicitly blocked. It emits count-only JSON, with no appearance screenshots.
An aggregate pass covers the named checks only, never complete desktop parity or physical-phone
acceptance. Private account credentials are not uploaded to GitHub.

Live Linux checks through the actual mobile FFI passed Home, four catalog result types (20 each),
Guest AAC resolution, all 6,992,801 expected bytes and full audio decoding. Provider duration was
431.933 seconds, ffprobe duration 431.933061 seconds, and no trailing silence was detected.
Lyrics lookup returned successfully. The available local desktop account could not be verified;
this is not an authenticated playback pass. These are Linux results, not an iPhone audio pass.

Source inspection confirmed that ytmusic.persist_cookies loads an existing jar over supplied
cookies. The iPhone bridge used a single global jar for all fresh sign-ins. Each attempt now gets
a private, unique jar and resolution cache. Only restoring an existing Keychain session may
migrate a legacy jar after checking its stable identity cookie. In-flight requests retain their
own jar and remove it after the last request completes. Account verification and rotation return
current cookies privately to Swift; Swift persists them in Keychain, rotates with one retained
cancelable task, and rejects refresh results across sign-out. Proof tokens are cleared on new
account verification. Three offline cookie regressions pass, bringing the shared suite to 56.
Actual iOS Keychain storage and native live playback checks are pending the new Apple run.

A quick backup-provider assessment found that the desktop Apple Music path uses Widevine and
has no equivalent wired into this native bridge. Subsonic requires a server/account, and Spotify,
Deezer and Tidal also need distinct account/playback integrations. No cosmetic provider entry or
unusable fallback has been added. Local imported audio and completed downloads remain available.

Build 13's signed-in Linux check also passed after restoring the desktop cookie jar through the
new same-identity migration path. Account verification, Home, Search, stream resolution, all
expected download bytes, full decoding, precise duration and absence of a doubled silent tail
passed. Credentials remained local and were not uploaded. The first iOS 27 run (40360499506,
fee7d5c3) compiled both native targets but timed out installing into the cold simulator before
launch. Cold install now has a 300-second bound; feature assertions have not been reduced.

The user's new Apple Music screenshots are recorded in References/AppleMusic/README.md.
The collapsed accessory retains both title and artist, uses a 30-point inline cover and only
Play/Pause, and clips overflow with a direction-aware native label alpha fade. Short text is not
faded; the full metadata stays accessible. The queue uses a 72-point current cover, larger row
metadata and a bottom fade into transport. Collection playback carries/persists real source
names for Continue Playing/From labels, without invented queue context.

Native zoom anchors the Now Playing sheet to the accessory and reverses on dismissal. A single
compact header is shared between lyrics/queue, while artwork/metadata morph from the artwork
stage with matched geometry. Artwork uses measured remaining space rather than a fixed chrome
height. System menus/submenus and native collection row drag/swipe behavior are retained.
Reduce Motion remains respected. A fourth touch flow checks mode changes, menus, dismissal and
reopening. No appearance screenshots are requested or analyzed. Exact animation parity cannot
be certified from static screenshots, and unsupported AutoMix/crossfade buttons are not faked.

Run 40374499230 at 3921f918 compiled both targets and ran on iPhone 13/iOS 27.0. All ten native
state/playback groups passed (92 boolean checks): cancellation, sound observation/profiles,
lyrics storage, scrobbling fixtures, AAC/local playback, download storage, local playlists,
relaunch and queue occurrence/order checks. Downloads navigation, playlist rename and the new
player modes/menu/dismiss/reopen touch flow passed. Native drag and swipe removal passed, but
Add Songs still had no hittable identified selection row. The picker now uses explicit native
row Buttons and selection circles instead of relying on a passive List selection label, with
full-row hit regions and selected accessibility traits.

The real Keychain check failed before its first assertion in the unsigned simulator app. The
simulator app is now ad-hoc signed with a simulator-only application identifier/access group;
the unsigned device IPA is unaffected and remains signed by iLoader at installation. Actual
Keychain failures now record only their OSStatus code for diagnosis, without credentials.

The runner also reused a pre-XCTest data-container path for later Home/Search/Guest evidence.
It now re-fetches the AUT container after XCTest installation and again for final diagnostics.
Those earlier missing files/null Guest result do not establish a provider pass or a Google
verification response. Live network results must be collected again from the active container.


Run 40379514699 at c6463d44 compiled both targets and verified the development IPA, but the
simulator returned NSPOSIXErrorDomain 3 (no process handle) before initial app launch. This
provides no new runtime acceptance. The simulator-only signature now explicitly emits DER
entitlements, as required by current Apple signing formats, and uses a complete test-only team/
application identity. The device IPA remains unsigned and does not contain these test identities.
The selected Simulator application's display services are activated by CLI for UI tests, with
no screenshots. Initial-launch failures now retain only termination/exception metadata from a
Sonora crash report for diagnosis. Apple reference:
https://developer.apple.com/documentation/xcode/using-the-latest-code-signature-format .

Run 40381404738 at 12e6111b compiled device/simulator and generated the verified device IPA,
but this runner image has command-line simulator services without the Simulator.app GUI bundle.
The added GUI activation failed before installation or launch. That optional activation is
removed entirely; headless simctl remains the path used by earlier successful native checks.
This was a runner setup error, not an app feature result. DER signature and launch diagnostics
remain. No GUI or screenshot work is requested.

Run 40383655659 at a2035d5d compiled both targets, then the captured launch diagnostics identified
CODESIGNING / Taskgated Invalid Signature, SIGKILL. The simulator-only ad-hoc signature no longer
claims a team identifier or debugger permission: it contains only the app identifier and its
own Keychain group, with DER encoding retained. This follows the ordinary self-contained
simulator app identity; real device signing remains entirely with iLoader. The prior run does
not establish any new native feature acceptance. Simulator signing troubleshooting has not
changed the release app code since the explicit picker fix.

Run 40385596637 at b4111278 again identified Taskgated Invalid Signature before app launch,
even with minimal ad-hoc entitlements. Manual simulator signing is removed, restoring the
unsigned headless simulator setup that actually ran 92 native assertions and three touch flows
at 3921f918. The simulator-entitlement file is removed as well. Keychain checks remain enabled
and must report their OSStatus/failure honestly; without a supported signing identity they are
not accepted. No weaker storage fallback or signing-policy bypass has been introduced. The
physical iPhone's iLoader-provided signature and Keychain still require phone acceptance. These
signing experiments changed only test infrastructure, not the device build's signature path.

## Candidate delivered for parallel phone testing (27 October 2026 local time)

At the user's explicit request, build 13 was placed in ios/build/LATEST-VERSION while the native
checks continue. Filename: Sonora-0.3.0-build13-e6868506.ipa; source e68685060fa4363a13283511e8bbd448366e554c;
8,100,138 bytes; SHA256 b339918ad2fe28aaa83c468c4e3d04a01e037e3d23b9447e3f3cd248cb8355d7.
Build/archive/arm64 iPhoneOS checks passed. Functional run 40387301121 is pending; no native pass
is claimed for that final revision. The user is sideloading with iLoader in parallel. Build 12
and its metadata remain under Previous-Versions. BUILD-INFO.json and VALIDATION.md explicitly
label native verification pending. No accessible physical iPhone was detected from this host.


## 27 October: reference and font follow-up (build 14 source)

- The requested 04:30 IST automation was not created before that time passed. The user resumed work after 07:00 IST; implementation resumed directly. No new automation is needed. Prior run 40387301121 had already finished; it was not canceled.
- All relocated WhatsApp screenshots and the 29-second video are present under ios/References. Contact sheets for reference study are ignored files under ios/build/reference-study, not app screenshots. No Impeccable skill or browser automation was used.
- All 35 native navigation title declarations now use shared typography integration for large/inline titles. Fonts update on attachment, appearance and settings changes; native navigation materials and title collapse remain system-owned. Font behavior needs native runtime acceptance.
- Songs merges local/liked tracks by stable ID, sorts titles and provides native alphabetical section indexes. Artists uses matching alphabetical grouping, circular artwork and native index. Downloaded songs defaults to title order with section indexes for title/artist sort.
- Queue current artwork/title and mode controls share the queue scroll position; history precedes them, with native overscroll and a threshold haptic. The header stays in the SwiftUI matched-geometry scene rather than being recreated inside another hosting controller. Native touch acceptance remains pending.
- Albums adds indexed two-column grid/list and title/artist/year sorting, with real album track resolution for Play/Shuffle. Playlist listing adds width-filling two-column covers, list/grid selection and native creation menu. These are source implementations, not a claim of exact Apple Music parity.
- Mini-player artwork reduced to 32 pt expanded / 28 pt collapsed. Collection Play/Shuffle use matching tinted-text capsules; Library/Downloads category typography and icons share one style. Default Music accent is red; explicit user-selected accents remain available.
- Remaining: validate navigation font behavior and queue scrolling on iOS 27; finish playlist/album cover-derived detail theme and exact detail transitions/submenus, downloaded collection grid/index consistency, and compare the remaining interactions with supplied references. Full app functionality, physical playback and Safari auth are not certified by this change.
- Build 13 IPA is preserved. Build 14 has not been delivered until a device artifact passes compilation/integrity checks.

### Build 14 continuation and build-service blocker

- Collection detail pages now derive a translucent background hue from their own cover, including local/offline covers, with an opaque reduced-transparency fallback. Albums and playlists use cover-origin native zoom navigation with reduced-motion fallback. Downloaded album/playlist browsers now also have two-column grid/list selection; downloaded Artists has a native alphabetical index and circular artwork.
- Year sorting now groups by real provided year, with an explicit Unknown Year group for absent data. Missing dates are not invented.
- Build 14 source passed Swift tree-sitter syntax checks, canonical localization/project regeneration and git whitespace checks. These are NOT Swift typechecking, native runtime or appearance acceptance.
- Pushed source commit 031589a3, but GitHub rejects both functional and build-only dispatch with HTTP 422: Actions has been disabled for this repository. Repository Actions permission reports enabled=true, workflow state active, and repository disabled=false; workflow enable through the CLI succeeds but dispatch remains rejected. User was asked to inspect the Actions warning. No build-14 IPA exists. Avoid repeated retries until that external state changes.
- Retrieved completed build-13 run 40387301121 small JSON reports. All four touch tests passed on iPhone 13 / iOS 27.0. Native local storage/playback/queue/lyrics/scrobble/sound checks passed. Home returned 83 items across 8 sections and 40 genres; Search returned 20 results for each supported category. Account Keychain probe failed with OSStatus -34018; Guest playback candidates returned network_verification_required, so live streaming/downloading on the iOS host remained unaccepted. These results supersede the previous in-progress notes. Physical iPhone sign-in/playback is still unverified.
- Updated local build-13 delivery metadata to mark final test outcomes without changing the IPA bytes. Remaining work needs native compilation/runtime validation after Actions is restored; exact reference parity and complete desktop parity must not be claimed.

### Actions restored; lyrics-source menu (build 15 source)

- User re-enabled workflows on the fork's Actions page. Build 14 run 40435163817 at d6193b72 compiled the arm64 iPhone device and simulator apps successfully; its functional checks started. This clears the earlier service blocker and establishes native compilation for the build-14 UI/font changes.
- User requested relocating the lyrics three-dot menu while the build ran. LyricsSourceToolbar is now a separate fixed-height footer immediately above playback progress, outside the lyric ScrollView/TimelineView. Caption is single-line/truncated, the menu has a stable 44 pt target and native menu presentation, and inherited SwiftUI animation is disabled only for the toolbar. Source selection, source settings, import, copy and refresh actions remain. It respects reduced transparency. This is build 15 source and needs its own compilation; build 14 does not contain this latest request.

- Build 15 run 40435748036 at d621802b1342e7605347c7dcb47b17861fcb591e compiled device and iOS 27 simulator successfully. Verified IPA delivered in commentary: ios/build/LATEST-VERSION/Sonora-0.3.0-build15-d621802b.ipa (8,278,630 bytes; SHA256 659f6654e701d751c793cfa5ea7f9ea821f5d83f4dbaac1824165237bd62d4d9). Functional acceptance pending. Build-14 run 40435163817 was canceled to avoid repeating the superseded tests; its verified archive is preserved under Previous-Versions. Build 13 remains intact. The build-15 player UI test now covers opening source settings from the footer and returning to a hittable menu button. This does not yet establish timed-scroll/physical-phone behavior.


## 27 October: build-16 reference correction

- Build-15 touch rerun 40437590729 at 227fe7c7 passed all four touch cases, including opening Lyrics Sources, selecting the sheet-scoped Done and returning to the footer. App source was identical to delivered build 15; the previous failure was its test selecting the underlying player-dismiss button with an unscoped Done query. Full-run provider/Keychain limitations remain.
- User supplied phone comparisons of Library and revealed queue history and reported that the artwork still disappears/reappears during mode changes. New screenshots are copied locally under ios/References without adding their media to Git.
- Library default now uses five categories, explicit 52 pt rows with zero vertical List insets, 20 pt horizontal margins, an inline-large native title, grouped add/edit actions and separate profile/settings button. Edit Library persists visibility of optional history/pinned/favorites categories without removing their data. Recently Added includes real remote/local collection covers in a two-column grid rather than placing liked-song rows below eight oversized categories.
- Shared song/artist rows now have explicit 56 pt minimum rhythm and matching insets. Grid caption hierarchy and artwork corner radii follow supplied references. Mini-player uses 16 pt semantic title / 15 pt artist at baseline, zero inter-line gap, full label contrast, and a 4 pt cover radius. Custom typeface/Dynamic Type continue to apply.
- Now Playing renders one persistent high-resolution cover in a parent overlay. Active geometry placeholders supply destinations for full artwork, lyrics header and queue header, and inactive outgoing placeholders cannot overwrite the current target. A non-bouncy 0.4 response spring moves the same image frame. It no longer swaps two AsyncImage/rendered views using matchedGeometryEffect, and the request rendition is constant across mode changes. Queue scroll moves the cover and header in one non-animated update; reopening resets history offset.
- Queue history now has an explicit 24 pt separation before current-song artwork. The current-song row and mode buttons remain part of the queue scroll, with reorder/removal preserved.
- Player progress uses a native adjustable UISlider subclass with a thin 3 pt idle track, a 44 pt touch surface and a tracking-only thumb. Hardware volume remains MPVolumeView, styled through public track/thumb image APIs. This removes oversized idle knobs from the user screenshots without replacing hardware volume control. Native seek accessibility commits adjustments as well as drag releases.
- Source passes local syntax/project/localization/whitespace checks. Build 16 still needs native compilation and touch acceptance; exact visual/animation parity must not be claimed from code alone. No app screenshots or iOS 26 tests were generated.
- Apple APIs verified through Firecrawl: toolbarTitleDisplayMode(.inlineLarge) at https://developer.apple.com/documentation/swiftui/toolbartitledisplaymode/inlinelarge and native toolbar spacing/background grouping in https://developer.apple.com/videos/play/wwdc2025/323/. The reference video, not a third-party replica, governs cover motion.

- Reference grid measurements use 20 pt outer margins and a 12 pt horizontal gutter, with 16 pt vertical rhythm. These give approximately 169 pt covers on a 390 pt iPhone screen. The first build-16 attempt was superseded before delivery to incorporate these shared measurements.

- Final build-16 run: https://github.com/icesaviour02-droid/sonora/actions/runs/40442189850, source 60a9536cfad861e4c122337cc91959df1d30c98d. Device app compiled; staged archive verified at 8,361,437 bytes with SHA256 58c72080c23d5ccb8bcc0b77204b525275e4fb563fd9659ae5ad21f344bc5f3c. iOS 27 simulator build/touch checks are in progress. Explicit reference targets are saved in ios/References/UI-REFERENCE-METRICS.md. Source attempt 40441305769 was canceled and force-canceled to release the runner; it was not delivered.

- Final build-16 run 40442189850 succeeded. Both native targets compiled, and all four iPhone 13 / iOS 27.0 (24A434) touch flows passed with no runtime warnings reported. Delivered archive: ios/build/LATEST-VERSION/Sonora-0.3.0-build16-60a9536c.ipa; 8,361,437 bytes; SHA256 58c72080c23d5ccb8bcc0b77204b525275e4fb563fd9659ae5ad21f344bc5f3c. Native scene/interaction tests do not certify visual identity, seek/hardware-volume phone behavior or real authenticated playback. Detailed limits and small JSON are in LATEST-VERSION/VALIDATION.md and CHECKS. Build 15's corrected touch rerun also passed 4/4; no earlier IPA bytes were changed.


## 27 October: build-17 history, metadata, volume and search correction

- User supplied seven new reference/comparison images. Apple idle volume track is approximately 6 pt; active is approximately 18 pt and widens horizontally. Build 17 retains MPVolumeView as the hardware controller, observes touch without canceling its tracking, updates public track image APIs, and animates horizontal expansion and speaker displacement. Its visible footprint stays 24 pt while its touch surface is 44 pt. No private volume-setting API or view-hierarchy lookup is used. Physical volume animation/hardware behavior still needs phone review.
- Root player cover escaped the queue mask because it rendered in a parent overlay. Cover and metadata overlays now share the actual queue viewport mask and fade. Only the queue viewport extends through the empty upper half of the progress touch area, ending at the progress track; bottom content inset keeps tail actions reachable. Its content shape also bounds history/header hit testing.
- Expanded and compact metadata no longer render/cross-fade two visible labels with matchedGeometryEffect. One persistent title/artist view interpolates size/position between invisible measured targets, retains the selected font and accessibility sizing, and follows the header's scroll offset in the same update as the cover.
- History is now a distinct native UICollectionView section with a self-sizing pinned supplementary heading and a real 24 pt footer inset. Queue stays in section 1; drop clamping was adjusted accordingly to protect native reorder. Clearing history repositions the current header.
- Added native navigationBarDrawer search to music collection pages (Library, Home, songs/artists/albums/playlists, history/pins/favorites, downloaded collections, local/provider detail pages, genres). Search uses actual cached metadata, case/diacritic folding and native scrolling/keyboard behavior. Library/Downloads root search spans their real entities; offline search includes pending transfers but never starts them as songs. Source playlist ordering and storage data are not mutated by search. Filtered local playlist deletion maps displayed IDs, and reordering is disabled during search.
- Mini-player now uses 17 pt semibold / 15 pt regular metadata at baseline with a 32 pt expanded cover and existing reference insets; dynamic fonts and explicit user preferences remain supported.
- Existing Downloads touch case now verifies pull-down field and actual filter/clear behavior. Added a targeted history gesture case using DEBUG-only seeded history, ensuring the pinned header remains usable and playback controls are not covered by the scrolled current-song header. It generates no appearance screenshots.
- Build 17 source has local Swift syntax and localization/project regeneration checks. Native compilation and interaction acceptance are pending. Build 16 remains the last delivered IPA and must be preserved until replacement. Full authenticated/Guest streaming, Keychain phone acceptance, Safari login and complete desktop parity are not established by these UI checks.
- Official search placement verified via Firecrawl: https://developer.apple.com/documentation/swiftui/searchfieldplacement/navigationbardrawer. The native drawer uses automatic hiding below navigation titles.

- First build-17 run 40451169429 at de3fca4f compiled both native targets and passed 3/5 touch cases (playlist, player/lyrics modes and queue reorder/edit). Search failed in the test driver because snapshot predicates cannot query the computed hittable property; replaced with real XCUIElement filtering. The history case revealed the player sheet dismissed on a third downward swipe after reaching the top of history. Queue/lyrics now disable that sheet gesture handoff; the dismissal handle still supports tap and downward-drag release, and artwork mode retains native interactive sheet dismissal. These are app changes, so a replacement IPA must be built. No first-attempt build-17 IPA was delivered.
- Collapsed mini-player cover updated to 30 pt to match the earlier 1170 px Apple reference crop; expanded remains 32 pt.

- Overlay clipping is now based on one persistent content viewport for all player modes, including the compact lyrics header. It always ends at the progress track, so moving from a deeply scrolled history state to artwork/lyrics cannot briefly reveal the old cover/title beneath transport controls. The bottom fade transitions to opaque outside queue mode; the layout footprint and native touch areas stay unchanged.

- Final build-17 attempt is run 40453452044, source 48c1129159f52149c1d9f6c224f2479452dd8028. It supersedes canceled 40452906867 (d70da4fd), and includes the stable all-mode content viewport mask. No build-17 IPA has been delivered yet.

- Run 40453452044 compiled and again passed the three existing playlist/player/queue-edit cases. Search pull/filter/restore succeeded, then the test selected Sort By rather than Back after search changed native toolbar order; it now targets the actual BackButton identifier. History stayed open after the dismissal guard, but further swipes starting on the overlaid current-song header did not scroll the native collection. The actual interactive header/mode controls now live in the native playerHeader cell. A hidden non-interactive layout twin only supplies root-space geometry for the single visible cover/title; it does not render duplicate labels or controls. This preserves native gesture arbitration and inertia from the header as well as song rows. A replacement build is required for these application changes.

- Run 40462623332 at 0da1e225 compiled both targets and passed 4/5 native touch cases. The history regression now passes: native scrolling from the current header reaches history, the header leaves the playback region, and Clear restores it. Search filtering/restoration passes, but the category test cannot locate the assumed private BackButton identifier after search. The test now exercises the native left-edge back gesture and waits for the real destination category before continuing. This is a test-only correction; app source remains unchanged. No failed-run IPA has been promoted.

- Run 40464059091 also passed history/playlist/player/queue editing (4/5), with no runtime warnings. Search filtering/restoration passed, but a left-edge gesture did not reach Downloads while search was active. This is not full search/navigation acceptance. The shared drawer now explicitly preserves navigation toolbar content during search using Apple's documented searchPresentationToolbarBehavior(.avoidHidingContent), and the test taps the actual visible leading navigation control and records textual hierarchy on a destination failure. Source: https://developer.apple.com/documentation/swiftui/view/searchpresentationtoolbarbehavior(_:). A new device archive is required for this app change; earlier build-17 snapshots remain staged only.

- Final build-17 run 40465544047 at cf433d7f809e5c6350456649239daf3a3677a2c2 succeeded. Device and simulator targets compiled; all five targeted touch cases passed on iPhone 13 / iOS 27.0 (24A434), with no runtime warnings. This includes pull-down search/filter/restore and return navigation, local playlist rename, player/lyrics-source menus and mode return, history scrolling/clipping/clear/transport access, and native queue reorder/swipe/add/clear. No appearance screenshots were generated/inspected and no iOS 26 tests ran.
- Delivered candidate: ios/build/LATEST-VERSION/Sonora-0.3.0-build17-cf433d7f.ipa; 8,523,228 bytes; SHA256 1cb7ba239dd0f7bee462dd56515a0945308e29000d93d595e5521e8579f2f303. Local archive integrity, metadata, arm64 iPhoneOS Mach-O platform and absence of test bundles were verified. Build 16 and previous IPA files remain intact; build-16 delivery notes were copied to Previous-Versions. Read current VALIDATION.md and CHECKS/ios27-build17-*.json. This is targeted native UI acceptance, not exact visual identity, physical-phone volume/seek/motion or provider/background/AirPlay acceptance. Full-run Guest/Keychain limitations, Safari sign-in and other provider gaps remain as previously recorded.

## 27 October: build-18 motion, metadata and navigation correction

- New 13:46 video and four screenshots are copied locally to ios/References/build18-* and are not bundled or committed. Used apple-design, not Impeccable. Studied only the supplied reference video, not new app screenshots. Reference video measures approximately 250 px paused / 340 px playing artwork at a fixed center (ratio 0.735); playing art extends 10 pt beyond the text margins. Play/pause now uses a critically damped 0.48-response spring and a lighter cover-shaped shadow.
- Full player now targets 20 pt title/artist and 15 pt mini-player title/artist at the default text size, retaining custom fonts/Dynamic Type. The hidden geometry targets and visible labels use the exact same UIKit measurements to avoid clipped artist descenders. A single stationary trailing mask clips moving text before favorite/menu controls; per-label masking is disabled in that layer to prevent stacked fades.
- Artwork and metadata now share a horizontal queue swipe with real adjacent occurrence previews, direct tracking, projected release, boundary resistance, spring cancellation and paused-state preservation. Real queue selection stays in PlaybackController and preserves repeated-track UUID identity.
- Library Edit is inline: existing rows shift to selection circles/native reorder handles, optional categories enter, recents leave, toolbar changes to Done, and selection/order persist. The root Library search drawer is removed. Collection drawers remain. Main Search is provider-only; YouTube Music is the only implemented remote provider in this iPhone target, so no nonfunctional Apple Music option is added.
- Songs action-only rows/sections hide separators. MPVolumeView stays the real system control, inside a native host that aligns speaker symbols against public volumeSliderRect geometry. Retina capsule images stretch their solid centers, and no whole-control scale/blur is applied. Cannot subclass MPVolumeView; the host owns a normal instance. Official APIs checked: https://developer.apple.com/documentation/mediaplayer/mpvolumeview and https://developer.apple.com/documentation/mediaplayer/mpvolumeview/volumesliderrect(forbounds:). Simulator cannot establish physical volume behavior.
- Added targeted native swipe-forward/back and inline Library category-edit flows to existing interaction checks (seven cases total). Local Swift syntax, project/localization regeneration and whitespace checks pass. Native compilation/touch acceptance pending; build 17 remains last delivered and must be preserved. Provider/Safari/account/background/AirPlay limitations are unchanged.

- Initial build-18 source 6ddf525c in run 40474717351 compiled the device app. Before delivery, player vertical layout was adjusted to the reference's fixed artwork center: a 100 pt artwork-mode transport reservation and -12 pt artwork-stage offset move seek/metadata into the reference spacing while keeping the volume/footer placement. This needs a replacement build; no build-18 IPA was delivered from the initial attempt.

- A final read-only layout audit found that the larger playing cover and its soft shadow can extend slightly above the flexible artwork slot. The overlay mask now allows 32 pt of upper breathing room in artwork mode, keeping the bottom boundary at progress unchanged. This is a rendering-only refinement on non-interactive overlays; the seven-case interaction run at 4c2ffdbe can validate the unchanged interaction code, but the final archive must be compiled from the refinement commit. Do not label its exact pixels as simulator-verified.

- The final volume-symbol rendering also uses centered native-size SF Symbols, avoiding UIImageView aspect-fit enlargement of a 12 pt glyph. This changes rendering only; hardware volume control and gestures are unchanged. Include it in the final compiled artifact and record the interaction-source revision separately.

- Run 40475304344 compiled both native targets. XCTest logs show six passes: adjacent artwork swiping, Downloads/search navigation, playlist rename, player/lyrics/menu return, queue history/clipping/Clear, and native queue edit. The inline Library test failed while querying a NavigationLink only as Button after Done; the test now queries its actual identifier/label across accessibility roles and checks selection persistence by reopening editing first. This is not yet a proven test-only cause: if the persisted selection check fails, fix the app. The overall 360-second process deadline expired after all seven test bodies finished (317 seconds total), so no finalized summary was produced; the bounded allowance is now 480 seconds for the expanded suite. No build-18 archive has been delivered. The replacement run must include the final shadow/speaker rendering refinements and all seven cases.

- The swipe surface now explicitly includes the full artwork-stage rectangle, including its hidden metadata layout target, so gestures beginning over the displayed title/artist are delivered as requested. The existing swipe test now goes forward over artwork and backward over the metadata area. Run 40478394037 is superseded before delivery by this functional hit-surface refinement; the replacement runs all seven cases, including the strengthened Library selection test.

## Build 18 continuation: additional 13:59 / 14:37 motion references

- User added two Apple Music videos and History header comparison screenshots during the active build. New media is saved locally under ios/References/build18-apple-player-pill.mp4, build18-apple-queue-actions.mp4 and the history-heading PNGs, never committed/bundled. Continue all earlier build-18 requirements; none were canceled.
- Run 40478713253 at 2d35e9d7 compiled both targets and passed five of seven cases. Artwork-to-next and metadata-to-previous swiping passed, as did playlist/player/queue-history/queue-edit cases. Downloads search failed a global text-existence assertion that could include the underlying root page, so it now scopes results to an identified current Songs collection. Inline Library category persistence failed; this was not a successful app check. Custom buttons in an editing List are replaced by native List(selection:) check circles with a direct persisted binding, native reordering and inline Done. The revised test checks actual category appearance plus relaunch persistence rather than an assumed child accessibility trait.
- Seeking now uses a public UIControl covering the entire 44 pt target, deterministic tap/drag mapping, a native adjustable accessibility surface and exact AVPlayer seek tolerances. A seek generation guards stale completions, and periodic old clock samples cannot overwrite a pending position. Native clock revision publishes paused seeks. A new real-local-audio touch case taps ~80%, drags back ~25% and checks AVPlayer.currentTime, not just UI percentages (eight cases total).
- A shared high-resolution cover travels above the native sheet between actual accessory/player UIView anchors. UIKit animateAlongsideTransition(in:animation:completion:) synchronizes it with native open/close/interactive cancellation. Source/destination covers hide only during that flight, with cleanup/fallback and high-resolution image improvement. Native modal gestures remain; the old whole-pill zoom is removed. This is source implementation, not visual identity acceptance.
- Favorite/menu actions retain real native row controls while a single non-interactive moving visual layer follows measured bounds between modes. History cells clip below the pinned History/Clear heading and share that upper bound with floating cover/text overlays; the extra material stripe is removed. Queue badges show real shuffle/repeat/infinity states; Apple's unsupported fourth AutoMix/crossfade control is not faked.
- Official APIs verified: https://developer.apple.com/documentation/uikit/uiviewcontrollertransitioncoordinator/animatealongsidetransition(in:animation:completion:) and https://developer.apple.com/documentation/avfoundation/avplayer/seek(to:tolerancebefore:toleranceafter:). Native compilation and eight-case interaction acceptance are pending for these added changes. Build 17 remains last delivered.

- Run 40482593645 at 46c6ef26 compiled both native targets and passed six of eight cases, including real native-clock tap/drag seeking, Library visibility across relaunch, scoped Downloads search, artwork/metadata swipes, playlist rename and history clipping. Player mode return found duplicate native menus because animation/layout copies still constructed real Menu controls. Those copies now render static shared glyphs only; only the active stable row constructs real actions, and the test asserts exactly one Song Actions control.
- Queue editing exited the app during native reordering; its exact crash stack was not in the small report, and the large result-bundle download timed out. History clipping no longer asks layout attributes for absent supplementary headers, does no mask work while UIKit is lifting/dropping rows, and only changes masks it owns (never native reorder/swipe masks). This is a candidate fix pending regression acceptance, not a proven root-cause claim. Failed runs now export bounded text crash summaries from native xcresult diagnostics if available, with no screenshot export. No build-18 IPA has been promoted.

## Final build-18 acceptance and delivery

Source d15d7b9c3d6beccc68b6866c3c87b3a6239728ba; successful run https://github.com/icesaviour02-droid/sonora/actions/runs/40504942163. Both native targets compiled. All eight iPhone 13 / iOS 27.0 (24A434) interaction cases passed; zero failures and no runtime warnings reported. The final checks include scoped Downloads search/navigation, playlist rename, player/lyrics/menu/dismiss/reopen (one real Song Actions menu), native queue reorder/swipe/add/clear without app exit, history clipping/Clear/available transport, artwork-forward and metadata-back queue swipes, inline Library selection plus relaunch persistence/no root search, and tap/drag seeking checked against AVPlayer.currentTime of real local audio.

Delivered: ios/build/LATEST-VERSION/Sonora-0.3.0-build18-d15d7b9c.ipa; 8,603,227 bytes; SHA256 920dc4e7154ea721eba5be4e4cc4270df1d428ea5d03a5564cfd755c328ca0bd. Device ZIP/metadata/Mach-O arm64 iPhoneOS integrity verified; no test bundles packaged. Unsigned for iLoader. Previous IPA files remain intact and build-17 delivery notes are preserved under Previous-Versions. Small JSON is stored in CHECKS/ios27-build18-*.json; current BUILD-INFO.json and VALIDATION.md describe this exact candidate.

The duplicate menu and queue-editing exit from the previous run did not recur. The exact earlier crash stack was unavailable, so do not claim a confirmed crash root cause beyond the validated safer mask handling. No app screenshots were exported or visually reviewed and no iOS 26 tests ran. Native behavioral acceptance does not certify exact Apple Music pixel/motion identity or physical system-volume behavior. Guest/authenticated streaming, downloads from a live provider, signed-phone account persistence, background audio and AirPlay were not repeated in this UI run. Safari sign-in, additional remote providers and complete desktop parity remain unfinished. The implemented queue modes are shuffle, repeat and autoplay; unsupported Apple-only mixing controls are not faked.


## Build 19: 19:31 / 20:01 fullscreen, menus and motion corrections

- Local-only reference media: build19-apple-fullscreen.mp4 (actually queue/history context-menu recording), build19-apple-queue-volume.mp4 (fullscreen pull and volume recording), Apple/Sonora fullscreen JPEGs and inline-mini JPEGs. Media is never committed or packaged. Used apple-design and Firecrawl, no Impeccable or browser automation. Only supplied reference media was sampled; no app screenshot audit.
- Replaced the large sheet with a window-sized custom UIKit presentation, native UIViewPropertyAnimator plus UIPercentDrivenInteractiveTransition. Downward pulls over cover/metadata/empty space follow the finger; projected release chooses dismissal or cancellation. UIControl, collection scrolling and explicit SwiftUI control rectangles retain their inputs. Artwork and panel use the same interruptible animator, not two separate timing curves. Reduced Motion uses a fade. Existing system sheets/menus stay native.
- One persistent real favorite/overflow row now uses root-space measured targets throughout artwork/lyrics/queue. No glyph-to-real-control handoff occurs at animation completion. Geometry refinements retarget the same spring while mode motion remains active; history scroll keeps its direct position updates.
- Native UICollectionView context menus provide lifted queue/history previews with Favorite, Add to Playlist, Play Next, Play Last, download/remove download, and remove queue/history. Upcoming edits move the exact occurrence UUID rather than add a duplicate. History actions preserve the original history selection. Existing native reorder handles and swipe removal remain.
- Mini-player targets 14/14 pt labels at default Dynamic Type, removes the inline explicit badge that interrupted the text fade, and retains the full 44 pt play target plus existing 30/32 pt art. Selected fonts/accessibility scaling remain. This is reference-based sizing, not certified one-to-one pixel identity.
- Volume remains the real system MPVolumeView. A weak display-link ticker retargets the activation state and updates native retina track images plus width/brightness together over 0.22 s. Speaker baseline reads the documented UISlider track geometry when available, with MPVolumeView public drawing-rectangle fallback. No private slider class names, volume setters, bitmap scaling or copied private Apple code.
- Sources: https://developer.apple.com/documentation/mediaplayer/mpvolumeview (public supported customization) and https://github.com/pratikg29/Custom-Slider-Control (MIT public recreation, inspected VolumeSlider.swift). The recreation uses bound-value SwiftUI drawing, not system output volume; no source was copied. It is not Apple's original Music implementation.
- Existing eight interaction cases are retained, with fullscreen bounds/pull/cancel/dismiss/reopen and queue/history native long-press actions added (ten cases). Local project/localization generation and Swift syntax checks pass. Native compilation/interaction acceptance pending. Build 18 remains last accepted; do not replace it before reviewing final build-19 results. Provider/account/background/AirPlay gaps unchanged.


- First build-19 run 40526280563 at c8d2d8af compiled device and simulator targets. Nine of ten tests passed with no runtime warnings. Fullscreen bounds, a canceled pull, and committed artwork pull-down all passed, but reopening after the interactive dismissal failed. Long-press queue/history reorder/removal passed alongside all eight previous cases. This is an app lifecycle issue candidate, not visual acceptance. Interactive cleanup now waits for UIKit's actual dismiss completion, with success/cancel recorded by the animator before transition completion; it no longer clears the retained controller inside the animator completion. Debug-only flag evidence is exported without screenshots. The final build also corrects remote playlist actions to editable YouTube playlists with retained/cancelable store requests, preserves local playlists for imported songs, rounds the surface during a pull, and captures fullscreen status-bar appearance. Replacement native acceptance required; first IPA is staged only.

- Inline pill measurements from the provided crops locate Apple's play center about8 pt farther right than Sonora relative to equal pill widths. Final inline trailing padding is8 pt instead of16 pt; leading inset and44 pt hit target are retained, allowing the metadata fade boundary to extend accordingly. Run40530414310 is superseded before delivery so this final requested position correction and the dismissal fix are built/tested together.


## Final build-19 acceptance and delivery

App source b10b94a365c255c91e09d5d8b4d849c647c01e1e; successful run https://github.com/icesaviour02-droid/sonora/actions/runs/40531111456. Both native targets compiled. All ten targeted iPhone 13 / iOS 27.0 (24A434) interaction cases passed, with zero failures and no runtime warnings.

The added fullscreen case confirmed the player covers the full window, survives a canceled pull, dismisses from artwork, reopens afterward, and dismisses again from empty space. Debug lifecycle flags confirm cancel retained the presented controller, committed cleanup occurred with no presented controller remaining, reopening presented a new controller, and the second pull cleaned up. This validates the UIKit-completion cleanup fix; the previous candidate's reopening failure did not recur. The added context-menu case moved an actual queue occurrence with Play Next, removed it, opened a history-row menu and removed that history entry. Existing eight touch regressions also passed, including native audio clock seeking, queue reorder/swipe/add/clear, history clipping, artwork/metadata horizontal swipes, Library persistence, Downloads/search/navigation, playlist rename and player/lyrics-source/menu return.

Delivered: ios/build/LATEST-VERSION/Sonora-0.3.0-build19-b10b94a3.ipa; 8,603,290 bytes; SHA256 2dd529d51489dcdd775d1db0dc63104a8680c7c50a73b456caf04bb7ec56119a. Unsigned for iLoader. ZIP integrity, device metadata, arm64 iPhoneOS Mach-O platform and absence of test bundles were verified. Build 18 and all previous IPA files remain untouched; build-18 delivery notes were saved under Previous-Versions. Current BUILD-INFO.json, README.txt, VALIDATION.md and CHECKS/ios27-build19-*.json describe the accepted candidate. Documentation-only commits after the app source do not alter this artifact.

No app appearance screenshots were exported/visually reviewed and no iOS 26 tests ran. Native behavior acceptance does not certify one-to-one Apple Music visual/motion identity or physical system volume. Only supplied reference media was sampled. No original Apple Music source was obtained. Live YouTube streaming/downloads, authenticated account persistence, background audio and AirPlay were not repeated in this UI run. System Safari sign-in, additional remote providers and complete desktop parity remain unfinished. Native provider playlist operations compile and are appropriately routed, but require a signed-in phone account for live acceptance.


## Build 20: collection transitions, player proportions and selected-row previews

User supplied three videos and the marked Apple/Sonora player PNG pair. All are copied locally to ios/References/build20-* and excluded from commits/packaging. The 21:20 recording compares collection navigation; the 21:53 recording shows Sonora queue context-menu highlighting; the 21:46 recording shows Apple's whole-player pull-down and reopening. Only reference media was sampled; no app appearance screenshots were generated/reviewed. Continued both prompts and used apple-design, never Impeccable.

- Removed the detached UIImageView cover flight and custom percent-driven screen animator. Now Playing uses public UIViewController.preferredTransition = .zoom from the full live accessory anchor with a .fullScreen presentation. UIKit owns the whole moving page, continuously interactive spring, cancellation and reversal. Options reject horizontal track gestures, scrolling and control rectangles. Native completion/lifecycle cleanup retains the host until a completed dismissal and preserves reopening. No independent artwork snapshot or delayed cover handoff remains.
- New screenshot measurement targets: playing cover margin24 pt (342 pt at390 pt width); grabber60 x4 pt,7 pt above its previous position; full-player favorite/menu targets have4 pt inter-target spacing and6 pt outward offset; overflow20 pt; play/pause44 pt; previous/next move12 pt inward; transport group moves14 pt up; duration labels10 pt up; footer26 pt inner inset and5 pt downward placement. Existing custom fonts/Dynamic Type remain. Codec strings no longer appear in the player progress badge; actual offline availability remains. Physical screenshots are still needed to certify exact matching.
- MPVolumeView still controls system volume. Track alignment now finds the documented public UISlider recursively, handling the additional native container seen on the phone, rather than only checking direct children. No private class names or setters are used.
- Queue/history use current iOS16+ UICollectionView context-menu delegates. Both highlight and dismissal previews target the actual pressed cell.contentView, with a rounded visible path. Sonora removes only its owned history mask for that cell and suspends refresh/clipping through the native context-menu lift/dismiss sequence. A single material preview shows the selected track's own cover/title/artist/album; tapping it commits the corresponding real queue/history song. UUID-sensitive actions/reorder/swipe removal remain. Debug-only selected-row flags export without screenshots.
- Native cover zooms are added to Library Recently Added local/remote playlists and albums, local/provider artist album links, and offline album/playlist/recent links. Existing grid/list source identities now attach to the artwork, excluding title/artist labels. Shared reusable cards/row labels gain coverSource builders. Native toolbar action IDs/placements remain consistent between root and collection pages; system glass grouping and navigation handle their motion. Library category rows explicitly show bottom separators using the native separator color.
- Eleven native interaction cases retain all ten previous checks and add opening/returning through actual Library album/playlist cover buttons plus toolbar actions. The context-menu run additionally requires debug evidence for both queue and history targeted previews. A DEBUG generated-recording fixture seeds the real collection browser, not a destination-only sheet. Local project generation, Swift syntax and whitespace checks pass. Native compilation/acceptance pending. Build19 remains last accepted; provider/account/background/AirPlay gaps are unchanged.

Primary APIs verified via Firecrawl: https://developer.apple.com/documentation/uikit/enhancing-your-app-with-fluid-transitions ; https://developer.apple.com/documentation/uikit/uiviewcontroller/transition/zoom(options:sourceviewprovider:) ; https://developer.apple.com/documentation/uikit/uiviewcontroller/transition/zoomoptions/interactioncontext ; https://developer.apple.com/documentation/uikit/uicollectionviewdelegate/collectionview(_:contextmenuconfiguration:highlightpreviewforitemat:) ; https://developer.apple.com/documentation/swiftui/toolbaritem/init(id:placement:content:). Native public transitions are used; original Apple Music private code was not obtained. Stable toolbar IDs alone are not proof of exact Apple Music morph timing.


- First build20 run40549769861 at944149bd compiled both targets. Five of eleven native cases passed (collection cover navigation/toolbars, Downloads/search/back, inline Library editing, playlist rename and native-clock seek). Six player cases failed because the system zoom modal integration made required player controls unavailable; there is no passing fullscreen/queue acceptance for that candidate. No IPA was promoted. The debug source showed UIKit removed the underlying presenter's view from its window after a fullScreen presentation, but the exact missing-control cause was not established from the small report. Do not claim a confirmed UIKit bug.
- Replacement keeps the tested build19 full-window custom presentation/interactive driver and its validated dismiss-completion cleanup. Its detached cover flight remains removed: the real artwork, labels and controls stay inside the same moving fullscreen surface during pull, release and cancellation. Whole-panel translation and continuous corners follow the same UIKit property animator; no separate album-art animation or hide/show handoff occurs. Public native cover navigation and selected-row menu preview fixes remain. This supersedes the attempted preferredTransition.zoom adoption above; native behavior acceptance must be repeated before delivery.


## Final build-20 UI acceptance and delivery

Source d03b6d964f008750c3888a6b284695a2e3fffbd0; successful run https://github.com/icesaviour02-droid/sonora/actions/runs/40553369272. Both native targets compiled; all eleven iPhone13/iOS27.0(24A434) targeted interaction cases passed, with zero runtime warnings. Queue and history actual-cell highlight/dismiss preview evidence was exported and verified. Full-window drag/cancel/artwork-dismiss/reopen/empty-space-dismiss passed, alongside native clock seeking, track swipes, history clipping, queue editing, Library persistence, Downloads/search, playlist rename/player menus and actual recent-collection open/back/toolbar actions.

Delivered UI candidate: ios/build/LATEST-VERSION/Sonora-0.3.0-build20-d03b6d96.ipa;8,624,777 bytes;SHA256032c27eeb5e2af597d0de9f8a566b145c39db582e0bfcdab08de9e71018a39ed. All package/device checks passed; unsigned for iLoader. Build19 and earlier files preserved, with build19 notes under Previous-Versions. No app appearance screenshots were exported/reviewed and no iOS26 tests ran. This uses the tested full-window UIKit custom presenter/percent driver with all real player elements inside one translating surface. The attempted system preferredTransition.zoom modal was removed after its regression; do not describe the delivered fullscreen player as that system modal zoom. Collection navigation remains native cover zoom. Physical exactness and volume need phone review; provider/account/background/AirPlay limits unchanged.

Reference files are local-only: build20-collections-comparison.mp4 (21:20), build20-sonora-context-menu.mp4 (21:53), build20-apple-player-dismiss.mp4 (21:46), build20-apple-player.png and build20-sonora-player.png. The later lyric-download request is not included in this UI20 IPA; it is being built as21.


## Build 21: automatic durable lyric downloads

User explicitly requested timed lyrics files with music downloads while UI20 testing was active. This extends the ongoing task; UI20 has been delivered for parallel phone review, while21 includes both accepted UI changes and lyrics.

- Completed audio downloads automatically queue a bounded serial lyrics fetch using existing NativeProvider.lyrics and the enabled source order, actual track metadata and source duration. Missing sources do not fail/delete the audio. Existing downloads backfill; transient failures retry on foreground, source changes retry prior unavailable responses, and Refresh can explicitly requeue lyrics without downloading audio again. Cellular policy is respected using NWPathMonitor, with cancellable UIKit background time when available. OS suspension can defer unfinished lyric work until the app resumes; permanent background execution is not claimed.
- Durable files use the unique audio filename: UUID.lyrics.json plus synchronized UUID.lrc. JSON preserves source choices, original line/word timestamps, romanization, backing lanes and writer data; timed/worded choices rank before plain sheets. LRC preserves supplied timestamps only. If no timed source exists, the available plain content is preserved; no timing is fabricated. Instrumental responses are retained appropriately.
- Actor file IO validates owned UUID m4a paths and requires the actual audio file. Cancellation/generation guards prevent stale requests changing replaced/deleted entries. Removing music, signing out or retrying/replacing its file removes only that audio's sidecars. Download lyric files are outside temporary lyric-cache storage and survive Clear Cache. Missing saved JSON requeues on restore.
- The player reads download sidecars in saved-only mode, independent of metadata cache-key changes and without contacting source services. User-imported local sidecars keep priority when enabled. Download status changes refresh an open lyrics view. Existing rendering/seeking consumes the same preserved timing models.
- A generated fixture uses real downloaded AAC, enhanced LRC parsing, a competing plain source and actual disk persistence. Eight checks cover preferred timed/word choice, timestamp fidelity, durable JSON/LRC, cache clearing, new-store saved-only restore, persisted status and retained audio. An added native case restarts the app, renders the offline lines and taps a timed line to verify actual audio-clock movement. All previous eleven UI tests remain (twelve total). These are local/offline acceptance checks; live per-song lyric service availability and signed-phone background downloading still need real-phone review.


- First21 run40557011562 at9f9e7b0a compiled both targets and passed11/12 native cases. The new timed-download case passed, including cache-clear/fresh-store restore, app relaunch, visible offline lyric rows and a lyric tap checked against the audio clock. All eight disk/timestamp flags passed. Existing Downloads search timed out while asserting that a filtered row's accessibility node no longer existed; this does not establish a filtering failure or a test-only cause. The test now checks the actual input value, visible No Results content and absence of a hittable old result, then checks visible restored content. It uses a bounded12 s wait to accommodate native accessibility updates. An AVAudioSession main-thread activation warning was also reported; system category/activation now runs on a serial actor with retained task, pause/occurrence/generation guards before starting native playback. A final guard prevents lyric fetches/mutations while download-index restoration has failed. Replacement compilation and all12 cases required before delivery; no21 IPA has been promoted.

- Before delivery, async audio activation now publishes loading state and Toggle follows the existing playback intent as well as native play/loading flags. A second tap while session activation is pending therefore pauses/cancels rather than issuing another Play. Success/error clear the activation loading state. Run40560148128 is superseded before acceptance so this final cancellation behavior is included in the exact tested archive; no further UI/design changes were added.


## Final build-21 acceptance

Source055ce8611bdbc86d34a339a51cf2ec2012d9fe0c; run https://github.com/icesaviour02-droid/sonora/actions/runs/40561102402 succeeded with both native targets compiled,12/12 targeted interaction cases passed and zero runtime warnings on iPhone13/iOS27.0(24A434). All eight durable lyric checks passed, plus queue/history native targeted-preview evidence. The native case confirms offline timed lyrics survive cache clearing and relaunch, and tapping a line moves the audio clock. Live source availability and phone background completion remain unverified.

Delivered archive: ios/build/LATEST-VERSION/Sonora-0.3.0-build21-055ce861.ipa;8,660,045 bytes; SHA2564cd66b515c37a2a8e1b095e0ff94ca5596766f52d8c4b31604dcfe0403f3e5ee. Older IPAs preserved. These checks do not certify exact Apple Music pixels, physical volume, live account/provider parity, background or AirPlay. No appearance screenshots or iOS26 tests were run.

## Build22: late cover handoff, native volume and offline spacing

Pending native acceptance. Keeps the accepted rounded full-window percent-driven pull/cancel lifecycle. Artwork stays in the panel while the finger is down. After committed release, its actual high-resolution image moves into the actual mini-player cover during the final40% of panel travel; the live presentation-layer displacement drives the handoff. Real UIKit cover nodes and their shadows hide/restore synchronously, without SwiftUI opacity races. Reduced Motion skips the separate flight. Twelve targeted cases remain, with full-window dismissal using generated tagged AAC artwork and DEBUG geometric/alpha evidence required for a late, post-release handoff and restored real images.

Per the user's explicit request to simplify the glitchy volume control, MPVolumeView now has no custom track/thumb images, scaling, activation animation or separate speaker icons. Native iOS owns the slider's internal alignment and touches. Physical hardware-volume behavior still requires phone review. The offline badge is centered separately below the time-label row in the gap before transport; its position no longer inherits the labels' upward offset. Automatic durable lyric downloads from21 remain included.


Build22 sourceba296bce run40567369671: both targets compiled in both attempts. Attempt1 timed out in a simulator launchctl diagnostic before any native interaction case ran; it gives no behavior result. Attempt2 passed11/12 cases with zero runtime warnings. Full-window cancellation/artwork-dismiss/reopen/empty-space-dismiss, actual late post-release artwork handoff and synchronous source/mini alpha restoration, timed lyrics after relaunch, native seeking, collections and queue/history previews all passed. The Downloads search test reached visible No Results for the entered query, then blocked repeatedly resolving the removed old result's isHittable property. The assertion now checks existence before querying that property, while still requiring the actual entered value, visible No Results and restored visible content after searching Review. No app behavior change was made for this correction; new native acceptance is required before marking22 fully checked. A device snapshot ofba296bce is available under LATEST-VERSION/Development-Snapshots, explicitly pending full acceptance. Both prior failed-run reports and IPA copies are preserved locally.


## Build23: durable downloaded artwork and explicit offline mode (30 October 2026)

Both native targets compiled in the first23 candidate; final acceptance is pending. Keeps build22 player handoff, simple system volume and offline-badge spacing changes. A full-sized provider artwork request is followed by supported large/original fallbacks; valid original image bytes are stored as UUID.artwork beside the audio, without lossy re-encoding. Bounds are20MiB encoded/16MP decoded. Existing completed downloads with missing asset state backfill automatically; unavailable/failed assets can be queued independently through Download Missing Artwork & Lyrics. Source availability limits quality/timing; no upscaling or fabricated lyric timing. Saved lyric JSON/LRC and cover files survive temporary-cache clearing and are removed with their unique audio. Artwork lookup rebuilds from downloads.json and relative filenames at startup, so queued/history/library tracks with old remote metadata resolve to saved covers after relaunch. Rendering, lock-screen artwork and accent extraction share this lookup. Native queue hosting cells/previews explicitly receive the download environment.

Offline Mode persists in preferences, is available in Settings and Downloads options, and also activates on NWPathMonitor connectivity loss. One locked gate blocks/cancels native provider, artwork and scrobble requests; local library, lyric parsing and equalizer operations remain allowed. Background audio transfers suspend/resume; pending asset jobs resume on reconnect/foreground with cellular policy retained. A streaming item without local audio stops; downloaded/imported playback stays local. Next/previous skip unavailable queued tracks without deleting queue entries or their order; autoplay radio does not fetch offline. Home routes to Downloads and offline Search filters saved content. The helper webview stops offline. Existing account/downloads are retained on transient offline restore errors.

The existing native downloaded-lyrics case now also preserves original cover bytes, clears temporary/memory caches, checks offline provider blocking plus local lyric parsing, and cold-launches with the actual production offline toggle enabled. DEBUG evidence requires the real player to decode saved artwork from a local file while network access is blocked. Thirteen asset/timing/policy flags accompany the existing twelve interaction cases. No appearance screenshots or iOS26 tests are requested. Physical radio changes, hardware volume, per-song provider source availability and long suspended-background completion remain phone checks.

Build22 follow-up0b08954a/run40572965780 also had11 passing cases and the combined Downloads-search predicate timed out during sequential accessibility snapshots; the job later reached the600s test-process timeout. This is not12/12 acceptance and no new final IPA was promoted. Build23 separates the query-value, No Results visibility, absent visible old result and restored result assertions instead of putting several slow snapshot operations under one12s predicate deadline. Its failure messages retain the accessibility tree without exporting appearance images.

Final23 network-policy refinement waits for the first NWPathMonitor result before starting queued downloads/asset backfills, avoiding a startup cellular-policy race. Artwork URLRequests also carry allowsCellularAccess explicitly, independent of the monitor callback. The UI's initial connectivity display remains unchanged while detection starts.

First23 candidatecade611f/run41025128938 compiled both native targets and passed11/12 interaction cases plus all13 artwork/lyric/policy flags. The first downloaded-lyrics presentation did not open after the fixture toggled Offline Mode and changed tabs; no cold-offline cover report was produced, so this candidate is not accepted. The follow-up keeps Library/Search selected when connectivity changes (only Home redirects to Downloads) and retries pending player presentation after its UIKit anchor attaches to a window. Sourcef43d6c80/run41030083230 also includes the final cellular-startup guards; exact-source compilation and all acceptance checks are required before delivery. No appearance screenshots are requested.

Sourcef43d6c80/run41030083230 compiled both targets and again passed all13 disk/policy flags, but the downloaded-player opening check still failed. The slower runner also failed the8s queue-order wait and reached the600s test-process deadline before the suite finished; full acceptance is still absent. A focused existing offline-assets case with separate count-only setup/presenter traces is available to isolate the failure without rerunning unrelated cases. Full-suite process allowance is now900s; the queue-order criterion is unchanged, with15s for native accessibility snapshots. Paused remote queue restoration was also found to raise an Offline alert despite no playback attempt; the upcoming source avoids that alert and makes the custom presenter wait/retry through ancestor alert/sheet transitions, including rejected UIKit presentations.

## Final build-23 acceptance and delivery

Source6ea741e29933ba8e3c2881b60bb67bc6e0aef8d2; successful run https://github.com/icesaviour02-droid/sonora/actions/runs/41052925941. Both native targets compiled. All12 targeted interaction cases passed on iPhone13/iOS27.0(24A434), with zero runtime warnings. All13 durable artwork/lyric/timing/offline-policy flags passed. The actual player decoded the saved64x64 generated cover from a local file after a cold launch with the production Offline Mode preference enabled; tapping a saved timed lyric moved the real local audio clock. Setup evidence confirms retained audio/index entry, completed restoration and uncanceled player presentation. Presenter evidence confirms native presentation completed. Earlier failures remain recorded; this result supersedes pending acceptance for the included build22/23 changes. A DEBUG diagnostic helper initially failed actor isolation inb7c258c5/run41033997198;6ea741e2 explicitly isolates it to MainActor. The diagnostic-only961a7cce run was superseded/canceled by the full run.

Delivered ios/build/LATEST-VERSION/Sonora-0.3.0-build23-6ea741e2.ipa;8,738,116 bytes;SHA2564e418899093c7de9158d4974c08bb84f875b147f5f2cfc08f80e1ea0aadba319. ZIP integrity, version, arm64 iPhoneOS Mach-O and absence of test bundles passed. Unsigned for iLoader. BUILD-INFO.json, README.txt, VALIDATION.md and CHECKS/ios27-build23-*.json describe this exact candidate. Previous IPAs and build21 delivery notes are preserved; build22 remains separately labeled as an earlier development snapshot.

Includes durable original artwork, available timed lyric sidecars, existing-download backfill and manual repair, explicit/automatic Offline Mode, local cover lookup across relaunch, local playback/queue filtering, paused-offline alert correction and presentation retry through native alerts/sheets. Previous late post-release artwork-to-pill handoff, plain system volume slider, independent centered offline-badge spacing, live queue/history previews, native seeking and collection/player interactions all passed their targeted checks. No appearance screenshots were exported/reviewed and no iOS26 tests ran. Actual cellular/airplane-mode transitions, hardware volume, source-specific image/lyric availability, long background suspension and exact appearance still require phone review. Live authenticated streaming, Safari sign-in, additional remote providers, AirPlay and full desktop parity remain unaccepted or incomplete.

## Build 24: shared player/cover settling and measured offline badge

Accepted in the final build-24 run below. The cover remains inside the rounded player during the finger drag. On a committed release it starts at its actual visible frame immediately, rather than waiting for60% of panel travel. A monotone cubic path initially follows the downward panel motion, bends into the real mini-player bounds, and resizes/rounds with a zero-slope size curve. The native percent-driven transition's remaining duration is normalized to a0.48–0.64s settle, so a long pull cannot squeeze the entire cover trip into a few frames. Opening reverses the full path. Cancellation retains the in-player artwork. Display-link telemetry records actual presentation-layer panel position, cover bounds and timestamps only for the existing DEBUG fullscreen review; no media or appearance screenshots are exported. Existing interaction acceptance now requires two completed closing motions with release/target bounds matching, at least six samples and at least0.3s of observed settling, as well as restored real-image alpha.

Available offline is a separate overlay positioned at the actual midpoint between SwiftUI anchors for the visible time-label row and central play/pause button; the old fixed offset is removed. The same geometry applies in artwork, lyrics and queue modes. The existing native fullscreen case checks the rendered badge's horizontal centering and separation above the transport button. These checks do not certify pixel-identical Apple Music motion or physical-phone perception.

Public UIKit completionSpeed/duration documentation informed the speed normalization: https://developer.apple.com/documentation/uikit/uipercentdriveninteractivetransition/completionspeed and https://developer.apple.com/documentation/uikit/uipercentdriveninteractivetransition/duration. No private Apple Music code is used.

## Final build-24 acceptance and delivery

Source 305dd0c5d7b793dc0f58ee533bf5ee55e4942ef1; successful run https://github.com/icesaviour02-droid/sonora/actions/runs/41062387380. Both native targets compiled. All 12 targeted cases passed on iPhone 13/iOS 27.0 (24A434), with no runtime warnings. Both completed pull gestures recorded 42 display-link samples: 0.649s and 0.648s after release, with a planned 0.64s settle. Their initial positions/widths match the released cover, and final bounds match the mini-player within one point. Canceled pulls, reopening and restored real-image alpha passed. The rendered offline badge was horizontally centered and above the play/pause control; the code resolves its vertical midpoint from actual time-label and transport-button anchors. All prior queue/history/collection/seeking/lyrics interactions and all 13 permanent offline asset flags passed again, including real cover decoding after a cold offline launch. No appearance screenshots were exported/reviewed and no iOS 26 tests ran.

Delivered ios/build/LATEST-VERSION/Sonora-0.3.0-build24-305dd0c5.ipa; 8,748,843 bytes; SHA256 ff623238aa4e697756af77568fdd1beab2ced92a91fd4587a08d8a7286d7cf0c. ZIP integrity, version, arm64 iPhoneOS Mach-O, absence of test bundles and final copied-file hash passed. Unsigned for iLoader. BUILD-INFO.json, README.txt, VALIDATION.md and CHECKS/ios27-build24-*.json describe the exact accepted archive. Previous IPA files remain untouched; build 23 notes are preserved in Previous-Versions. Exact Apple Music motion/appearance, perceived hardware smoothness and other existing phone/provider/account parity limits still require review.

## Build 25 on the transferred fork

The iPhone build now runs on mohammed160209/sonora with Xcode 27.2. The run at https://github.com/mohammed160209/sonora/actions/runs/42389943451 passed all 12 interaction and 13 offline asset checks on iOS 27.2 (24B8117). All 56 Linux core tests passed. A live Linux check returned 287 distinct, playable catalog entries for an artist with five top songs. Catalog coverage depends on what YouTube Music supplies and which releases can be read within the request deadline.

The IPA is ios/build/LATEST-VERSION/Sonora-0.3.0-build25-648fc888.ipa. SHA-256 is 15650c87194ebfd18ab3b1e34fbc79f6996eeb6de4e12c2c7979cf2fa0594e1d. It is unsigned for iLoader. A physical device check is still needed to confirm whether refreshing the signing profile resolves the reported launch message.
