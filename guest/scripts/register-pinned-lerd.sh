#!/bin/bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: register-pinned-lerd.sh --root ROOT --work WORK --spec SPEC --pacman-config CONFIG

Downloads the spec-pinned official Lerd ARM64 release and license, verifies
their digests and exact archive shape, then installs lerd as a local Arch
package staged in the guest's immutable repository. Lerd's per-user setup
(`lerd install`) still runs on first use; only the binary is preinstalled.
USAGE
}

fail() {
  echo "register-pinned-lerd: $*" >&2
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
for command in arch-chroot curl install pacman python3 sha256sum tar zstd; do
  command -v "$command" >/dev/null || fail "$command is required"
done

mapfile -t metadata < <(python3 - "$spec" <<'PY'
import json
import pathlib
import sys

spec = json.loads(pathlib.Path(sys.argv[1]).read_text())
component = spec.get("supplyChain", {}).get("lerd")
if component is None:
    print("disabled")
    raise SystemExit
print("enabled")
for key in (
    "version",
    "commit",
    "repository",
    "url",
    "sha256",
    "binarySha256",
    "reportedVersion",
    "license",
    "licenseUrl",
    "licenseSha256",
):
    print(component[key])
print(spec["image"]["architecture"])
print(spec["image"]["sourceDateEpoch"])
PY
) || fail "could not read pinned lerd metadata"
[[ ${metadata[0]:-} == disabled ]] && exit 0
[[ ${metadata[0]:-} == enabled ]] || fail "invalid pinned lerd state"
(( ${#metadata[@]} == 13 )) || fail "pinned lerd metadata is incomplete"
version=${metadata[1]}
commit=${metadata[2]}
repository=${metadata[3]}
url=${metadata[4]}
sha256=${metadata[5]}
binary_sha256=${metadata[6]}
reported_version=${metadata[7]}
license=${metadata[8]}
license_url=${metadata[9]}
license_sha256=${metadata[10]}
architecture=${metadata[11]}
source_date_epoch=${metadata[12]}

[[ $architecture == aarch64 ]] || fail "pinned lerd component supports only aarch64"
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid lerd version: $version"
[[ $commit =~ ^[0-9a-f]{40}$ ]] || fail "invalid lerd commit"
[[ $repository == https://github.com/lerd-env/lerd ]] || fail "unexpected lerd repository"
[[ $sha256 =~ ^[0-9a-f]{64}$ ]] || fail "invalid lerd archive digest"
[[ $binary_sha256 =~ ^[0-9a-f]{64}$ ]] || fail "invalid lerd binary digest"
[[ $reported_version == "lerd version $version (commit $commit, built "*")" ]] || fail "invalid lerd reported version"
[[ $license == MIT ]] || fail "unexpected lerd license: $license"
[[ $license_sha256 =~ ^[0-9a-f]{64}$ ]] || fail "invalid lerd license digest"
[[ $source_date_epoch =~ ^[0-9]+$ ]] || fail "invalid source date epoch"
expected_url="$repository/releases/download/v$version/lerd_${version}_linux_arm64.tar.gz"
expected_license_url="https://raw.githubusercontent.com/lerd-env/lerd/v$version/LICENSE"
[[ $url == "$expected_url" ]] || fail "lerd URL does not match the pinned official release"
[[ $license_url == "$expected_license_url" ]] || fail "lerd license URL does not match the pinned tag"

cache_dir="$work/download-cache"
install -d -m 0755 "$cache_dir"
asset_cache="$cache_dir/lerd_${version}_linux_arm64.tar.gz"
license_cache="$cache_dir/lerd-$version.LICENSE"

verify_file() {
  local expected=$1
  local path=$2
  printf '%s  %s\n' "$expected" "$path" | sha256sum -c - >/dev/null
}

download_verified() {
  local source_url=$1
  local expected=$2
  local destination=$3
  local temporary=""

  [[ ! -L $destination ]] || fail "refusing symlinked download cache entry: $destination"
  if [[ -f $destination ]] && verify_file "$expected" "$destination"; then
    return 0
  fi
  rm -f "$destination"
  temporary=$(mktemp "$cache_dir/.download.XXXXXX")
  if ! curl --fail --location --proto '=https' --tlsv1.2 --silent --show-error \
    "$source_url" --output "$temporary"; then
    rm -f "$temporary"
    fail "download failed: $source_url"
  fi
  if ! verify_file "$expected" "$temporary"; then
    rm -f "$temporary"
    fail "download digest mismatch: $source_url"
  fi
  chmod 0644 "$temporary"
  mv "$temporary" "$destination"
}

download_verified "$url" "$sha256" "$asset_cache"
download_verified "$license_url" "$license_sha256" "$license_cache"

package_name=try-omarchy-lerd
package_version="$version-1"
stage=$(mktemp -d "$work/lerd-package.XXXXXX")
cleanup() {
  rm -rf "$stage"
}
trap cleanup EXIT

expected_members=$(printf '%s\n' LICENSE README.md THIRD-PARTY-LICENSES.md install.sh lerd)
actual_members=$(tar -tzf "$asset_cache" | LC_ALL=C sort)
[[ $actual_members == "$expected_members" ]] || fail "lerd archive has an unexpected member set"

install -d -m 0755 "$stage/extracted"
tar -xzf "$asset_cache" --no-same-owner -C "$stage/extracted"
verify_file "$binary_sha256" "$stage/extracted/lerd" || fail "extracted lerd binary digest mismatch"

install -Dm0755 "$stage/extracted/lerd" "$stage/usr/bin/lerd"
install -Dm0644 "$stage/extracted/README.md" "$stage/usr/share/doc/$package_name/README.md"
install -Dm0644 "$license_cache" "$stage/usr/share/licenses/$package_name/LICENSE"
install -Dm0644 "$stage/extracted/THIRD-PARTY-LICENSES.md" "$stage/usr/share/licenses/$package_name/THIRD-PARTY-LICENSES.md"

installed_size=$(du -sb "$stage/usr" | awk '{print $1}')
cat >"$stage/.PKGINFO" <<EOF
pkgname = $package_name
pkgbase = $package_name
pkgver = $package_version
pkgdesc = Pinned official Lerd $version binary (Herd-like PHP development environment) for the Omarchy ARM64 guest
url = $repository
builddate = $source_date_epoch
packager = Try Omarchy reproducible guest builder
size = $installed_size
arch = aarch64
license = MIT
provides = lerd=$version
conflict = lerd
depend = podman
depend = passt
depend = fuse-overlayfs
EOF

package_archive="$stage/$package_name-$package_version-aarch64.pkg.tar.zst"
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
  fail "installed lerd package failed its ownership check"
pacman --config "$pacman_config" --root "$root" --dbpath "$root/var/lib/pacman" -T lerd >/dev/null ||
  fail "installed lerd package does not satisfy the lerd dependency"
verify_file "$binary_sha256" "$root/usr/bin/lerd" || fail "installed lerd binary digest mismatch"
reported=$(arch-chroot "$root" /usr/bin/lerd --version)
[[ $reported == "$reported_version" ]] || fail "lerd reported an unexpected identity: $reported"

repo_dir="$root/usr/share/try-omarchy/repo"
install -d -m 0755 "$repo_dir"
install -m 0644 "$package_archive" "$repo_dir/$(basename "$package_archive")"
echo "Registered $query from verified official release $sha256"
