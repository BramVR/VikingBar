#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$PWD/.build/ci-tools/bin:$PATH"
mkdir -p .build/ci-logs
for gate in check workflow-check smoke-package; do
    make "$gate" 2>&1 | tee ".build/ci-logs/$gate.log"
done
