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
