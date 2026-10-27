#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
SDK26=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
[ -d "$SDK26" ] && export SDKROOT="$SDK26"
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
PL=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
export MULTITUL_NO_LOG=1
export MULTITUL_VPS_ADDRESS=203.0.113.10
exec swift test -Xswiftc -plugin-path -Xswiftc $PL -Xswiftc -F$F -Xlinker -F$F -Xlinker -rpath -Xlinker $F \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib "$@"
