#!/usr/bin/env python3
"""Launch the built app on an iPhone 13 simulator and capture review evidence, not mockups."""

import json
import math
import os
from pathlib import Path
import subprocess
import struct
import time
import urllib.parse
import wave
import zlib

IOS = Path(__file__).resolve().parents[1]
OUTPUT = IOS / "build/review"
BUNDLE = "org.sonorahq.iphone.development"


def run(*args):
    print("Running: " + " ".join(args), flush=True)
    # Initial simulator migration can be slow on a fresh hosted Mac. Bound it so failures
    # produce artifacts and diagnostics instead of consuming the entire job allowance.
    limit = 600 if "bootstatus" in args else 300 if "install" in args else 240 if "launch" in args and "--terminate-running-process" not in args else 120
    return subprocess.check_output(args, text=True, timeout=limit).strip()


def sim(*args):
    return run("xcrun", "simctl", *args)


def verify_playback(container, video_id, downloaded):
    """Require the native player clock to advance, rather than inferring audio from a screenshot."""
    state_file = container / "Library/Application Support/playback-review.json"
    deadline = time.monotonic() + 130
    state = None
    while time.monotonic() < deadline:
        if state_file.exists():
            state = json.loads(state_file.read_text())
            if state.get("hasError"):
                (OUTPUT / ("downloaded-playback-failed.json" if downloaded else "stream-playback-failed.json")).write_text(json.dumps(state, indent=2))
                return False
            if (state.get("trackID") == "youtube:" + video_id and state.get("isPlaying")
                    and state.get("elapsed", 0) > 1 and state.get("isDownloaded") == downloaded):
                (OUTPUT / ("downloaded-playback.json" if downloaded else "stream-playback.json")).write_text(json.dumps(state, indent=2))
                return True
        time.sleep(1)
    (OUTPUT / ("downloaded-playback-failed.json" if downloaded else "stream-playback-failed.json")).write_text(json.dumps(state, indent=2))
    return False


def evidence(container, filename, timeout=45):
    """Read count-only app evidence from actual decoded provider results, never raw music/lyrics."""
    path = container / "Library/Application Support" / filename
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            value = json.loads(path.read_text())
            (OUTPUT / filename).write_text(json.dumps(value, indent=2))
            return value
        time.sleep(1)
    return None


def generate_review_media(container):
    """Create original audio and artwork for repeatable local playback and interface checks."""
    # This synthetic file checks native import and audio independently from provider authorization.
    tone = container / "Library/Caches/sonora-review-tone.wav"
    tone.parent.mkdir(parents=True, exist_ok=True)
    rate = 22_050
    with wave.open(str(tone), "wb") as output:
        output.setparams((1, 2, rate, 0, "NONE", "not compressed"))
        output.writeframes(b"".join(struct.pack("<h", int(2_000 * math.sin(2 * math.pi * 220 * i / rate))) for i in range(rate * 16)))
    # A self-generated gradient cover exercises actual artwork metadata, never third-party media.
    def png_chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    rows = b"".join(b"\x00" + bytes(channel for x in range(64) for channel in (x * 4, y * 4, 128)) for y in range(64))
    cover = b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", struct.pack(">IIBBBBB", 64, 64, 8, 2, 0, 0, 0)) + png_chunk(b"IDAT", zlib.compress(rows)) + png_chunk(b"IEND", b"")
    (tone.parent / "sonora-review-cover.png").write_bytes(cover)


def export_crash_summaries(bundle):
    """Export text crash evidence only; never export screenshots for appearance review."""
    destination = OUTPUT / "CrashDiagnostics"
    try:
        result = subprocess.run(["xcrun", "xcresulttool", "export", "diagnostics", "--path", str(bundle),
            "--output-path", str(destination)], capture_output=True, text=True, timeout=45)
        reports = []
        if result.returncode == 0:
            import zipfile
            entries = []
            for path in destination.rglob("*"):
                if path.suffix == ".ips": entries.append((path.name, path.read_bytes()))
                elif path.suffix == ".zip":
                    try:
                        with zipfile.ZipFile(path) as archive:
                            entries.extend((name, archive.read(name)) for name in archive.namelist()
                                if name.endswith(".ips") and archive.getinfo(name).file_size < 2_000_000)
                    except (OSError, zipfile.BadZipFile): pass
            for name, data in entries:
                try:
                    text = data.decode("utf-8")
                    try: value = json.loads(text)
                    except ValueError: value = json.loads(text.split("\n", 1)[1])
                    if "Sonora" not in value.get("procName", name): continue
                    index = value.get("faultingThread", 0)
                    threads = value.get("threads", [])
                    frames = threads[index].get("frames", [])[:30] if isinstance(index, int) and index < len(threads) else []
                    reports.append({"file": name, "process": value.get("procName"), "exception": value.get("exception"),
                        "termination": value.get("termination"), "lastExceptionBacktrace": value.get("lastExceptionBacktrace", [])[:30],
                        "faultingFrames": frames, "images": [{"name": image.get("name"), "base": image.get("base")}
                            for image in value.get("usedImages", [])]})
                except (ValueError, IndexError, UnicodeError): pass
        (OUTPUT / "crash-summary.json").write_text(json.dumps({"exported": result.returncode == 0, "reports": reports}, indent=2))
    except (OSError, subprocess.SubprocessError) as error:
        (OUTPUT / "crash-summary.json").write_text(json.dumps({"exported": False, "error": type(error).__name__}))


