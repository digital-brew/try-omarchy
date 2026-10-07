#!/bin/bash

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd -P)
macos_dir=$(cd "$test_dir/.." && pwd -P)
launcher="$macos_dir/run-qemu-gpu.sh"
runtime_builder="$macos_dir/build-qemu-gpu-runtime.sh"
patch_file="$macos_dir/patches/qemu-virtio-gpu-mapping-entries.patch"

fail() {
  printf 'qemu-virtio-gpu-mapping.test: %s\n' "$*" >&2
  exit 1
}

# A 5K HiDPI guest's full-screen buffer exceeds upstream's 16384-entry limit,
# so the bundled QEMU must carry the raised limit, pinned and applied.
[[ -f $patch_file ]] || fail 'the virtio-gpu mapping-entries patch is missing'
grep -Fq '#define VIRTIO_GPU_MAX_MAPPING_ENTRIES 262144' "$patch_file" || {
  fail 'the patch must raise the mapping-entry limit to 262144'
}
grep -Fq -- '-    if (nr_entries > 16384) {' "$patch_file" || {
  fail 'the patch must replace the upstream 16384 check'
}
grep -Fxq 'gpu_mapping_patch="$native_dir/patches/qemu-virtio-gpu-mapping-entries.patch"' \
  "$runtime_builder" || fail 'the runtime build must name the mapping-entries patch'
pinned=$(sed -n 's/^gpu_mapping_patch_sha256=//p' "$runtime_builder")
actual=$(shasum -a 256 "$patch_file" | cut -d' ' -f1)
[[ -n $pinned && $pinned == "$actual" ]] || {
  fail "the pinned patch hash ($pinned) does not match the patch ($actual)"
}
grep -Fxq 'patch -d "$source_dir" -p1 -f -i "$gpu_mapping_patch"' "$runtime_builder" || {
  fail 'the runtime build must apply the mapping-entries patch'
}

# QEMU's stdout and stderr are discarded; guest-caused device errors must reach
# a log file, rotated like the console log.
qemu_arguments=$(sed -n '/^qemu_args=(/,/^)/p' "$launcher")
[[ -n $qemu_arguments ]] || fail 'could not find the QEMU argument list'
grep -Fxq '  -d guest_errors' <<<"$qemu_arguments" || {
  fail 'the launcher must enable QEMU guest-error logging'
}
grep -Fxq '  -D "$guest_error_log"' <<<"$qemu_arguments" || {
  fail 'the launcher must write guest errors to the guest-error log'
}
grep -Fxq 'guest_error_log="${console_log%/*}/qemu-guest-errors.log"' "$launcher" || {
  fail 'the guest-error log must sit beside the console log'
}

printf 'qemu-virtio-gpu-mapping.test: virtio-gpu mapping limit and guest-error log: PASS\n'
