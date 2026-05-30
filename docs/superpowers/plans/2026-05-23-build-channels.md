# Build Channels Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Separate local Android dev app builds from production GitHub Release assets, normalize release tags, and make Mac build entrypoints match APK build scripts.

**Architecture:** GitHub Release stable and prerelease builds always keep `com.airoucat.pawterm` and use release signing. Local dev Android builds use `com.airoucat.pawterm.dev`, display `PawTerm Dev`, and are not uploaded to GitHub Release. Mac builds expose one public script, `mac/scripts/build.sh`, which packages prod or dev apps directly.

**Tech Stack:** Flutter Android Gradle Kotlin DSL, zsh/bash build scripts, GitHub Actions, Swift Package Manager for Mac.

---

### Task 1: Mac Build Entrypoint

**Files:**
- Modify: `mac/scripts/build.sh`
- Delete: `mac/build.sh`
- Modify: `mac/README.md`
- Modify: `README.md`

- [ ] Inline the existing `mac/build.sh` packaging behavior into `mac/scripts/build.sh`.
- [ ] Keep `mac/scripts/build.sh --dev` building and installing `PawTermDev.app`.
- [ ] Keep release builds writing `dist/PawTerm-{version}-mac.zip`.
- [ ] Remove references that tell users to run `mac/build.sh` directly.

### Task 2: Android Channels

**Files:**
- Modify: `app/android/app/build.gradle.kts`
- Modify: `app/android/app/src/main/AndroidManifest.xml`
- Modify: `.gitignore`

- [ ] Add `prod` and `dev` flavors.
- [ ] Set `prod` app name to `PawTerm`.
- [ ] Set `dev` application id to `com.airoucat.pawterm.dev` and app name to `PawTerm Dev`.
- [ ] Configure production release signing from `app/android/key.properties` or `ANDROID_*` environment variables.
- [ ] Let local dev builds use the normal Android debug signing identity.
- [ ] Keep production keystore files ignored.

### Task 3: APK Build Script And CI

**Files:**
- Modify: `app/scripts/build-apk.sh`
- Modify: `.github/workflows/build-apk.yml`
- Modify: `.github/workflows/release.yml`
- Rename: `.github/workflows/dev-release.yml` to `.github/workflows/prerelease.yml`

- [ ] Add `--prod` and `--dev` options to the APK script.
- [ ] Make the default APK build use `prod`.
- [ ] Keep GitHub Release workflows on `--prod`.
- [ ] Keep `.dev` APKs local-only; they must not be attached to GitHub Release.
- [ ] Make release and prerelease workflows pass Android signing secrets and build `--prod`.
- [ ] Rename the prerelease workflow semantics from dev release to prerelease release.

### Task 4: Release Tags And App Update Channel

**Files:**
- Modify: `scripts/release.sh`
- Modify: `app/lib/utils/update_checker.dart`
- Modify: `app/lib/screens/settings_screen.dart`
- Modify: `app/lib/i18n/strings.dart`
- Modify: `CLAUDE.md`

- [ ] Use `release-v{semver}` for stable releases.
- [ ] Use `prerelease-v{semver}` for production prereleases.
- [ ] Keep `--dev` as a compatibility alias for prerelease but message it as deprecated.
- [ ] Make the app prerelease toggle fetch the newest `prerelease-v*` release.
- [ ] Rename user-facing “Dev channel” text to “Prerelease channel”.

### Task 5: Verification

**Commands:**
- `zsh -n app/scripts/build-apk.sh`
- `zsh -n scripts/release.sh`
- `zsh -n mac/scripts/build.sh`
- `flutter analyze` from `app`

- [ ] Run shell syntax checks.
- [ ] Run Flutter analysis without invoking release build scripts.
