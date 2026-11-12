#!/usr/bin/env bash
# Linux counterpart of tools/fetch-scrcpy.ps1: downloads the pinned scrcpy release (it includes adb and
# scrcpy-server) into third_party/scrcpy-linux and verifies its SHA-256. Keep the version equal to the Windows one.
set -euo pipefail
version=v5.0.1
sha256=9f969d30cc574816077edecda65719c1c70b0aee1df1ba5fa00779ac07b8fd6e
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
dest=$root/third_party/scrcpy-linux
if [ -x "$dest/scrcpy" ] && [ -x "$dest/adb" ] && [ -f "$dest/scrcpy-server" ] && [ "$(cat "$dest/.version" 2>/dev/null)" = "$version" ]; then
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
name=scrcpy-linux-x86_64-$version
curl -fsSL -o "$tmp/$name.tar.gz" "https://github.com/Genymobile/scrcpy/releases/download/$version/$name.tar.gz"
echo "$sha256  $tmp/$name.tar.gz" | sha256sum -c - >/dev/null || { echo "scrcpy checksum mismatch." >&2; exit 1; }
tar -xzf "$tmp/$name.tar.gz" -C "$tmp"
rm -rf "$dest"
mkdir -p "$(dirname "$dest")"
mv "$tmp/$name" "$dest"
rm -f "$dest/scrcpy.1"
echo "$version" > "$dest/.version"
echo "scrcpy $version -> $dest"
