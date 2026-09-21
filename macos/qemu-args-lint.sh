#!/bin/bash
# Sanity checks over an assembled QEMU command line, run by run-qemu-gpu.sh
# just before it starts QEMU and by the launcher contract tests.
#
# QEMU reports a duplicated backend or device id only after the window has
# opened, as a QMP failure that the app surfaces as "QMP socket closed". Merge
# resolutions have produced exactly that twice, so refuse such a command line
# here with a message that names the offending argument instead.
#
# Usage: qemu-args-lint.sh QEMU_ARG...
set -euo pipefail

fail() {
  echo "qemu-args-lint: $*" >&2
  exit 1
}

(($#)) || fail "no QEMU arguments to check"

# /bin/bash on macOS is 3.2, without associative arrays: keep the ids seen so
# far as "id<TAB>argument" lines instead.
seen_ids=""
audiodev_count=0
network_device_count=0
previous=""
for argument in "$@"; do
  case "$previous" in
    -audiodev) ((audiodev_count += 1)) ;;
  esac
  case "$previous" in
    -audiodev|-blockdev|-chardev|-device|-drive|-netdev|-object)
      if [[ $argument == *virtio-net-* ]]; then
        ((network_device_count += 1))
      fi
      id=""
      IFS=',' read -r -a properties <<<"$argument"
      for property in "${properties[@]}"; do
        [[ $property == id=* ]] || continue
        id=${property#id=}
      done
      if [[ -n $id ]]; then
        earlier=$(printf '%s' "$seen_ids" | awk -F'\t' -v id="$id" '$1 == id { print $2; exit }')
        [[ -z $earlier ]] ||
          fail "duplicate QEMU id '$id': '$earlier' and '$previous $argument'"
        seen_ids+="$id	$previous $argument"$'\n'
      fi
      ;;
  esac
  previous=$argument
done

((audiodev_count == 1)) || fail "expected exactly one -audiodev, found $audiodev_count"
((network_device_count == 1)) || fail "expected exactly one virtio-net device, found $network_device_count"
