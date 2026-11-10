#!/bin/bash
# Fetches SwiftTerm into Vendor/ and builds it as a static library, once per
# architecture, if that is not already done.
#
#   Tools/fetch-swiftterm.sh arm64 [x86_64]
#
# SwiftTerm (MIT, Miguel de Icaza) is the terminal emulator behind the
# terminal that drops from the notch. It is downloaded rather than committed,
# like Sparkle: 23,000 lines of somebody else's code have no place in this
# repository's history. The version and checksum are pinned, and a mismatch is
# a hard failure, because this code is compiled into the app.
#
# 1.10.1 is the last release that is plain Swift sources: later ones need a
# SwiftPM build plugin and ship a Metal shader as a bundle resource, neither of
# which a build made of one swiftc call can provide.
set -euo pipefail

SWIFTTERM_VERSION="1.10.1"
SWIFTTERM_SHA256="2759241551aead2aeda793ea349578954b8e9275f6694e837bb4a8603083c68a"
MIN_MACOS="${MIN_MACOS:-14.0}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/Vendor/SwiftTerm"
STAMP="$DEST/.version"

[ $# -gt 0 ] || { echo "usage: $0 <arch>..." >&2; exit 1; }

missing=()
for arch in "$@"; do
  if [ "$(cat "$STAMP" 2>/dev/null)" != "$SWIFTTERM_VERSION" ] \
    || [ ! -f "$DEST/$arch/libSwiftTerm.a" ] || [ ! -f "$DEST/$arch/SwiftTerm.swiftmodule" ]; then
    missing+=("$arch")
  fi
done
[ ${#missing[@]} -gt 0 ] || exit 0

echo "==> Fetching SwiftTerm $SWIFTTERM_VERSION"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

URL="https://github.com/migueldeicaza/SwiftTerm/archive/refs/tags/v${SWIFTTERM_VERSION}.tar.gz"
curl -fsSL "$URL" -o "$TMP/swiftterm.tar.gz"

ACTUAL="$(shasum -a 256 "$TMP/swiftterm.tar.gz" | cut -d' ' -f1)"
if [ "$ACTUAL" != "$SWIFTTERM_SHA256" ]; then
  echo "ERROR: SwiftTerm checksum mismatch." >&2
  echo "  expected $SWIFTTERM_SHA256" >&2
  echo "  got      $ACTUAL" >&2
  exit 1
fi

tar xzf "$TMP/swiftterm.tar.gz" -C "$TMP"
SRC="$TMP/SwiftTerm-${SWIFTTERM_VERSION}"

# A stamp for another version means the libraries beside it are that version's.
if [ "$(cat "$STAMP" 2>/dev/null)" != "$SWIFTTERM_VERSION" ]; then
  rm -rf "$DEST"
fi
mkdir -p "$DEST"
cp "$SRC/LICENSE" "$DEST/LICENSE"

for arch in "${missing[@]}"; do
  echo "==> Building SwiftTerm ($arch)"
  mkdir -p "$DEST/$arch"
  # shellcheck disable=SC2046
  xcrun swiftc \
    -target "${arch}-apple-macos${MIN_MACOS}" \
    -O -whole-module-optimization -suppress-warnings \
    -swift-version 5 \
    -parse-as-library \
    -module-name SwiftTerm \
    -emit-module -emit-module-path "$DEST/$arch/SwiftTerm.swiftmodule" \
    -emit-library -static -o "$DEST/$arch/libSwiftTerm.a" \
    $(find "$SRC/Sources/SwiftTerm" -name '*.swift' | sort)
done

printf '%s' "$SWIFTTERM_VERSION" > "$STAMP"
echo "==> SwiftTerm $SWIFTTERM_VERSION ready in Vendor/SwiftTerm"
