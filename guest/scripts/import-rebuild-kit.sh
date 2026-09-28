#!/bin/bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: import-rebuild-kit.sh [--from DIR]

Copies the live Try Omarchy backup/restore kit from DIR into the vendored
guest sources and refreshes the pinned digests and version in guest/spec.json.
USAGE
}

fail() {
  echo "import-rebuild-kit: $*" >&2
  exit 1
}

from="$HOME/Downloads/linux-share/omarchy-rebuild"

while (($#)); do
  case "$1" in
    --from)
      from=${2:-}
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

script_dir=$(cd "$(dirname "$0")" && pwd)
guest_dir=$(cd "$script_dir/.." && pwd)
vendor_dir="$guest_dir/vendor/rebuild-kit"
spec="$guest_dir/spec.json"

[[ -d $from ]] || fail "source directory not found: $from"
[[ -f $spec ]] || fail "spec not found: $spec"

for relative in bin/try-omarchy bin/try-omarchy.d/backup bin/try-omarchy.d/restore bin/try-omarchy.d/repack README.md; do
  [[ -f $from/$relative ]] || fail "source is missing $relative: $from"
done

install -d -m 0755 "$vendor_dir/try-omarchy.d"
install -m 0755 "$from/bin/try-omarchy" "$vendor_dir/try-omarchy"
install -m 0755 "$from/bin/try-omarchy.d/backup" "$vendor_dir/try-omarchy.d/backup"
install -m 0755 "$from/bin/try-omarchy.d/restore" "$vendor_dir/try-omarchy.d/restore"
install -m 0755 "$from/bin/try-omarchy.d/repack" "$vendor_dir/try-omarchy.d/repack"
install -m 0644 "$from/README.md" "$vendor_dir/README.md"

python3 - "$spec" "$from" "$vendor_dir" <<'PY'
import datetime
import hashlib
import json
import pathlib
import sys

spec_path = pathlib.Path(sys.argv[1])
source = pathlib.Path(sys.argv[2])
vendor = pathlib.Path(sys.argv[3])
spec = json.loads(spec_path.read_text())
component = spec["supplyChain"]["rebuildKit"]

sources = {
    "README.md": "README.md",
    "try-omarchy": "bin/try-omarchy",
    "try-omarchy.d/backup": "bin/try-omarchy.d/backup",
    "try-omarchy.d/repack": "bin/try-omarchy.d/repack",
    "try-omarchy.d/restore": "bin/try-omarchy.d/restore",
}

files = {}
newest = 0
for name, relative in sources.items():
    path = vendor / name
    files[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    newest = max(newest, int((source / relative).stat().st_mtime))

version = datetime.datetime.fromtimestamp(newest).strftime("%Y.%m.%d")
old_files = dict(component.get("files", {}))
old_version = component.get("version")
component["version"] = version
component["files"] = files
spec_path.write_text(json.dumps(spec, indent=2) + "\n")

for name in files:
    if old_files.get(name) != files[name]:
        print(f"updated {name}: {old_files.get(name, 'none')} -> {files[name]}")
if old_version != version:
    print(f"updated version: {old_version} -> {version}")
print(f"imported rebuild kit {version} from {source}")
PY
