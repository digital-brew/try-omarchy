#!/bin/bash

# Rebuild hyprtoolkit 0.5.4 from the reviewed Arch PKGBUILD and upstream tarball
# against the pinned aquamarine 0.14 (libaquamarine.so=13). ALARM rebuilt its
# hyprtoolkit against libaquamarine.so=14, which the pinned Hyprland cannot
# load. The resulting unsigned package is served only through the disposable
# builder [try-omarchy-abi-pins] repo alongside the aquamarine rebuild.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: build-pinned-hyprtoolkit.sh --spec FILE --guest-dir DIR --output-repo DIR --abi-repo DIR [--work DIR]
USAGE
}

fail() {
  echo "build-pinned-hyprtoolkit: $*" >&2
  exit 1
}

spec=""
guest_dir=""
output_repo=""
abi_repo=""
work=""

while (($#)); do
  case "$1" in
    --spec)
      spec=${2:-}
      shift 2
      ;;
    --guest-dir)
      guest_dir=${2:-}
      shift 2
      ;;
    --output-repo)
      output_repo=${2:-}
      shift 2
      ;;
    --work)
      work=${2:-}
      shift 2
      ;;
    --abi-repo)
      abi_repo=${2:-}
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

[[ -f $spec ]] || fail "spec not found: $spec"
[[ -d $guest_dir ]] || fail "guest directory not found: $guest_dir"
[[ -n $output_repo ]] || fail "--output-repo is required"
[[ -d $abi_repo ]] || fail "--abi-repo must be the directory holding the rebuilt aquamarine package"
[[ $(uname -s) == Linux && $(uname -m) == aarch64 ]] \
  || fail "hyprtoolkit must be built natively on aarch64 Linux"
(( EUID == 0 )) || fail "run as root so build dependencies can be installed"
for command in curl install makepkg pacman python3 repo-add runuser sha256sum tar useradd zstd; do
  command -v "$command" >/dev/null || fail "$command is required"
done

