#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
developer="$(xcode-select -p)"
if [[ "$developer" == */CommandLineTools && -d "$developer/Library/Developer/Frameworks/Testing.framework" ]]; then
    frameworks="$developer/Library/Developer/Frameworks"
    swift test -Xswiftc "-F$frameworks" -Xlinker -rpath -Xlinker "$frameworks" \
        -Xlinker -rpath -Xlinker "$developer/Library/Developer/usr/lib" "$@"
else
    swift test "$@"
fi
