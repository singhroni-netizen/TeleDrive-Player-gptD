
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

    # TDLib's AAR also declares an application label. Keep the Flutter app's
    # label and resolve the manifest merger conflict explicitly.
    if "xmlns:tools=" not in content:
        content = content.replace(
            "<manifest",
            '<manifest xmlns:tools="http://schemas.android.com/tools"',
            1,
        )

    application_start = content.find("<application")
    if application_start < 0:
        raise SystemExit("Application element not found in AndroidManifest.xml")
    application_end = content.find(">", application_start)
    if application_end < 0:
        raise SystemExit("Malformed application element in AndroidManifest.xml")
    application_tag = content[application_start:application_end]
    if "tools:replace=" not in application_tag:
        application_tag += ' tools:replace="android:label"'
    elif "android:label" not in application_tag.split("tools:replace=", 1)[1]:
        application_tag = application_tag.replace(
            'tools:replace="', 'tools:replace="android:label,', 1
        )
    content = (
        content[:application_start]
        + application_tag
        + content[application_end:]
    )

    manifest.write_text(content, encoding="utf-8")



def configure_teledrive_android() -> None:
    """Install the native TDLib bridge into the generated Android runner."""
    native_dir = ROOT / "client" / "native" / "android"
    package_dir = (
        CLIENT / "android" / "app" / "src" / "main" / "kotlin"
        / "com" / "teledriveplayer" / "tele_drive_player"
    )
    package_dir.mkdir(parents=True, exist_ok=True)

    for filename in ("MainActivity.kt", "TeleDriveNativeBridge.kt"):
        source = native_dir / filename
        if not source.exists():
            raise SystemExit(f"Native TeleDrive source not found: {source}")
        shutil.copy2(source, package_dir / filename)

    # Use the same JitPack TDLib AAR coordinate as the upstream TeleDrive app.
    root_gradle = next(
        (
            candidate
            for candidate in (
                CLIENT / "android" / "build.gradle.kts",
                CLIENT / "android" / "build.gradle",
            )
            if candidate.exists()
        ),
        None,
    )
    if root_gradle is None:
        raise SystemExit("Android root Gradle file not found")
    root_content = root_gradle.read_text(encoding="utf-8")
    if "jitpack.io" not in root_content:
        if root_gradle.suffix == ".kts":
            updated_root = root_content.replace(
                "mavenCentral()",
                'mavenCentral()\\n        maven("https://jitpack.io")',
                1,
            )
        else:
            updated_root = root_content.replace(
                "mavenCentral()",
                "mavenCentral()\\n        maven { url 'https://jitpack.io' }",
                1,
            )
        if updated_root == root_content:
            raise SystemExit("Could not add JitPack to Android root repositories")
        root_gradle.write_text(updated_root, encoding="utf-8")

    app_gradle = next(
        (
            candidate
            for candidate in (
                CLIENT / "android" / "app" / "build.gradle.kts",
                CLIENT / "android" / "app" / "build.gradle",
            )
            if candidate.exists()
        ),
        None,
    )
    if app_gradle is None:
        raise SystemExit("Android app Gradle file not found")

    gradle = app_gradle.read_text(encoding="utf-8")

    # TeleDrive's Android engine uses Android Keystore and targets API 26+.
    if app_gradle.suffix == ".kts":
        gradle = gradle.replace("minSdk = flutter.minSdkVersion", "minSdk = 26", 1)
    else:
        gradle = gradle.replace(
            "minSdkVersion flutter.minSdkVersion", "minSdkVersion 26", 1
        )

    # Maven Central hosts the Android AAR; no JitPack or backend service is needed.
    dependency = 'implementation("com.github.tdlibx:td:1.8.56")'
    if "io.github.tdlibx:td-android:" not in gradle:
        gradle = (
            gradle.rstrip()
            + "\n\ndependencies {\n    "
            + dependency
            + "\n}\n"
        )

    app_gradle.write_text(gradle, encoding="utf-8")


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
    configure_teledrive_android()

    print("Flutter platform folders generated successfully.")


if __name__ == "__main__":
    main()
