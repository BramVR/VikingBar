#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 Scripts/package-artifacts.py --app-only --configuration "${CONFIGURATION:-debug}" \
  --output "${VIKINGBAR_APP_OUTPUT:-$PWD/.build/app/VikingBar.app}"
