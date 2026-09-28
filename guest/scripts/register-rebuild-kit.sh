#!/bin/bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: register-rebuild-kit.sh --root ROOT --work WORK --spec SPEC --pacman-config CONFIG

Stages the vendored Try Omarchy backup/restore kit as a local Arch package and
installs it into the guest's immutable repository. The kit installs
`try-omarchy` to /usr/bin and its subcommands to /usr/lib/try-omarchy-rebuild-kit.
USAGE
}

fail() {
  echo "register-rebuild-kit: $*" >&2
  exit 1
}

root=""
work=""
spec=""
pacman_config=""

while (($#)); do
  case "$1" in
    --root)
      root=${2:-}
      shift 2
      ;;
    --work)
      work=${2:-}
      shift 2
      ;;
    --spec)
      spec=${2:-}
      shift 2
      ;;
    --pacman-config)
      pacman_config=${2:-}
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

[[ $root == /* && -d $root ]] || fail "--root must be an absolute staged root"
case "$root" in
  /|/bin|/boot|/etc|/home|/opt|/root|/usr|/var)
    fail "refusing unsafe root: $root"
    ;;
esac
[[ $work == /* && -d $work ]] || fail "--work must be an absolute directory"
[[ -f $spec ]] || fail "spec not found: $spec"
[[ -f $pacman_config ]] || fail "pacman config not found: $pacman_config"
for command in install pacman python3 sha256sum tar zstd; do
  command -v "$command" >/dev/null || fail "$command is required"
done

script_dir=$(cd "$(dirname "$0")" && pwd)
guest_dir=$(cd "$script_dir/.." && pwd)

mapfile -t metadata < <(python3 - "$spec" <<'PY'
import json
import pathlib
import sys

spec = json.loads(pathlib.Path(sys.argv[1]).read_text())
component = spec.get("supplyChain", {}).get("rebuildKit")
if component is None:
    print("disabled")
    raise SystemExit
print("enabled")
files = component["files"]
expected = {
    "README.md",
    "try-omarchy",
    "try-omarchy.d/backup",
    "try-omarchy.d/repack",
    "try-omarchy.d/restore",
}
if set(files) != expected:
    raise SystemExit("unexpected rebuild kit file set")
print(component["version"])
print(component["pkgrel"])
print(component["source"])
print(component["license"])
for name in (
    "README.md",
    "try-omarchy",
    "try-omarchy.d/backup",
    "try-omarchy.d/repack",
    "try-omarchy.d/restore",
):
    print(files[name])
print(spec["image"]["sourceDateEpoch"])
PY
) || fail "could not read vendored rebuild kit metadata"
[[ ${metadata[0]:-} == disabled ]] && exit 0
[[ ${metadata[0]:-} == enabled ]] || fail "invalid rebuild kit state"
(( ${#metadata[@]} == 11 )) || fail "rebuild kit metadata is incomplete"
version=${metadata[1]}
pkgrel=${metadata[2]}
source=${metadata[3]}
license=${metadata[4]}
readme_sha256=${metadata[5]}
try_omarchy_sha256=${metadata[6]}
backup_sha256=${metadata[7]}
repack_sha256=${metadata[8]}
restore_sha256=${metadata[9]}
source_date_epoch=${metadata[10]}

[[ $version =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}$ ]] || fail "invalid rebuild kit version: $version"
[[ $pkgrel =~ ^[0-9]+$ ]] || fail "invalid rebuild kit pkgrel: $pkgrel"
[[ $source == vendor/rebuild-kit ]] || fail "unexpected rebuild kit source: $source"
[[ $license == custom:personal ]] || fail "unexpected rebuild kit license: $license"
for digest in "$readme_sha256" "$try_omarchy_sha256" "$backup_sha256" "$repack_sha256" "$restore_sha256"; do
  [[ $digest =~ ^[0-9a-f]{64}$ ]] || fail "invalid rebuild kit digest"
done
[[ $source_date_epoch =~ ^[0-9]+$ ]] || fail "invalid source date epoch"

source_dir="$guest_dir/$source"
[[ -d $source_dir && ! -L $source_dir ]] || fail "vendored rebuild kit directory is missing"

verify_file() {
  local expected=$1
  local path=$2
  printf '%s  %s\n' "$expected" "$path" | sha256sum -c - >/dev/null
}

verify_vendored() {
  local relative=$1
  local expected=$2
  local path="$source_dir/$relative"
  [[ ! -L $path ]] || fail "refusing symlinked vendored file: $relative"
  [[ -f $path ]] || fail "vendored rebuild kit file is missing: $relative"
  verify_file "$expected" "$path" || fail "vendored rebuild kit digest mismatch: $relative"
}

verify_vendored README.md "$readme_sha256"
verify_vendored try-omarchy "$try_omarchy_sha256"
verify_vendored try-omarchy.d/backup "$backup_sha256"
verify_vendored try-omarchy.d/repack "$repack_sha256"
verify_vendored try-omarchy.d/restore "$restore_sha256"

package_name=try-omarchy-rebuild-kit
package_version="$version-$pkgrel"
stage=$(mktemp -d "$work/rebuild-kit-package.XXXXXX")
cleanup() {
  rm -rf "$stage"
}
trap cleanup EXIT

install -Dm0755 "$source_dir/try-omarchy" "$stage/usr/bin/try-omarchy"
install -Dm0755 "$source_dir/try-omarchy.d/backup" "$stage/usr/lib/try-omarchy-rebuild-kit/backup"
install -Dm0755 "$source_dir/try-omarchy.d/repack" "$stage/usr/lib/try-omarchy-rebuild-kit/repack"
install -Dm0755 "$source_dir/try-omarchy.d/restore" "$stage/usr/lib/try-omarchy-rebuild-kit/restore"
install -Dm0644 "$source_dir/README.md" "$stage/usr/share/doc/$package_name/README.md"

installed_size=$(du -sb "$stage/usr" | awk '{print $1}')
cat >"$stage/.PKGINFO" <<EOF
pkgname = $package_name
pkgbase = $package_name
pkgver = $package_version
pkgdesc = Try Omarchy backup/restore kit: try-omarchy --backup / --restore / --repack
url = https://github.com/digital-brew/try-omarchy
builddate = $source_date_epoch
packager = Try Omarchy reproducible guest builder
size = $installed_size
arch = any
license = custom:personal
depend = bash
depend = python
depend = zstd
depend = libarchive
optdepend = python-yaml: export and import Lerd site databases
optdepend = lerd: Lerd database steps
optdepend = flatpak: restore Flathub apps
EOF

package_archive="$stage/$package_name-$package_version-any.pkg.tar.zst"
tar \
  --sort=name \
  --mtime="@$source_date_epoch" \
  --owner=0 \
  --group=0 \
  --numeric-owner \
  --format=gnu \
  -C "$stage" \
  -cf - .PKGINFO usr |
  zstd --force --quiet -12 --threads=1 -o "$package_archive"

pacman \
  --noconfirm \
  --config "$pacman_config" \
  --root "$root" \
  --dbpath "$root/var/lib/pacman" \
  --logfile "$root/var/log/pacman.log" \
  -U "$package_archive"

query=$(pacman --config "$pacman_config" --root "$root" --dbpath "$root/var/lib/pacman" -Q "$package_name")
[[ $query == "$package_name $package_version" ]] || fail "provider query returned: $query"
pacman --config "$pacman_config" --root "$root" --dbpath "$root/var/lib/pacman" -Qkk "$package_name" >/dev/null ||
  fail "installed rebuild kit package failed its ownership check"
verify_file "$try_omarchy_sha256" "$root/usr/bin/try-omarchy" || fail "installed try-omarchy digest mismatch"

repo_dir="$root/usr/share/try-omarchy/repo"
install -d -m 0755 "$repo_dir"
install -m 0644 "$package_archive" "$repo_dir/$(basename "$package_archive")"
echo "Registered try-omarchy-rebuild-kit $package_version from vendored kit"
