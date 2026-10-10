#!/bin/zsh
set -eu
set -o pipefail
cd "${0:A:h:h}"
task_build_dir="${STORYWRITER_BUILD_DIR:-${TMPDIR:-/private/tmp/}StoryWriter-build}"
export CLANG_MODULE_CACHE_PATH="$task_build_dir/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_build_dir/ModuleCache"
task_swift_options=(--build-system native --cache-path "$task_build_dir/cache" --config-path "$task_build_dir/config" --security-path "$task_build_dir/security" --disable-sandbox)
task_app_dir="$PWD/dist/StoryWriter.app"
mkdir -p "$task_app_dir/Contents/MacOS" "$task_app_dir/Contents/Resources" "$task_app_dir/Contents/Frameworks"

if [[ "${STORYWRITER_UNIVERSAL:-0}" == 1 ]]; then
    for task_arch in arm64 x86_64; do
        swift build -c release "${task_swift_options[@]}" --scratch-path "$task_build_dir/$task_arch" --triple "$task_arch-apple-macosx14.0"
        task_binary_dir=$(swift build -c release "${task_swift_options[@]}" --scratch-path "$task_build_dir/$task_arch" --triple "$task_arch-apple-macosx14.0" --show-bin-path)
        cp "$task_binary_dir/StoryWriter" "$task_build_dir/StoryWriter-$task_arch"
    done
    lipo -create "$task_build_dir/StoryWriter-arm64" "$task_build_dir/StoryWriter-x86_64" -output "$task_app_dir/Contents/MacOS/StoryWriter"
    task_artifact_dir="$task_build_dir/arm64/artifacts/sparkle/Sparkle"
else
    swift build -c release "${task_swift_options[@]}" --scratch-path "$task_build_dir"
    task_binary_dir=$(swift build -c release "${task_swift_options[@]}" --scratch-path "$task_build_dir" --show-bin-path)
    cp "$task_binary_dir/StoryWriter" "$task_app_dir/Contents/MacOS/StoryWriter"
    task_artifact_dir="$task_build_dir/artifacts/sparkle/Sparkle"
fi

ditto "$task_artifact_dir/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$task_app_dir/Contents/Frameworks/Sparkle.framework"
cp "$task_artifact_dir/LICENSE" "$task_app_dir/Contents/Resources/Sparkle-LICENSE"
cp Resources/Info.plist "$task_app_dir/Contents/Info.plist"
task_plist="$task_app_dir/Contents/Info.plist"
if [[ -n "${STORYWRITER_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $STORYWRITER_VERSION" "$task_plist"
fi
if [[ -n "${STORYWRITER_BUILD_NUMBER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $STORYWRITER_BUILD_NUMBER" "$task_plist"
fi
task_public_key=$(tr -d '\r\n' < Resources/update-public-key.txt)
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $task_public_key" "$task_plist"
/usr/libexec/PlistBuddy -c 'Add :SUFeedURL string https://github.com/Lacrowx/StoryWriter/releases/latest/download/appcast.xml' "$task_plist"
/usr/libexec/PlistBuddy -c 'Add :SUEnableAutomaticChecks bool true' "$task_plist"
/usr/libexec/PlistBuddy -c 'Add :SUAutomaticallyUpdate bool true' "$task_plist"
/usr/libexec/PlistBuddy -c 'Add :SUVerifyUpdateBeforeExtraction bool true' "$task_plist"
/usr/libexec/PlistBuddy -c 'Add :SURequireSignedFeed bool true' "$task_plist"
swift scripts/make-icon.swift "$task_build_dir/AppIcon.iconset"
cp "$task_build_dir/AppIcon.icns" "$task_app_dir/Contents/Resources/AppIcon.icns"

# Developer ID signing is optional; personal builds use an ad-hoc signature.
task_identity="${STORYWRITER_SIGNING_IDENTITY:--}"
task_sign_options=(--force --sign "$task_identity")
if [[ "$task_identity" != - ]]; then task_sign_options+=(--options runtime --timestamp); fi
task_framework="$task_app_dir/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign "${task_sign_options[@]}" "$task_framework/XPCServices/Downloader.xpc"
codesign "${task_sign_options[@]}" "$task_framework/XPCServices/Installer.xpc"
codesign "${task_sign_options[@]}" "$task_framework/Autoupdate"
codesign "${task_sign_options[@]}" "$task_framework/Updater.app"
codesign "${task_sign_options[@]}" "$task_app_dir/Contents/Frameworks/Sparkle.framework"
codesign "${task_sign_options[@]}" "$task_app_dir"
codesign --verify --deep --strict "$task_app_dir"
printf 'Built: %s\n' "$task_app_dir"
