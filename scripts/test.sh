#!/bin/zsh
set -eu
cd "${0:A:h:h}"
task_build_dir="${TMPDIR:-/private/tmp/}StoryWriter-build"
export CLANG_MODULE_CACHE_PATH="$task_build_dir/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_build_dir/ModuleCache"
if [[ "$(uname -m)" == arm64 && "${STORYWRITER_DISABLE_MLX:-0}" != 1 ]]; then
    swift package --cache-path "$task_build_dir/cache" --config-path "$task_build_dir/config" --security-path "$task_build_dir/security" --scratch-path "$task_build_dir" --disable-sandbox resolve
    python3 scripts/prepare-mlx-resources.py "$task_build_dir"
    task_test_products="$task_build_dir/arm64-apple-macosx/debug"
    zsh scripts/build-mlx-metal.sh "$task_build_dir/checkouts/mlx-swift" "$task_test_products/mlx.metallib"
    # XCTest is hosted by Xcode's runner rather than this executable. MLX also
    # searches beside the binary containing MLX, inside the XCTest bundle.
    task_test_metal="$task_test_products/StoryWriterPackageTests.xctest/Contents/MacOS"
    mkdir -p "$task_test_metal"
    cp "$task_test_products/mlx.metallib" "$task_test_metal/mlx.metallib"
fi
swift test --build-system native --cache-path "$task_build_dir/cache" --config-path "$task_build_dir/config" --security-path "$task_build_dir/security" --scratch-path "$task_build_dir" --disable-sandbox "$@"
