#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "✗ $*" >&2
  exit 1
}

grep -q 'productFlavors' app/android/app/build.gradle.kts || fail "Android build must define product flavors"
grep -q 'applicationId = "com.airoucat.pawterm.dev"' app/android/app/build.gradle.kts || fail "dev flavor must use com.airoucat.pawterm.dev"
grep -q 'resValue("string", "app_name", "PawTerm Dev")' app/android/app/build.gradle.kts || fail "dev flavor must set PawTerm Dev app name"
grep -q 'android:label="@string/app_name"' app/android/app/src/main/AndroidManifest.xml || fail "Android label must come from app_name resource"

grep -q 'prerelease-v' scripts/release.sh || fail "release script must use prerelease-v tags"
! grep -q 'dev-v' scripts/release.sh || fail "release script must not use dev-v release tags"

grep -q -- '--dev' app/scripts/build-apk.sh || fail "APK build script must expose --dev for local dev APKs"
grep -q -- '--prod' app/scripts/build-apk.sh || fail "APK build script must expose --prod"
grep -q -- '--all-abi' app/scripts/build-apk.sh || fail "APK build script must allow full-ABI dev builds explicitly"
grep -q -- '--flavor "$FLAVOR"' app/scripts/build-apk.sh || fail "APK build script must pass the selected flavor to Flutter"
grep -q 'SPLIT_PER_ABI=0' app/scripts/build-apk.sh || fail "dev APK builds must default to arm64 only"
grep -q 'pawtermAbiFilter=arm64-v8a' app/scripts/build-apk.sh || fail "single-ABI APK builds must filter transitive native libraries"
grep -q 'find "$VERSION_DIR" -maxdepth 1 -type f -name "${NAME_PREFIX}-${VERSION}-\*.apk" -delete' app/scripts/build-apk.sh || fail "versioned APK output must remove stale artifacts for the current flavor"
grep -q 'if \[\[ "$FLAVOR" == "prod" \]\]; then' app/scripts/build-apk.sh || fail "only prod APKs should copy to dist"
grep -q 'pawtermAbiFilter' app/android/app/build.gradle.kts || fail "Android Gradle build must support ABI filtering for single-ABI APKs"

grep -q 'CI=true bash app/scripts/build-apk.sh --prod' .github/workflows/release.yml || fail "stable release workflow must build prod APKs"
grep -q 'CI=true bash app/scripts/build-apk.sh --prod' .github/workflows/prerelease.yml || fail "prerelease workflow must build prod APKs"
! grep -q 'build-apk.sh --dev' .github/workflows/release.yml .github/workflows/prerelease.yml || fail "GitHub Release workflows must not build .dev APKs"

[[ ! -f mac/build.sh ]] || fail "Mac build must have one public entrypoint; remove mac/build.sh"
! grep -q 'bash build.sh --dev' mac/scripts/build.sh || fail "mac/scripts/build.sh must not shell out to mac/build.sh"
grep -q 'appUpdateChannel' mac/Sources/PawTerm/ServerManager.swift || fail "Mac app update checks must expose an update channel"
grep -q 'prerelease-v' mac/Sources/PawTerm/ServerManager.swift || fail "Mac app update checks must understand prerelease-v tags"
grep -q 'isDevBuild' mac/Sources/PawTerm/ServerManager.swift || fail "Mac dev builds must be identifiable"
grep -q 'appReleasePageURL' mac/Sources/PawTerm/ServerManager.swift || fail "Mac update download must open the selected release page"
grep -q 'serverTag = appUpdateChannel == .prerelease ? "prerelease" : "latest"' mac/Sources/PawTerm/ServerManager.swift || fail "Mac prerelease channel must check npm server prerelease dist-tag"
grep -q 'serverPackage = appUpdateChannel == .prerelease ? "pawterm-server@prerelease" : "pawterm-server@latest"' mac/Sources/PawTerm/ServerManager.swift || fail "Mac prerelease channel must install npm server prerelease dist-tag"
grep -q 'Prerelease channel' mac/Sources/PawTerm/MenuBarContent.swift || fail "Mac menu must expose a prerelease channel toggle"
grep -q 'official updates are disabled' mac/Sources/PawTerm/MenuBarContent.swift || fail "Mac dev builds must explain that official updates are disabled"

grep -q -- '--prerelease' server/scripts/publish.sh || fail "server publish script must expose --prerelease"
grep -q 'prerelease-server-v' server/scripts/publish.sh || fail "server publish git tags must use prerelease-server-v"
grep -q 'npm publish --tag prerelease' server/scripts/publish.sh || fail "server prereleases must publish to npm prerelease dist-tag"
! grep -q 'dev-server-v' server/scripts/publish.sh || fail "server publish script must not create dev-server-v tags"
grep -q 'pnpm --filter @pawterm/web run build' server/scripts/publish.sh || fail "server publish must build web before packaging server"

echo "✓ build channel contracts ok"