mapfile -t metadata < <(python3 - "$spec" "$guest_dir" <<'PY'
import json
import pathlib
import sys

spec = json.loads(pathlib.Path(sys.argv[1]).read_text())
guest = pathlib.Path(sys.argv[2]).resolve(strict=True)
pins = spec.get("inputs", {}).get("abiPackagePins")
if pins != [
    {"name": "aquamarine", "version": "0.14.0-2"},
    {"name": "hyprtoolkit", "version": "0.5.4-4"},
]:
    raise SystemExit("abiPackagePins must be exactly hyprtoolkit 0.14.0-2 and hyprtoolkit 0.5.4-4")
component = spec["supplyChain"]["hyprtoolkit"]
required = (
    "version",
    "pkgrel",
    "repository",
    "url",
    "sha256",
    "pkgbuild",
    "pkgbuildSha256",
    "packagingRepository",
    "packagingCommit",
    "license",
    "binarySha256",
)
if set(component) != set(required):
    raise SystemExit("supplyChain.hyprtoolkit keys are not the reviewed set")
pkgbuild = pathlib.PurePosixPath(component["pkgbuild"])
if pkgbuild.is_absolute() or any(part in {"", ".", ".."} for part in pkgbuild.parts):
    raise SystemExit("hyprtoolkit PKGBUILD path escapes the guest directory")
candidate = (guest / pathlib.Path(*pkgbuild.parts)).resolve(strict=True)
if candidate == guest or guest not in candidate.parents or not candidate.is_file():
    raise SystemExit("hyprtoolkit PKGBUILD path is invalid")
print(component["version"])
print(component["pkgrel"])
print(component["repository"])
print(component["url"])
print(component["sha256"])
print(candidate)
print(component["pkgbuildSha256"])
print(component["packagingRepository"])
print(component["packagingCommit"])
print(component["license"])
print(component["binarySha256"])
print(spec["image"]["sourceDateEpoch"])
PY
) || fail "could not read pinned hyprtoolkit metadata"
(( ${#metadata[@]} == 12 )) || fail "pinned hyprtoolkit metadata is incomplete"

version=${metadata[0]}
pkgrel=${metadata[1]}
repository=${metadata[2]}
url=${metadata[3]}
sha256=${metadata[4]}
pkgbuild_path=${metadata[5]}
pkgbuild_sha256=${metadata[6]}
packaging_repository=${metadata[7]}
packaging_commit=${metadata[8]}
license=${metadata[9]}
binary_sha256=${metadata[10]}
source_date_epoch=${metadata[11]}

[[ $version == 0.5.4 ]] || fail "unexpected hyprtoolkit version: $version"
[[ $pkgrel == 4 ]] || fail "unexpected hyprtoolkit pkgrel: $pkgrel"
[[ $repository == https://github.com/hyprwm/hyprtoolkit ]] || fail "unexpected hyprtoolkit repository"
[[ $url == "$repository/archive/v$version/hyprtoolkit-$version.tar.gz" ]] ||
  fail "hyprtoolkit URL does not match the pinned release"
[[ $packaging_repository == https://gitlab.archlinux.org/archlinux/packaging/packages/hyprtoolkit.git ]] ||
  fail "unexpected hyprtoolkit packaging repository"
[[ $packaging_commit =~ ^[0-9a-f]{40}$ ]] || fail "invalid hyprtoolkit packaging commit"
[[ $license == BSD-3-Clause ]] || fail "unexpected hyprtoolkit license: $license"
[[ $source_date_epoch =~ ^[0-9]+$ && $source_date_epoch -gt 0 ]] || fail "invalid source date epoch"
for digest in "$sha256" "$pkgbuild_sha256" "$binary_sha256"; do
  [[ $digest =~ ^[0-9a-f]{64}$ ]] || fail "invalid hyprtoolkit content digest"
done
[[ ! -L $pkgbuild_path ]] || fail "refusing symlinked hyprtoolkit PKGBUILD"

verify_file() {
  local expected=$1
  local path=$2
  printf '%s  %s\n' "$expected" "$path" | sha256sum -c - >/dev/null
}

verify_file "$pkgbuild_sha256" "$pkgbuild_path" || fail "hyprtoolkit PKGBUILD digest mismatch"
grep -F "sha256sums=('$sha256')" "$pkgbuild_path" >/dev/null ||
  fail "hyprtoolkit PKGBUILD does not pin the reviewed source digest"
grep -F "pkgver=$version" "$pkgbuild_path" >/dev/null || fail "hyprtoolkit PKGBUILD version mismatch"
grep -F "pkgrel=$pkgrel" "$pkgbuild_path" >/dev/null || fail "hyprtoolkit PKGBUILD pkgrel mismatch"

if [[ -z $work ]]; then
  work=$(mktemp -d)
  cleanup_work=1
else
  [[ $work == /* && -d $work ]] || fail "--work must be an absolute directory"
  cleanup_work=0
fi
cache_dir="$work/hyprtoolkit-download-cache"
# The build path leaks into the compiled library, so a randomized mktemp stage
# would make every rebuild produce a different digest. Use one fixed, absolute
# stage path that is identical in the resolve and factory paths, and keep it
# traversable (0755) for the unprivileged makepkg user created below.
stage=/var/tmp/try-omarchy-hyprtoolkit-stage
rm -rf -- "$stage"
install -d -m 0755 "$stage"
cleanup() {
  if [[ -n ${stage:-} && -d $stage && $stage == /var/tmp/try-omarchy-hyprtoolkit-stage ]]; then
    rm -rf -- "$stage"
  fi
  if (( cleanup_work )) && [[ -n $work && -d $work ]]; then
    rm -rf -- "$work"
  fi
}
trap cleanup EXIT

install -d -m 0755 "$cache_dir"
source_cache="$cache_dir/hyprtoolkit-$version.tar.gz"

download_verified() {
  local source_url=$1
  local expected=$2
  local destination=$3
  local temporary=""

  [[ ! -L $destination ]] || fail "refusing symlinked download cache entry: $destination"
  if [[ -f $destination ]] && verify_file "$expected" "$destination"; then
    return 0
  fi
  rm -f -- "$destination"
  temporary=$(mktemp "$cache_dir/.download.XXXXXX")
  if ! curl --fail --location --proto '=https' --tlsv1.2 --silent --show-error \
    "$source_url" --output "$temporary"; then
    rm -f -- "$temporary"
    fail "download failed: $source_url"
  fi
  if ! verify_file "$expected" "$temporary"; then
    rm -f -- "$temporary"
    fail "download digest mismatch: $source_url"
  fi
  chmod 0644 "$temporary"
  mv "$temporary" "$destination"
}

download_verified "$url" "$sha256" "$source_cache"

python3 - "$source_cache" "hyprtoolkit-$version" <<'PY' || fail "hyprtoolkit source archive has an unsafe member set"
import pathlib
import sys
import tarfile

archive = pathlib.Path(sys.argv[1])
expected_root = sys.argv[2]
with tarfile.open(archive, "r:gz") as source:
    members = source.getmembers()
    if not members:
        raise SystemExit("hyprtoolkit source archive is empty")
    for member in members:
        name = member.name[:-1] if member.isdir() and member.name.endswith("/") else member.name
        if not name or name.startswith("/") or ".." in pathlib.PurePosixPath(name).parts:
            raise SystemExit(f"unsafe hyprtoolkit source member: {member.name}")
    roots = {pathlib.PurePosixPath(member.name).parts[0] for member in members if member.name}
    if roots != {expected_root}:
        raise SystemExit("hyprtoolkit source archive has an unexpected member set")
PY

# Build against the rebuilt aquamarine 0.14 rather than the mirror's 0.15.
aquamarine_archives=("$abi_repo"/aquamarine-0.14.0-2-*.pkg.tar.zst)
(( ${#aquamarine_archives[@]} == 1 )) && [[ -f ${aquamarine_archives[0]} ]] ||
  fail "expected exactly one rebuilt aquamarine 0.14.0-2 archive in $abi_repo"
pacman -U --needed --noconfirm "${aquamarine_archives[0]}" >/dev/null
[[ $(pacman -Q aquamarine) == "aquamarine 0.14.0-2" ]] || fail "rebuilt aquamarine 0.14.0-2 is not installed"
pacman -S --needed --noconfirm \
  base-devel cmake cairo glib2 hyprgraphics hyprlang hyprutils iniparser libdrm \
  libglvnd libxkbcommon mesa pango pixman wayland \
  >/dev/null
[[ $(pacman -Q aquamarine) == "aquamarine 0.14.0-2" ]] || fail "installing build dependencies replaced aquamarine 0.14.0-2"

if ! id -u hyprtoolkit-build >/dev/null 2>&1; then
  useradd --system --create-home --home-dir "$stage/home" --shell /usr/bin/nologin \
    hyprtoolkit-build
  added_build_user=1
else
  added_build_user=0
fi
build_home=$(getent passwd hyprtoolkit-build | cut -d: -f6)
build_dir="$stage/build"
install -d -m 0755 -o hyprtoolkit-build -g hyprtoolkit-build "$build_dir" "$build_home"
install -m 0644 -o hyprtoolkit-build -g hyprtoolkit-build "$pkgbuild_path" "$build_dir/PKGBUILD"
install -m 0644 -o hyprtoolkit-build -g hyprtoolkit-build "$source_cache" \
  "$build_dir/hyprtoolkit-$version.tar.gz"

export SOURCE_DATE_EPOCH="$source_date_epoch"
export PACKAGER='Try Omarchy factory <factory@try-omarchy>'
(
  cd "$build_dir"
  # Arch Linux ARM's makepkg.conf emits .pkg.tar.xz; the provenance check and
  # the abi-pin repository below expect zstd, so pin the extension explicitly.
  runuser -u hyprtoolkit-build -- env HOME="$build_home" SOURCE_DATE_EPOCH="$source_date_epoch" \
    PACKAGER="$PACKAGER" PKGEXT='.pkg.tar.zst' \
    makepkg --noconfirm --skippgpcheck
)

package_archive="$build_dir/hyprtoolkit-$version-$pkgrel-aarch64.pkg.tar.zst"
[[ -f $package_archive ]] || fail "makepkg did not produce $package_archive"

python3 - "$package_archive" "$binary_sha256" <<'PY' || fail "hyprtoolkit package provenance mismatch"
import hashlib
import io
import subprocess
import sys
import tarfile

archive = sys.argv[1]
expected = sys.argv[2]
raw = subprocess.check_output(["zstd", "-d", "-c", archive])
with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as package:
    info = package.extractfile(".PKGINFO")
    if info is None:
        raise SystemExit("hyprtoolkit package is missing .PKGINFO")
    pkginfo = info.read().decode()
    if "pkgver = 0.5.4-4" not in pkginfo or "arch = aarch64" not in pkginfo:
        raise SystemExit("hyprtoolkit package identity mismatch")
    if "provides = libhyprtoolkit.so=5-64" not in pkginfo:
        raise SystemExit("hyprtoolkit package does not provide libhyprtoolkit.so=5")
    if "depend = libaquamarine.so=13-64" not in pkginfo:
        raise SystemExit("hyprtoolkit package was not built against libaquamarine.so=13")
    libraries = [
        member
        for member in package.getmembers()
        if member.isfile() and member.name.startswith("usr/lib/libhyprtoolkit.so.")
    ]
    if len(libraries) != 1:
        raise SystemExit("hyprtoolkit package must contain exactly one libhyprtoolkit.so shared object")
    member = package.extractfile(libraries[0])
    digest = hashlib.sha256(member.read()).hexdigest()
    if digest != expected:
        raise SystemExit(f"hyprtoolkit reproducible library digest mismatch: {digest}")
PY

# The aquamarine rebuild already created this repository; add to it.
[[ $output_repo == "$abi_repo" ]] || fail "--output-repo must be the same abi pin repository as --abi-repo"
install -d -m 0755 "$output_repo"
install -m 0644 "$package_archive" "$output_repo/hyprtoolkit-$version-$pkgrel-aarch64.pkg.tar.zst"
repo-add "$output_repo/try-omarchy-abi-pins.db.tar.gz" \
  "$output_repo/hyprtoolkit-$version-$pkgrel-aarch64.pkg.tar.zst" >/dev/null

if (( added_build_user )); then
  userdel --remove hyprtoolkit-build >/dev/null 2>&1 || userdel hyprtoolkit-build >/dev/null 2>&1 || true
fi

echo "Rebuilt hyprtoolkit $version-$pkgrel from $packaging_commit (library $binary_sha256)"
