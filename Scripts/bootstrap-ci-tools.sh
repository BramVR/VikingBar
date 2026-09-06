#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)/$(uname -m)" == Darwin/arm64 ]] || { echo 'CI tools require macOS arm64' >&2; exit 1; }
tools="$PWD/.build/ci-tools"
mkdir -p "$tools/bin"
staging="$(mktemp -d "$tools/download.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
install_tool() {
    local name="$1" url="$2" checksum="$3" archive="$staging/$1.archive"
    curl --fail --location --retry 3 "$url" --output "$archive"
    echo "$checksum  $archive" | shasum -a 256 -c -
    mkdir "$staging/$name"
    case "$url" in
        *.zip) unzip -q "$archive" -d "$staging/$name" ;;
        *.tar.gz) tar -xzf "$archive" -C "$staging/$name" ;;
    esac
    install -m 755 "$staging/$name/$name" "$tools/bin/$name"
    "$tools/bin/$name" --version
}
install_tool swiftformat https://github.com/nicklockwood/SwiftFormat/releases/download/0.63.0/swiftformat.zip 28c7802e11fa5ae113d903066439c6bb1be20a8ac1ad9709c42616a7e273fb0f
install_tool swiftlint https://github.com/realm/SwiftLint/releases/download/0.65.0/portable_swiftlint.zip d6cb0aa7a2f5f1ef306fc9e37bcb54dc9a26facc8f7784ac0c3dd3eccf5c6ba6
install_tool actionlint https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_darwin_arm64.tar.gz aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f
if [[ -n "${GITHUB_PATH:-}" ]]; then
    echo "$tools/bin" >> "$GITHUB_PATH"
fi