def run_interactions(udid, export_images=True):
    """Run real touch tests on the same populated simulator; failure preserves the result bundle."""
    test_run = next((IOS / "build/simulator/Build/Products").glob("*.xctestrun"))
    bundle = OUTPUT / "MusicInteractions.xcresult"
    failed = True
    selection = ["-only-testing:SonoraUITests/MusicInteractionTests/testDownloadedTimedLyricsSurviveCacheClearAndRelaunch"] if os.environ.get("SONORA_REVIEW_SCOPE") == "offline_assets" else []
    try:
        subprocess.run(["xcodebuild", "test-without-building", "-xctestrun", str(test_run),
            "-destination", "id=" + udid, "-parallel-testing-enabled", "NO",
            "-resultBundlePath", str(bundle)] + selection, check=True, timeout=900)
        failed = False
    finally:
        if failed: export_crash_summaries(bundle)
        current = Path(sim("get_app_container", udid, BUNDLE, "data"))
        for filename in ["queue-drag-review.json", "player-presentation-review.json", "queue-context-preview-review.json", "download-lyrics-review.json", "player-cover-handoff-review.json", "player-cover-motion-review.json", "offline-artwork-restore-review.json", "download-player-setup-review.json", "download-player-presentation-review.json", "download-integrity-review.json", "history-replay-review.json"]:
            evidence = current / "Library/Application Support" / filename
            if evidence.exists():
                (OUTPUT / filename).write_bytes(evidence.read_bytes())
        try:
            summary = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)],
                capture_output=True, text=True, timeout=30)
            if summary.returncode == 0:
                value = json.loads(summary.stdout)
                (OUTPUT / "touch-review-summary.json").write_text(json.dumps(value, indent=2))
            help_text = subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--help"],
                capture_output=True, text=True, timeout=15)
            if export_images and "--only-failures" in help_text.stdout + help_text.stderr:
                destination = OUTPUT / "TouchAttachments"
                exported = subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle),
                    "--output-path", str(destination), "--only-failures"], capture_output=True, text=True, timeout=30)
                if exported.returncode == 0:
                    for index, screenshot in enumerate(sorted(destination.rglob("*.png"))[:6]):
                        (OUTPUT / f"touch-failure-{index}.png").write_bytes(screenshot.read_bytes())
        except (subprocess.SubprocessError, ValueError):
            print("Detailed touch-test result remains in the xcresult bundle", flush=True)


def review_changed_screens(udid, container):
    """Validate the playback/UI patch without claiming full provider acceptance."""
    generate_review_media(container)
    routes = [
        ("localreview", "local-playback-review.json", None),
        ("downloadsreview", "downloads-layout-review.json", "iphone13-downloads-populated.png"),
        ("localplaylistreview", "local-library-review.json", "iphone13-local-playlist.png"),
        ("localplaylistrestore", "local-library-relaunch-review.json", "iphone13-local-playlist-restored.png"),
    ]
    for route, filename, screenshot in routes:
        (container / "Library/Application Support" / filename).unlink(missing_ok=True)
        sim("launch", "--terminate-running-process", udid, BUNDLE, "--sonora-review-url", "sonora://" + route)
        result = evidence(container, filename, timeout=90)
        if not result or not result.get("passed"):
            raise RuntimeError("Changed-screen regression failed: " + filename)
        if screenshot:
            time.sleep(2)
            sim("io", udid, "screenshot", str(OUTPUT / screenshot))
    run_interactions(udid)
    fixture = json.loads((IOS / "scripts/review-track.json").read_text())
    metadata = {"id": fixture["id"], "title": fixture["title"], "artist": fixture["artist"], "artwork": fixture["artwork_url"]}
    sim("launch", "--terminate-running-process", udid, BUNDLE, "--sonora-review-url", "sonora://queuereview?" + urllib.parse.urlencode(metadata))
    queue = evidence(container, "queue-review.json")
    if not queue or not queue.get("passed"):
        raise RuntimeError("Queue storage checks failed")
    time.sleep(2)
    sim("io", udid, "screenshot", str(OUTPUT / "iphone13-queue-duplicates.png"))
    sim("launch", "--terminate-running-process", udid, BUNDLE)
    time.sleep(2)
    sim("io", udid, "screenshot", str(OUTPUT / "iphone13-library-populated.png"))
    sim("ui", udid, "content_size", "accessibility-extra-extra-extra-large")
    time.sleep(2)
    sim("io", udid, "screenshot", str(OUTPUT / "iphone13-library-large-text.png"))
    (OUTPUT / "review-scope.json").write_text(json.dumps({
        "scope": "changed_ui", "passed": True,
        "checks": ["native_playback_end", "download_migration", "local_playlist_restore", "queue_storage", "touch_interactions"],
        "full_provider_acceptance": False,
        "guest_streaming": "not repeated; previous full run failed Google verification"
    }, indent=2))


