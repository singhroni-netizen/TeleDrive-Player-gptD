#!/usr/bin/env python3
"""Generate Flutter's Android and Windows runner folders without overwriting app code."""
from __future__ import annotations
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLIENT = ROOT / "client"


def main() -> None:
    if not (CLIENT / "pubspec.yaml").exists():
        raise SystemExit("client/pubspec.yaml not found")
    with tempfile.TemporaryDirectory(prefix="tele-drive-platforms-") as tmp:
        target = Path(tmp) / "tele_drive_player"
        subprocess.run([
            "flutter", "create", "--no-pub", "--platforms=android,windows",
            "--project-name=tele_drive_player", "--org=com.teledriveplayer", str(target),
        ], check=True)
        for folder in ("android", "windows"):
            dest = CLIENT / folder
            if dest.exists():
                shutil.rmtree(dest)
            shutil.copytree(target / folder, dest)
        metadata = target / ".metadata"
        if metadata.exists():
            shutil.copy2(metadata, CLIENT / ".metadata")
    # Android Lint has a known class/parser crash in some moving toolchain
    # combinations. Lint is not required to produce the release APK; disable
    # lint tasks while keeping the actual compile/package tasks enabled.
    app_dir = CLIENT / "android" / "app"
    gradle_file = next(
        (candidate for candidate in (app_dir / "build.gradle", app_dir / "build.gradle.kts")
         if candidate.exists()),
        None,
    )
    if gradle_file is None:
        raise SystemExit("Generated Android app Gradle file was not found")
    gradle_text = gradle_file.read_text(encoding="utf-8")
    lint_guard = (
            if "Work around Android Lint parser crash" not in gradle_text:
        if gradle_file.suffix == ".kts":
            lint_guard = """
// Work around Android Lint parser crash.
// This does not disable APK compilation.
tasks.configureEach {
    if (name.contains("lint", ignoreCase = true)) {
        enabled = false
    }
}
"""
        else:
            lint_guard = """
// Work around Android Lint parser crash.
tasks.configureEach { task ->
    if (task.name.toLowerCase().contains('lint')) {
        task.enabled = false
    }
}
"""
        gradle_file.write_text(gradle_text + lint_guard, encoding="utf-8")

    manifest = CLIENT / "android" / "app" / "src" / "main" / "AndroidManifest.xml"
    text = manifest.read_text(encoding="utf-8")
    if "android.permission.INTERNET" not in text:
        text = text.replace("<manifest ", '<manifest xmlns:tools="http://schemas.android.com/tools" ', 1)
        text = text.replace("<application", '<uses-permission android:name="android.permission.INTERNET" />\n    <application android:usesCleartextTraffic="true"', 1)
    elif "usesCleartextTraffic" not in text:
        text = text.replace("<application", '<application android:usesCleartextTraffic="true"', 1)
    manifest.write_text(text, encoding="utf-8")
    print("Generated client/android and client/windows. App source and pubspec were preserved.")


if __name__ == "__main__":
    main()
