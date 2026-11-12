
#!/usr/bin/env python3
"""Generate Flutter Android and Windows runner folders."""

from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLIENT = ROOT / "client"


def configure_android_lint() -> None:
    app_dir = CLIENT / "android" / "app"

    gradle_file = next(
        (
            candidate
            for candidate in (
                app_dir / "build.gradle",
                app_dir / "build.gradle.kts",
            )
            if candidate.exists()
        ),
        None,
    )

    if gradle_file is None:
        raise SystemExit("Android app Gradle file not found")

    gradle_text = gradle_file.read_text(encoding="utf-8")

    marker = "Work around Android Lint parser crash"

    if marker in gradle_text:
        return

    if gradle_file.suffix == ".kts":
        lint_guard = """
// Work around Android Lint parser crash.
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

    gradle_file.write_text(
        gradle_text.rstrip() + "\n\n" + lint_guard,
        encoding="utf-8",
    )


def configure_manifest() -> None:
    manifest = (
        CLIENT
        / "android"
        / "app"
        / "src"
        / "main"
        / "AndroidManifest.xml"
    )

    if not manifest.exists():
        raise SystemExit("AndroidManifest.xml not found")

    content = manifest.read_text(encoding="utf-8")

    permission = (
        '<uses-permission android:name="android.permission.INTERNET" />'
    )

    if permission not in content:
        content = content.replace(
            "<application",
            permission + "\n    <application",
            1,
        )

    if "android:usesCleartextTraffic" not in content:
        content = content.replace(
            "<application",
            '<application android:usesCleartextTraffic="true"',
            1,
        )

    manifest.write_text(content, encoding="utf-8")


def main() -> None:
    if not (CLIENT / "pubspec.yaml").exists():
        raise SystemExit("client/pubspec.yaml not found")

    with tempfile.TemporaryDirectory(
        prefix="tele-drive-platforms-"
    ) as temp_dir:

        target = Path(temp_dir) / "tele_drive_player"

        subprocess.run(
            [
                "flutter",
                "create",
                "--no-pub",
                "--platforms=android,windows",
                "--project-name=tele_drive_player",
                "--org=com.teledriveplayer",
                str(target),
            ],
            check=True,
        )

        for folder in ("android", "windows"):
            destination = CLIENT / folder

            if destination.exists():
                shutil.rmtree(destination)

            shutil.copytree(target / folder, destination)

        metadata = target / ".metadata"

        if metadata.exists():
            shutil.copy2(metadata, CLIENT / ".metadata")

    configure_android_lint()
    configure_manifest()

    print("Flutter platform folders generated successfully.")


if __name__ == "__main__":
    main()