def review_interactions_only(udid, container):
    """Rerun native touch regressions without screenshots or repeated provider acceptance."""
    generate_review_media(container)
    run_interactions(udid, export_images=False)
    previews = json.loads((OUTPUT / "queue-context-preview-review.json").read_text())
    assert {item["kind"] for item in previews} >= {"queue", "history"}, "Missing selected-row native preview evidence"
    assert all(item["opaqueBackground"] for item in previews), "A lifted row still has a transparent background"
    replay = json.loads((OUTPUT / "history-replay-review.json").read_text())
    assert replay["current"] == replay["selected"]
    remainder = replay["remainder"]
    assert remainder and replay["upcoming"][-len(remainder):] == remainder
    original = replay["originalHistory"]
    split = original.index(replay["selected"])
    assert original[split + 1:] and replay["upcoming"][:-len(remainder)] == original[split + 1:], "History did not replay forward into the existing queue"
    assert split > 0 and replay["history"] == original[:split][::-1], "History did not retain exactly the older entries"
    assert json.loads((OUTPUT / "download-integrity-review.json").read_text())["passed"], "Audio integrity validation failed"
    assert json.loads((OUTPUT / "download-lyrics-review.json").read_text())["passed"], "Downloaded timed lyrics did not persist"
    assert json.loads((OUTPUT / "offline-artwork-restore-review.json").read_text())["passed"], "Offline relaunch did not decode saved artwork"
    handoffs = json.loads((OUTPUT / "player-cover-handoff-review.json").read_text())
    closing = [event for event in handoffs if event["event"] == "handoff" and not event["opening"]]
    assert closing and all(event["afterRelease"] and event["sharedPanelProgress"] and event["settleDuration"] >= 0.60 for event in closing), "Cover did not share the committed panel settling motion"
    motions = json.loads((OUTPUT / "player-cover-motion-review.json").read_text())
    settled = [event for event in motions if not event["opening"] and event["completed"]]
    assert len(settled) >= 2, "Missing artwork/empty-space dismissal motion evidence"
    for event in settled:
        frames = event["samples"]
        assert len(frames) >= 6 and frames[-1]["t"] >= 0.3, "Cover settling was rushed into too few frames"
        for field, original, target in [("x", "startX", "targetX"), ("y", "startY", "targetY"), ("width", "startWidth", "targetWidth")]:
            assert abs(frames[0][field] - event[original]) <= 1, "Cover jumped at release"
            assert abs(frames[-1][field] - event[target]) <= 1, "Cover missed the mini-player target"
    restored = [event for event in handoffs if event["event"] == "restored"]
    assert restored and all(event["sourceAlpha"] == 1 and event["miniAlpha"] == 1 for event in restored), "Cover was not restored after transition"
    (OUTPUT / "review-scope.json").write_text(json.dumps({
        "scope": "interactions", "passed": True,
        "checks": ["download_categories_and_search_navigation", "playlist_rename", "queue_editing", "player_and_lyrics_source_menu", "queue_history_clipping", "artwork_track_swiping", "inline_library_editing", "tap_drag_native_audio_seeking", "fullscreen_drag_cancel_dismiss", "queue_history_context_menus", "collection_cover_navigation_and_toolbars", "downloaded_timed_lyrics_offline_relaunch"],
        "full_provider_acceptance": False,
        "provider_checks": "not repeated; inspect the latest functional report"
    }, indent=2))


