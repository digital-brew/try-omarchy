#!/bin/bash
# Contract tests for the QEMU command-line sanity check the launcher runs.
set -euo pipefail

macos_dir=$(cd "$(dirname "$0")/.." && pwd)
lint="$macos_dir/qemu-args-lint.sh"

fail() {
  echo "qemu-args-lint.test: $*" >&2
  exit 1
}

expect_rejects() {
  local pattern=$1
  shift
  local output
  if output=$(/bin/bash "$lint" "$@" 2>&1); then
    fail "accepted a command line that must be rejected ($pattern)"
  fi
  [[ $output == *"$pattern"* ]] || fail "expected '$pattern' in: $output"
}

good=(
  -name 'Try Omarchy'
  -audiodev 'sdl,id=omarchy-audio,timer-period=1000'
  -device 'intel-hda,id=omarchy-hda'
  -netdev 'user,id=omarchy-net'
  -device 'virtio-net-pci,id=omarchy-nic,netdev=omarchy-net,mac=52:54:00:00:00:01,romfile='
  -chardev 'socket,id=omarchy-camera,path=/tmp/camera.sock'
  -device 'virtserialport,bus=omarchy-serial.0,nr=4,chardev=omarchy-camera,name=dev.tryomarchy.camera'
  -drive 'if=none,id=omarchy-disk,file=/tmp/disk.raw,format=raw'
)
/bin/bash "$lint" "${good[@]}" || fail "rejected a well-formed command line"

expect_rejects "duplicate QEMU id 'omarchy-nic'" "${good[@]}" \
  -device 'virtio-net-pci,id=omarchy-nic,netdev=omarchy-net,romfile='
expect_rejects "duplicate QEMU id 'omarchy-camera'" "${good[@]}" \
  -chardev 'socket,id=omarchy-camera,path=/tmp/other.sock'
expect_rejects "exactly one -audiodev, found 2" "${good[@]}" -audiodev 'sdl,id=omarchy-audio-2'
expect_rejects "exactly one -audiodev, found 0" "${good[@]:4}"
expect_rejects "exactly one virtio-net device, found 2" "${good[@]}" \
  -device 'virtio-net-pci,id=omarchy-nic-2,netdev=omarchy-net'
expect_rejects "no QEMU arguments"

echo "qemu-args-lint.test: ok"
