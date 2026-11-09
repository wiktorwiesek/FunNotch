#!/bin/bash
#
# Type-checks every source file without writing anything to build/, so it can
# run while other edits are in flight. Pass a pattern to see only the errors
# in matching files:   Tools/typecheck.sh Palette
#
set -uo pipefail
cd "$(dirname "$0")/.."

"$(dirname "$0")/fetch-sparkle.sh" >/dev/null

FRAMEWORKS=(
  AppKit SwiftUI Combine Foundation ApplicationServices
  AVFoundation AudioToolbox CoreAudio CoreLocation CoreMedia CoreImage CoreGraphics
  CoreWLAN EventKit IOBluetooth IOKit Quartz QuartzCore ServiceManagement
  QuickLookThumbnailing UniformTypeIdentifiers UserNotifications Vision
)
FLAGS=()
for fw in "${FRAMEWORKS[@]}"; do FLAGS+=(-framework "$fw"); done

output=$(xcrun swiftc -typecheck \
  -target "$(uname -m)-apple-macos14.0" \
  -swift-version 5 -parse-as-library -module-name FunNotch \
  "${FLAGS[@]}" -F Vendor -framework Sparkle \
  $(find Sources -name '*.swift' | sort) 2>&1 | grep -E 'error:')

if [ -n "${1:-}" ]; then
  output=$(printf '%s\n' "$output" | grep -E "$1")
fi
if [ -z "$output" ]; then
  echo "OK: no errors${1:+ matching $1}"
else
  printf '%s\n' "$output" | sort -u
  exit 1
fi
