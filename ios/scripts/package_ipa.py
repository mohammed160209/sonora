#!/usr/bin/env python3
"""Package a real device build for sideloading, refusing simulator apps and incomplete bundles."""

import json
import hashlib
import os
from datetime import datetime, timezone
from pathlib import Path
import plistlib
import shutil
import subprocess
import zipfile

IOS = Path(__file__).resolve().parents[1]
BUILD = IOS / "build"
APP = BUILD / "device/Build/Products/Release-iphoneos/Sonora.app"


def package():
    with (APP / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if "iPhoneOS" not in info.get("CFBundleSupportedPlatforms", []):
        raise ValueError("This is not an iPhone device build; refusing to package it")
    executable = APP / info["CFBundleExecutable"]
    architecture = subprocess.check_output(["lipo", "-archs", str(executable)], text=True).strip()
    if "arm64" not in architecture.split():
        raise ValueError(f"The app does not contain iPhone 13 arm64 code: {architecture}")
    if not info.get("MinimumOSVersion"):
        raise ValueError("The built app has no minimum iOS version")
    extension = APP / "PlugIns/SonoraWidgets.appex"
    with (extension / "Info.plist").open("rb") as source:
        widget = plistlib.load(source)
    if (widget["CFBundleIdentifier"] != info["CFBundleIdentifier"] + ".widgets"
            or widget["CFBundleVersion"] != info["CFBundleVersion"]
            or widget["CFBundleShortVersionString"] != info["CFBundleShortVersionString"]
            or widget["CFBundleSupportedPlatforms"] != ["iPhoneOS"]
            or widget["NSExtension"]["NSExtensionPointIdentifier"] != "com.apple.widgetkit-extension"):
        raise ValueError("Invalid Sonora widget extension")
    widget_archs = subprocess.check_output(["lipo", "-archs", str(extension / widget["CFBundleExecutable"])], text=True)
    if "arm64" not in widget_archs.split():
        raise ValueError("The widget does not contain iPhone arm64 code")

    package_root = BUILD / "package"
    if package_root.exists():
        shutil.rmtree(package_root)
    payload = package_root / "Payload"
    payload.mkdir(parents=True)
    subprocess.run(["ditto", str(APP), str(payload / "Sonora.app")], check=True)
    archive = BUILD / "Sonora-unsigned.ipa"
    archive.unlink(missing_ok=True)
    subprocess.run(["ditto", "-c", "-k", "--keepParent", str(payload), str(archive)], check=True)
    with zipfile.ZipFile(archive) as result:
        if result.testzip() is not None:
            raise ValueError("The IPA archive failed integrity verification")
        if not {"Payload/Sonora.app/Info.plist",
                "Payload/Sonora.app/PlugIns/SonoraWidgets.appex/Info.plist"}.issubset(result.namelist()):
            raise ValueError("The IPA does not contain the app and widget extension")
    digest = hashlib.sha256()
    with archive.open("rb") as source:
        for chunk in iter(lambda: source.read(1_048_576), b""):
            digest.update(chunk)
    commit = os.environ.get("GITHUB_SHA") or subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=IOS.parent, text=True
    ).strip()
    report = {
        "source_commit": commit,
        "workflow_run": os.environ.get("GITHUB_RUN_ID"),
        "built_at_utc": datetime.now(timezone.utc).isoformat(),
        "build_kind": os.environ.get("SONORA_BUILD_KIND", "local-development"),
        "sha256": digest.hexdigest(),
        "bundle_id": info["CFBundleIdentifier"],
        "version": info["CFBundleShortVersionString"],
        "build_number": info["CFBundleVersion"],
        "minimum_ios": info["MinimumOSVersion"],
        "architectures": architecture.split(),
        "platforms": info["CFBundleSupportedPlatforms"],
        "widget_bundle_id": widget["CFBundleIdentifier"],
        "signing": "Unsigned; the sideloading tool must sign before installation.",
        "validation": "Device bundle and ZIP integrity only. This does not verify app features.",
    }
    (BUILD / "ipa-build-info.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Packaged and verified device archive: {archive}")


if __name__ == "__main__":
    package()
