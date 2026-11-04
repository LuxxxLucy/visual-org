#!/bin/sh
set -eu
command=${1:-build}
if [ "$#" -gt 0 ]; then shift; fi
case "$command" in
    build|test|run) ;;
    *) printf 'Usage: %s {build|test|run} [file.org]\n' "$0" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ] || { [ "$command" = build ] && [ "$#" -gt 0 ]; }; then
    printf 'Usage: %s {build|test|run} [file.org]\n' "$0" >&2
    exit 2
fi
document=${1:-}
case "$document" in
    '') ;;
    /*) ;;
    *) document="$PWD/$document" ;;
esac
cd "$(dirname "$0")"
document=${document:-"$PWD/../../../todo.org"}
app="$PWD/build/visual-org.app"

swift_package() {
mkdir -p build/modules
CLANG_MODULE_CACHE_PATH="$PWD/build/modules" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/modules" \
swift "$@" -c release --scratch-path build/package --cache-path build/cache \
    --config-path build/config --security-path build/security \
    --manifest-cache local --disable-sandbox \
    -Xswiftc -module-cache-path -Xswiftc "$(pwd)/build/modules"
}

build() {
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swift_package build
cp build/package/release/visual-org "$app/Contents/MacOS/visual-org"
cp Info.plist "$app/Contents/Info.plist"
cp Examples/Review.org "$app/Contents/Resources/Review.org"
xcrun swift -module-cache-path build/modules Tools/Icon.swift
cp build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"
printf '%s\n' "$app"
}

case "$command" in
    build) build ;;
    test)
        swift_package build --product CoreChecks
        build/package/release/CoreChecks
        build
        set --
        for source in Sources/App/*.swift; do
            [ "$source" = Sources/App/VisualOrgApp.swift ] || set -- "$@" "$source"
        done
        xcrun swiftc -parse-as-library -module-cache-path build/modules \
            -I build/package/release/Modules Tools/CardCoverageCheck.swift "$@" \
            build/package/release/OrgCore.build/*.swift.o \
            build/package/release/WorkspaceCore.build/*.swift.o \
            build/package/release/Crypto.build/*.swift.o -o build/card-coverage-check
        build/card-coverage-check "$document"
        xcrun swiftc -parse-as-library -module-cache-path build/modules \
            -I build/package/release/Modules \
            Tools/BehaviorTests.swift Tools/StartupCheck.swift Tools/UIAutomation.swift Tools/UIWorkflowTests.swift Sources/App/OrgSession.swift Sources/App/MacFileAccess.swift Sources/App/CanvasLayout.swift Sources/App/CreationDrafts.swift \
            build/package/release/OrgCore.build/*.swift.o \
            build/package/release/WorkspaceCore.build/*.swift.o \
            build/package/release/Crypto.build/*.swift.o -o build/behavior-tests
        build/behavior-tests "$document" "$app"
        ;;
    run)
        [ -f "$document" ] || { printf 'Org file not found: %s\n' "$document" >&2; exit 1; }
        [ -x "$app/Contents/MacOS/visual-org" ] || build
        open -a "$app" "$document"
        ;;
esac