def review_functionality(udid, container):
    """Exercise real state/playback and touch behavior without generating appearance screenshots."""
    generate_review_media(container)
    checks = {}
    report = {"scope": "functional", "device": "iPhone 13 / iOS 27 simulator", "checks": checks,
              "full_feature_parity": False, "private_account_and_physical_phone": "not available on this host"}

    def record(name, passed):
        checks[name] = bool(passed)
        report["passed"] = all(checks.values())
        (OUTPUT / "functional-results.json").write_text(json.dumps(report, indent=2))

    fixture = json.loads((IOS / "scripts/review-track.json").read_text())
    metadata = {"id": fixture["id"], "title": fixture["title"], "artist": fixture["artist"], "artwork": fixture["artwork_url"]}
    routes = [
        ("sessionreview", "account-storage-review.json"),
        ("requestreview", "native-requests-review.json"),
        ("soundobservationreview", "sound-observation-review.json"),
        ("soundprofilesreview", "sound-profiles-review.json"),
        ("lyricsstorereview", "lyrics-store-review.json"),
        ("scrobblereview", "scrobble-review.json"),
        ("localreview", "local-playback-review.json"),
        ("downloadsreview", "downloads-layout-review.json"),
        ("localplaylistreview", "local-library-review.json"),
        ("localplaylistrestore", "local-library-relaunch-review.json"),
        ("queuereview?" + urllib.parse.urlencode(metadata), "queue-review.json"),
    ]
    for route, filename in routes:
        (container / "Library/Application Support" / filename).unlink(missing_ok=True)
        sim("launch", "--terminate-running-process", udid, BUNDLE, "--sonora-review-url", "sonora://" + route)
        result = evidence(container, filename, timeout=90)
        record(filename, result and result.get("passed"))
    try:
        run_interactions(udid, export_images=False)
        record("touch_interactions", True)
    except (subprocess.SubprocessError, RuntimeError):
        record("touch_interactions", False)

    # XCTest may replace the AUT data container while installing its application-under-test.
    container = Path(sim("get_app_container", udid, BUNDLE, "data"))

    for route, filename, count in [("home", "home-review.json", "items"),
                                   ("search?q=Beethoven", "search-review.json", "songs")]:
        (container / "Library/Application Support" / filename).unlink(missing_ok=True)
        sim("launch", "--terminate-running-process", udid, BUNDLE, "--sonora-review-url", "sonora://" + route)
        result = evidence(container, filename, timeout=90)
        record(filename, result and result.get(count, 0) > 0)

    probe_file = container / "Library/Application Support/guest-probe.json"
    probe_file.unlink(missing_ok=True)
    sim("launch", "--terminate-running-process", udid, BUNDLE, "--sonora-review-url", "sonora://guestprobe")
    deadline = time.monotonic() + 390
    probe = None
    while time.monotonic() < deadline:
        if probe_file.exists():
            probe = json.loads(probe_file.read_text())
            if probe.get("status") in ("selected", "failed"):
                break
        time.sleep(1)
    (OUTPUT / "guest-probe.json").write_text(json.dumps(probe, indent=2))
    resolved = probe and probe.get("status") == "selected"
    record("guest_audio_resolution", resolved)
    if resolved:
        video_id = probe["selected_id"]
        streamed = verify_playback(container, video_id, downloaded=False)
        record("native_stream_decoding", streamed)
        if streamed:
            state = json.loads((OUTPUT / "stream-playback.json").read_text())
            record("provider_duration_preserved", probe.get("source_duration", 0) > 0 and state.get("duration", 0) > 0
                   and abs(state.get("duration", 0) - probe["source_duration"]) < 1)
            record("stream_pcm_processed", state.get("processedAudioFrames", 0) > 0)
        route = "sonora://play?" + urllib.parse.urlencode({"id": video_id, "title": video_id})
        controls_file = container / "Library/Application Support/live-controls-review.json"
        controls_file.unlink(missing_ok=True)
        sim("launch", "--terminate-running-process", udid, BUNDLE, "--sonora-review-live-controls", "--sonora-review-url", route)
        controls = evidence(container, "live-controls-review.json", timeout=160)
        record("stream_pause_seek_and_end", controls and controls.get("passed"))
        if controls: (OUTPUT / "stream-controls-review.json").write_text(json.dumps(controls, indent=2))
        sim("launch", "--terminate-running-process", udid, BUNDLE, "--sonora-review-url",
            "sonora://download?" + urllib.parse.urlencode({"id": video_id, "title": video_id}))
        index = container / "Library/Application Support/Downloads/downloads.json"
        deadline = time.monotonic() + 180
        complete = None
        while time.monotonic() < deadline:
            if index.exists():
                entry = next((e for e in json.loads(index.read_text()) if e["track"].get("youtubeID") == video_id), None)
                if entry and entry["state"] == "downloaded":
                    complete = entry
                    break
                if entry and entry["state"] == "failed":
                    report["download_failure_code"] = entry.get("failureCode")
                    break
            time.sleep(2)
        record("complete_native_download", complete is not None)
        if complete:
            path = index.parent / complete["filename"]
            record("download_byte_count", path.exists() and path.stat().st_size == complete.get("expectedBytes", -1))
            record("download_source_duration", probe.get("source_duration", 0) > 0 and complete.get("sourceDuration", 0) > 0
                   and abs(complete["sourceDuration"] - probe["source_duration"]) < 1)
            controls_file.unlink(missing_ok=True)
            sim("launch", "--terminate-running-process", udid, BUNDLE, "--sonora-review-live-controls",
                "--sonora-review-block-resolution", "--sonora-review-url", route)
            downloaded = evidence(container, "live-controls-review.json", timeout=160)
            record("download_relaunch_without_resolution", downloaded and downloaded.get("passed") and downloaded.get("downloaded"))
            if downloaded: (OUTPUT / "downloaded-controls-review.json").write_text(json.dumps(downloaded, indent=2))
    else:
        report["live_stream_and_download"] = "not accepted: provider did not resolve a real Guest stream"
        record("guest_audio_resolution", False)
    if not all(checks.values()):
        raise RuntimeError("Functional verification has unresolved failures; inspect functional-results.json")


