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
        task_disable_mlx=0
        if [[ "$task_arch" == x86_64 ]]; then task_disable_mlx=1; fi
        if [[ "$task_arch" == arm64 ]]; then
            STORYWRITER_DISABLE_MLX=0 swift package --cache-path "$task_build_dir/cache" --config-path "$task_build_dir/config" --security-path "$task_build_dir/security" --disable-sandbox --scratch-path "$task_build_dir/$task_arch" resolve
            python3 scripts/prepare-mlx-resources.py "$task_build_dir/$task_arch"
        fi
        STORYWRITER_DISABLE_MLX="$task_disable_mlx" swift build -c release "${task_swift_options[@]}" --scratch-path "$task_build_dir/$task_arch" --triple "$task_arch-apple-macosx14.0"
        task_binary_dir=$(STORYWRITER_DISABLE_MLX="$task_disable_mlx" swift build -c release "${task_swift_options[@]}" --scratch-path "$task_build_dir/$task_arch" --triple "$task_arch-apple-macosx14.0" --show-bin-path)
        cp "$task_binary_dir/StoryWriter" "$task_build_dir/StoryWriter-$task_arch"
    done
    lipo -create "$task_build_dir/StoryWriter-arm64" "$task_build_dir/StoryWriter-x86_64" -output "$task_app_dir/Contents/MacOS/StoryWriter"
    task_artifact_dir="$task_build_dir/arm64/artifacts/sparkle/Sparkle"
    task_mlx_build_dir="$task_build_dir/arm64"
    task_resource_dir="$task_build_dir/arm64/arm64-apple-macosx/release"
else
    if [[ "$(uname -m)" == arm64 && "${STORYWRITER_DISABLE_MLX:-0}" != 1 ]]; then
        swift package --cache-path "$task_build_dir/cache" --config-path "$task_build_dir/config" --security-path "$task_build_dir/security" --disable-sandbox --scratch-path "$task_build_dir" resolve
        python3 scripts/prepare-mlx-resources.py "$task_build_dir"
    fi
    swift build -c release "${task_swift_options[@]}" --scratch-path "$task_build_dir"
    task_binary_dir=$(swift build -c release "${task_swift_options[@]}" --scratch-path "$task_build_dir" --show-bin-path)
    cp "$task_binary_dir/StoryWriter" "$task_app_dir/Contents/MacOS/StoryWriter"
    task_artifact_dir="$task_build_dir/artifacts/sparkle/Sparkle"
    task_mlx_build_dir="$task_build_dir"
    task_resource_dir="$task_binary_dir"
fi

if [[ "${STORYWRITER_DISABLE_MLX:-0}" != 1 && ( "$(uname -m)" == arm64 || "${STORYWRITER_UNIVERSAL:-0}" == 1 ) ]]; then
    rm -rf "$task_app_dir/Contents/MacOS/mlx-metal-air"
    rm -f "$task_app_dir/Contents/MacOS/mlx.metallib"
    task_metal_bundle="$task_app_dir/Contents/Resources/mlx-swift_Cmlx.bundle"
    mkdir -p "$task_metal_bundle/Contents/Resources"
    zsh scripts/build-mlx-metal.sh "$task_mlx_build_dir/checkouts/mlx-swift" "$task_metal_bundle/Contents/Resources/default.metallib"
    cat > "$task_metal_bundle/Contents/Info.plist" <<'METAL_PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.storywriter.mlx-resources</string><key>CFBundleName</key><string>Cmlx</string><key>CFBundlePackageType</key><string>BNDL</string><key>CFBundleVersion</key><string>1</string></dict></plist>
METAL_PLIST
    # Keep resources inside the signed app; the build adapter teaches the
    # pinned tokenizer to resolve this layout instead of the unsigned root.
    rm -rf "$task_app_dir/swift-crypto_Crypto.bundle" "$task_app_dir/swift-transformers_Hub.bundle"
    for task_resource in "$task_resource_dir"/*.bundle(N); do
        ditto "$task_resource" "$task_app_dir/Contents/Resources/${task_resource:t}"
    done
    mkdir -p "$task_app_dir/Contents/Resources/ThirdPartyLicenses"
    for task_dependency in mlx-swift mlx-swift-lm swift-transformers swift-jinja swift-huggingface swift-collections swift-crypto swift-asn1 swift-numerics yyjson EventSource; do
        for task_license in "$task_mlx_build_dir/checkouts/$task_dependency"/LICENSE*(N); do
            cp -f "$task_license" "$task_app_dir/Contents/Resources/ThirdPartyLicenses/$task_dependency-${task_license:t}"
        done
    done
    cp -f "$task_mlx_build_dir/checkouts/mlx-swift/Source/Cmlx/metal-cpp/LICENSE.txt" "$task_app_dir/Contents/Resources/ThirdPartyLicenses/metal-cpp-LICENSE.txt"
fi

ditto "$task_artifact_dir/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$task_app_dir/Contents/Frameworks/Sparkle.framework"
cp "$task_artifact_dir/LICENSE" "$task_app_dir/Contents/Resources/Sparkle-LICENSE"
cp Resources/Info.plist "$task_app_dir/Contents/Info.plist"
task_plist="$task_app_dir/Contents/Info.plist"
# Local builds match the newest release tag (CI uses 0.2.<run> and build
# 1000 + run), so Sparkle offers newer releases instead of replacing a local
# build with the release it was built from.
if [[ -z "${STORYWRITER_VERSION:-}" ]]; then
    task_latest_tag=$(git tag --list 'v0.2.*' --sort=-v:refname 2>/dev/null | head -1)
    if [[ -n "$task_latest_tag" ]]; then
        STORYWRITER_VERSION="${task_latest_tag#v}-local"
        STORYWRITER_BUILD_NUMBER="${STORYWRITER_BUILD_NUMBER:-$((1000 + ${task_latest_tag##*.}))}"
    fi
fi
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
