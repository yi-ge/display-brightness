#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
version=2.10.1
archive_sha256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
dependency_dir="$root/build/dependencies"
destination="$dependency_dir/Sparkle-$version"

if [[ ! -d "$destination" ]]; then
    mkdir -p "$dependency_dir"
    staging="$(mktemp -d "$dependency_dir/.sparkle.XXXXXXXX")"
    trap '/usr/bin/find "$staging" -depth -delete' EXIT
    /usr/bin/curl --fail --silent --show-error --location --retry 3 --proto '=https' \
        "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" \
        --output "$staging/Sparkle.tar.xz"
    printf '%s  %s\n' "$archive_sha256" "$staging/Sparkle.tar.xz" | /usr/bin/shasum -a 256 -c >&2
    mkdir "$staging/distribution"
    /usr/bin/tar -xJf "$staging/Sparkle.tar.xz" -C "$staging/distribution"
    mv "$staging/distribution" "$destination"
fi

test -d "$destination/Sparkle.framework"
test -x "$destination/bin/generate_appcast"
printf '%s\n' "$destination"
