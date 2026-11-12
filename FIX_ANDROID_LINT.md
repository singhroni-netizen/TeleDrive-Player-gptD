# TeleDrive Player — Android CI lint workaround

This patch addresses the Android build failure shown in the GitHub Actions log:
`NoSuchMethodError: JavaDocParser.parseDataItem(...)` originating inside Android
Lint's `LintDriver` / `UElementVisitor`.

That stack is an Android Lint tooling crash, not the earlier duplicate
`_sleepTimer` Dart declaration. This patch:

1. Pins Android and Windows CI to Flutter 3.35.7 for a reproducible SDK baseline.
2. Updates `scripts/bootstrap_flutter.py` to disable Gradle tasks whose names
   contain `lint`. Lint is not required to compile/package the release APK.
   Flutter compilation, Gradle packaging, and unit tests remain enabled.

## Apply

Copy these two files into the root of your cloned repository, replacing the
existing files at the same paths:

- `.github/workflows/ci.yml`
- `scripts/bootstrap_flutter.py`

Then commit and push. GitHub Actions should start a new run automatically.

If it still fails, share the first error above `BUILD FAILED`; do not rely on
the final `Process completed with exit code 1` line.
