#!/bin/zsh
set -eu
cd "${0:A:h:h}"
task_build_dir="${TMPDIR:-/private/tmp/}StoryWriter-build"
export CLANG_MODULE_CACHE_PATH="$task_build_dir/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_build_dir/ModuleCache"
swift test --build-system native --cache-path "$task_build_dir/cache" --config-path "$task_build_dir/config" --security-path "$task_build_dir/security" --scratch-path "$task_build_dir" --disable-sandbox "$@"