if __name__ == "__main__":
    OUTPUT.mkdir(parents=True, exist_ok=True)
    runtimes = json.loads(sim("list", "runtimes", "--json"))["runtimes"]
    target_version = os.environ.get("SONORA_REVIEW_IOS_VERSION", "27.2")
    available = [r for r in runtimes if r.get("isAvailable")
                 and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
                 and (r["version"] == target_version or r["version"].startswith(target_version + "."))]
    device_type = "com.apple.CoreSimulator.SimDeviceType.iPhone-13"
    available = [r for r in available if not r.get("supportedDeviceTypes") or any(
        device.get("identifier") == device_type for device in r["supportedDeviceTypes"])]
    if not available:
        raise RuntimeError(f"No available iPhone 13 simulator runtime for iOS {target_version} on this runner")
    runtime = sorted(available, key=lambda r: tuple(map(int, r["version"].split("."))))[-1]
    (OUTPUT / "selected-runtime.json").write_text(json.dumps(runtime, indent=2))
    udid = sim("create", "Sonora iPhone 13 Review", device_type, runtime["identifier"])
    try:
        sim("boot", udid)
        sim("bootstatus", udid, "-b")
        sim("install", udid, str(IOS / "build/simulator/Build/Products/Debug-iphonesimulator/Sonora.app"))
        try:
            launch = sim("launch", udid, BUNDLE)
        except (subprocess.TimeoutExpired, subprocess.CalledProcessError) as failure:
            state = {"step": "initial_launch", "timeout_seconds": 240,
                     "failure_type": type(failure).__name__}
            try:
                processes = subprocess.run(["xcrun", "simctl", "spawn", udid, "launchctl", "list"],
                    capture_output=True, text=True, timeout=15)
                state["simulator_responding"] = processes.returncode == 0
                state["app_process_present"] = BUNDLE in processes.stdout
            except subprocess.SubprocessError:
                state["simulator_responding"] = False
            reports = Path.home() / "Library/Logs/DiagnosticReports"
            for diagnostic in sorted(reports.glob("Sonora*.ips"), key=lambda path: path.stat().st_mtime, reverse=True)[:2]:
                try:
                    body = diagnostic.read_text()
                    lines = body.splitlines()
                    detail = json.loads("\n".join(lines[1:]))
                    state["termination"] = detail.get("termination")
                    state["exception"] = detail.get("exception")
                    break
                except (OSError, ValueError):
                    pass
            (OUTPUT / "simulator-launch-failure.json").write_text(json.dumps(state, indent=2))
            raise
        time.sleep(3)
        # Fail if launch succeeded momentarily but the app immediately crashed.
        processes = sim("spawn", udid, "launchctl", "list")
        if BUNDLE not in processes:
            raise RuntimeError("Sonora did not remain running after launch")
        container = Path(sim("get_app_container", udid, BUNDLE, "data"))
        if os.environ.get("SONORA_REVIEW_SCOPE") == "offline_assets":
            generate_review_media(container)
            run_interactions(udid, export_images=False)
            assert json.loads((OUTPUT / "download-lyrics-review.json").read_text())["passed"]
            assert json.loads((OUTPUT / "offline-artwork-restore-review.json").read_text())["passed"]
            (OUTPUT / "review-scope.json").write_text(json.dumps({"scope": "offline_assets", "passed": True,
                "checks": ["downloaded_assets_and_offline_relaunch"], "full_provider_acceptance": False}, indent=2))
            raise SystemExit(0)
        if os.environ.get("SONORA_REVIEW_SCOPE") == "interactions":
            review_interactions_only(udid, container)
            raise SystemExit(0)
        if os.environ.get("SONORA_REVIEW_SCOPE") == "functional":
            review_functionality(udid, container)
            raise SystemExit(0)
        if os.environ.get("SONORA_REVIEW_SCOPE") == "changed_ui":
            review_changed_screens(udid, container)
            raise SystemExit(0)
        for appearance in ("light", "dark"):
            sim("ui", udid, "appearance", appearance)
            time.sleep(1)
            sim("io", udid, "screenshot", str(OUTPUT / f"iphone13-library-{appearance}.png"))
        sim("ui", udid, "content_size", "accessibility-extra-extra-extra-large")
        time.sleep(1)
        sim("io", udid, "screenshot", str(OUTPUT / "iphone13-library-large-text.png"))
        sim("ui", udid, "content_size", "large")
        sim("ui", udid, "appearance", "light")
        container = Path(sim("get_app_container", udid, BUNDLE, "data"))
        for typeface in ("rounded", "Inter-Regular"):
            review_file = container / "Library/Application Support/font-review.json"
            review_file.unlink(missing_ok=True)
            sim("launch", "--terminate-running-process", udid, BUNDLE, "--sonora-review-url", "sonora://fonts?font=" + typeface)
            review = evidence(container, "font-review.json")
            (OUTPUT / ("font-" + typeface + ".json")).write_text(json.dumps(review, indent=2))
            if not review or review.get("selected") != typeface or review.get("persisted") != typeface or not review.get("selected_available") or not review.get("rounded_available"):
                raise RuntimeError("The chosen font is not available or persisted")
            sim("io", udid, "screenshot", str(OUTPUT / ("iphone13-font-" + typeface + ".png")))
        review_file.unlink(missing_ok=True)
        sim("launch", "--terminate-running-process", udid, BUNDLE, "--sonora-review-url", "sonora://fonts")
        restored_font = evidence(container, "font-review.json")
        if not restored_font or restored_font.get("selected") != "Inter-Regular":
            raise RuntimeError("The font choice did not survive relaunch")
        review_file.unlink(missing_ok=True)
        sim("launch", "--terminate-running-process", udid, BUNDLE, "--sonora-review-url", "sonora://fonts?font=system")
        reset_font = evidence(container, "font-review.json")
        if not reset_font or reset_font.get("selected") != "system":
            raise RuntimeError("The system font could not be restored")
        sim("launch", "--terminate-running-process", udid, BUNDLE, "--sonora-review-url", "sonora://home")
        home_evidence = evidence(container, "home-review.json")
        sim("io", udid, "screenshot", str(OUTPUT / "iphone13-home.png"))
        sim("launch", "--terminate-running-process", udid, BUNDLE, "--sonora-review-url", "sonora://search?q=Beethoven")
        search_evidence = evidence(container, "search-review.json")
        sim("io", udid, "screenshot", str(OUTPUT / "iphone13-youtube-search.png"))
        sim("launch", "--terminate-running-process", udid, BUNDLE, "--sonora-review-url", "sonora://lyricsstorereview")
        lyrics_store = evidence(container, "lyrics-store-review.json", timeout=90)
        if not lyrics_store or not lyrics_store.get("passed"):
            raise RuntimeError("Lyrics import/timing/source/cache/restoration checks failed")
        sim("launch", "--terminate-running-process", udid, BUNDLE, "--sonora-review-url", "sonora://scrobblereview")
        scrobbling = evidence(container, "scrobble-review.json", timeout=90)
        if not scrobbling or not scrobbling.get("passed"):
            raise RuntimeError("Listening thresholds, durable scrobble retry or account isolation failed")
        sim("launch", "--terminate-running-process", udid, BUNDLE, "--sonora-review-url", "sonora://requestreview")
        requests = evidence(container, "native-requests-review.json")
        if not requests or not requests.get("passed"):
            raise RuntimeError("Swift/native cancellation or callback completion failed")
        sim("launch", "--terminate-running-process", udid, BUNDLE, "--sonora-review-url", "sonora://soundobservationreview")
        sound_observation = evidence(container, "sound-observation-review.json")
        if not sound_observation or not sound_observation.get("passed"):
            raise RuntimeError("Live sound settings/menu observation or latest-configuration handling failed")
        fixture = json.loads((IOS / "scripts/review-track.json").read_text())
        sim("launch", "--terminate-running-process", udid, BUNDLE, "--sonora-review-url", "sonora://soundprofilesreview")
        sound_profiles = evidence(container, "sound-profiles-review.json", timeout=90)
        if not sound_profiles or not sound_profiles.get("passed"):
            raise RuntimeError("Sound profile create/edit/import/export/restore/delete checks failed")
        sim("io", udid, "screenshot", str(OUTPUT / "iphone13-sound-profiles.png"))
        sim("launch", "--terminate-running-process", udid, BUNDLE, "--sonora-review-url", "sonora://soundprofileeditor")
        time.sleep(2)
        sim("io", udid, "screenshot", str(OUTPUT / "iphone13-sound-profile-editor.png"))
        metadata = {"id": fixture["id"], "title": fixture["title"], "artist": fixture["artist"], "artwork": fixture["artwork_url"]}
        sim("launch", "--terminate-running-process", udid, BUNDLE, "--sonora-review-url", "sonora://queuereview?" + urllib.parse.urlencode(metadata))
        queue_review = evidence(container, "queue-review.json")
        if not queue_review or not queue_review.get("passed"):
            raise RuntimeError("Queue occurrence, reorder or restoration checks failed")
        time.sleep(2)
        sim("io", udid, "screenshot", str(OUTPUT / "iphone13-queue-duplicates.png"))
        for mode in ("artwork", "lyrics", "queue"):
            route = "sonora://review?" + urllib.parse.urlencode(dict(metadata, mode=mode))
            sim("launch", "--terminate-running-process", udid, BUNDLE, "--sonora-review-url", route)
            if mode == "lyrics":
                lyrics_evidence = evidence(container, "lyrics-review.json")
            time.sleep(4)
            sim("io", udid, "screenshot", str(OUTPUT / ("iphone13-player-" + mode + ".png")))
            if mode == "artwork":
                sim("ui", udid, "content_size", "accessibility-extra-extra-extra-large")
                time.sleep(1)
                sim("io", udid, "screenshot", str(OUTPUT / "iphone13-player-large-text.png"))
                sim("ui", udid, "content_size", "large")
        if not home_evidence or home_evidence.get("items", 0) == 0:
            raise RuntimeError("Home did not return decoded content; inspect the captured screen")
        if not search_evidence or search_evidence.get("songs", 0) == 0:
            raise RuntimeError("Catalog Search did not return decoded songs; inspect the captured screen")
        if not lyrics_evidence or lyrics_evidence.get("line_count", 0) == 0:
            raise RuntimeError("Lyrics did not return decoded lines; inspect the captured screen")
        generate_review_media(container)
        sim("launch", "--terminate-running-process", udid, BUNDLE, "--sonora-review-url", "sonora://localreview")
        local_review = evidence(container, "local-playback-review.json", timeout=60)
        if not local_review or not local_review.get("passed"):
            raise RuntimeError("Local import, playback, pause, seek or removal checks failed")
        sim("launch", "--terminate-running-process", udid, BUNDLE, "--sonora-review-url", "sonora://downloadsreview")
        download_layout = evidence(container, "downloads-layout-review.json")
        if not download_layout or not download_layout.get("passed"):
            raise RuntimeError("Download duration, legacy data or playlist restoration failed")
        sim("io", udid, "screenshot", str(OUTPUT / "iphone13-downloads-populated.png"))
        sim("launch", "--terminate-running-process", udid, BUNDLE, "--sonora-review-url", "sonora://localplaylistreview")
        local_library = evidence(container, "local-library-review.json", timeout=90)
        if not local_library or not local_library.get("passed"):
            raise RuntimeError("Native local playlist/favorite queue, ordering or restoration failed")
        time.sleep(2)
        sim("io", udid, "screenshot", str(OUTPUT / "iphone13-local-playlist.png"))
        sim("launch", "--terminate-running-process", udid, BUNDLE, "--sonora-review-url", "sonora://localplaylistrestore")
        local_relaunch = evidence(container, "local-library-relaunch-review.json")
        if not local_relaunch or not local_relaunch.get("passed"):
            raise RuntimeError("Local playlist/media/favorites did not survive actual app relaunch")
        time.sleep(2)
        sim("io", udid, "screenshot", str(OUTPUT / "iphone13-local-playlist-restored.png"))
        run_interactions(udid)
        sim("launch", "--terminate-running-process", udid, BUNDLE, "--sonora-review-url", "sonora://locallyrics?" + urllib.parse.urlencode({"title": fixture["title"], "artist": fixture["artist"]}))
        local_lyrics = evidence(container, "local-lyrics-review.json")
        if not local_lyrics or local_lyrics.get("has_video_id") or local_lyrics.get("line_count", 0) == 0:
            raise RuntimeError("Local-file metadata lyrics did not decode without a provider ID")
        # A fork without repository variables must still verify real audio before publishing.
        video_id = os.environ.get("SONORA_SMOKE_VIDEO_ID") or fixture["id"]
        if video_id:
            probe_file = container / "Library/Application Support/guest-probe.json"
            sim("launch", "--terminate-running-process", udid, BUNDLE, "--sonora-review-url", "sonora://guestprobe")
            deadline = time.monotonic() + 390
            probe = None
            while time.monotonic() < deadline:
                if probe_file.exists():
                    probe = json.loads(probe_file.read_text())
                    if probe.get("status") in ("selected", "failed"): break
                time.sleep(1)
            (OUTPUT / "guest-probe.json").write_text(json.dumps(probe, indent=2))
            if not probe or probe.get("status") != "selected":
                sim("io", udid, "screenshot", str(OUTPUT / "iphone13-guest-probe.png"))
                raise RuntimeError("Guest resolution failed for the search candidates; inspect guest-probe.json")
            video_id = probe["selected_id"]
            streamed = verify_playback(container, video_id, downloaded=False)
            sim("io", udid, "screenshot", str(OUTPUT / "iphone13-stream-player.png"))
            sim("launch", "--terminate-running-process", udid, BUNDLE, "--sonora-review-url", "sonora://download?" + urllib.parse.urlencode({"id": video_id, "title": video_id}))
            index = container / "Library/Application Support/Downloads/downloads.json"
            deadline = time.monotonic() + 180
            complete = None
            while time.monotonic() < deadline:
                if index.exists():
                    entries = json.loads(index.read_text())
                    entry = next((e for e in entries if e["track"].get("youtubeID") == video_id), None)
                    if entry and entry["state"] == "downloaded":
                        complete = entry
                        break
                    if entry and entry["state"] == "failed":
                        (OUTPUT / "download-failure.json").write_text(json.dumps(entry, indent=2))
                        sim("io", udid, "screenshot", str(OUTPUT / "iphone13-download-failed.png"))
                        raise RuntimeError("The live download check failed: " + str(entry.get("failureCode", "unspecified")))
                time.sleep(2)
            sim("io", udid, "screenshot", str(OUTPUT / "iphone13-download.png"))
            if complete is None:
                raise RuntimeError("The download check did not finish within 180 seconds")
            downloaded = index.parent / complete["filename"]
            if not downloaded.exists() or downloaded.stat().st_size == 0:
                raise RuntimeError("A completed download has no audio file")
            sim("launch", "--terminate-running-process", udid, BUNDLE, "--sonora-review-url", "sonora://play?" + urllib.parse.urlencode({"id": video_id, "title": video_id}))
            played_download = verify_playback(container, video_id, downloaded=True)
            sim("io", udid, "screenshot", str(OUTPUT / "iphone13-downloaded-player.png"))
            (OUTPUT / "download-check.json").write_text(json.dumps({
                "state": complete["state"], "bytes": downloaded.stat().st_size,
                "expected_bytes": complete.get("expectedBytes"),
                "limitations": "The file was downloaded and validated by the app. Physical-device airplane mode is not verified."
            }, indent=2))
            if not streamed or not played_download:
                raise RuntimeError("Native playback did not advance; inspect playback diagnostic artifacts")
        (OUTPUT / "device.json").write_text(json.dumps({"device": "iPhone 13 simulator", "runtime": runtime, "launch": launch, "limitations": "Simulator launch, appearance, streaming and download review. Physical-device behavior remains unverified."}, indent=2))
    finally:
        if "container" in locals():
            try:
                container = Path(sim("get_app_container", udid, BUNDLE, "data"))
            except subprocess.SubprocessError:
                pass
            for filename in ("potoken-review.json", "provider-failure.json"):
                path = container / "Library/Application Support" / filename
                if path.exists(): (OUTPUT / filename).write_text(path.read_text())
        try:
            sim("shutdown", udid)
        finally:
            sim("delete", udid)
