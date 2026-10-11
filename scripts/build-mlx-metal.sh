#!/bin/zsh
# SwiftPM's native builder does not compile .metal resources. Compile the
# non-JIT kernels used by pinned mlx-swift 0.31.3, matching its CMakeLists.txt.
set -eu
mlx_checkout="$1"
mlx_output="$2"
mlx_sources="$mlx_checkout/Source/Cmlx/mlx"
mlx_kernels="$mlx_sources/mlx/backend/metal/kernels"
mkdir -p "${mlx_output:h}"
if [[ -f "$mlx_output" && "$mlx_output" -nt "$mlx_kernels/CMakeLists.txt" ]]; then exit 0; fi
mlx_work=$(mktemp -d "${TMPDIR:-/private/tmp/}StoryWriter-mlx-metal.XXXXXX")
trap 'rm -rf "$mlx_work"' EXIT
mlx_objects=()
for mlx_kernel in arg_reduce conv gemv layer_norm random rms_norm rope scaled_dot_product_attention fence; do
    xcrun -sdk macosx metal -c -std=metal3.2 -mmacosx-version-min=14.0 -fno-fast-math \
        -Wno-c++17-extensions -Wno-c++20-extensions \
        -I "$mlx_sources" -I "$mlx_kernels" "$mlx_kernels/$mlx_kernel.metal" -o "$mlx_work/$mlx_kernel.air"
    mlx_objects+=("$mlx_work/$mlx_kernel.air")
done
xcrun -sdk macosx metallib "${mlx_objects[@]}" -o "$mlx_output"
