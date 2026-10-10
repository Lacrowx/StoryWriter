#!/bin/zsh
set -eu
cd "${0:A:h:h}"
task_build_dir="${TMPDIR:-/private/tmp/}StoryWriter-build"
export CLANG_MODULE_CACHE_PATH="$task_build_dir/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_build_dir/ModuleCache"
swift build -c release --build-system native --cache-path "$task_build_dir/cache" --config-path "$task_build_dir/config" --security-path "$task_build_dir/security" --scratch-path "$task_build_dir" --disable-sandbox
task_binary_dir=$(swift build -c release --build-system native --cache-path "$task_build_dir/cache" --config-path "$task_build_dir/config" --security-path "$task_build_dir/security" --scratch-path "$task_build_dir" --disable-sandbox --show-bin-path)
task_app_dir="$PWD/dist/StoryWriter.app"
mkdir -p "$task_app_dir/Contents/MacOS" "$task_app_dir/Contents/Resources"
cp "$task_binary_dir/StoryWriter" "$task_app_dir/Contents/MacOS/StoryWriter"
cp Resources/Info.plist "$task_app_dir/Contents/Info.plist"
swift scripts/make-icon.swift "$task_build_dir/AppIcon.iconset"
cp "$task_build_dir/AppIcon.icns" "$task_app_dir/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$task_app_dir"
printf 'Built: %s\n' "$task_app_dir"
