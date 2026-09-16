#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

revision="cca812bc1acf5ce970f45d02b8f17b55743c623b"
archive_sha="6366d4cc3d5c5a027a5315636f0deb211b298b510aaf3957da161f9d15c831bb"
build="$PWD/.build/payment-qr"
archive="$build/goinvoiceqr-$revision.tar.gz"
stage="$build/source"
output="$build/payment-qr"

command -v go >/dev/null || { echo "Go is required to build payment-qr." >&2; exit 1; }
mkdir -p "$build"
if [[ ! -f "$archive" ]]; then
    curl --fail --location --silent --show-error \
        "https://codeload.github.com/BramVR/goinvoiceqr/tar.gz/$revision" -o "$archive.tmp"
    mv "$archive.tmp" "$archive"
fi
actual_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
[[ "$actual_sha" == "$archive_sha" ]] || { echo "goinvoiceqr archive checksum mismatch." >&2; exit 1; }
prefix="goinvoiceqr-$revision"
while IFS= read -r path; do
    [[ "$path" == "$prefix/"* && "$path" != *"../"* && "$path" != /* ]] \
        || { echo "Unsafe goinvoiceqr archive path." >&2; exit 1; }
done < <(tar -tzf "$archive")
rm -rf "$stage"
mkdir -p "$stage/cmd/payment-qr"
tar -xzf "$archive" -C "$stage" --strip-components 1 \
    "$prefix/go.mod" "$prefix/go.sum" "$prefix/internal/invoiceqr"
cp Scripts/payment-qr-helper/main.go "$stage/cmd/payment-qr/main.go"
(
    cd "$stage"
    CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 GOMODCACHE="$build/module-cache" \
        go build -buildvcs=false -trimpath -o "$output" ./cmd/payment-qr
)
chmod 0755 "$output"
cp -f "$build/module-cache/github.com/piglig/go-qr@v1.1.0/LICENSE" "$build/go-qr-LICENSE"
chmod 0644 "$build/go-qr-LICENSE"
printf '%s\n' "$revision" > "$build/revision.txt"
printf '%s\n' "$archive_sha" > "$build/archive-sha256.txt"
shasum -a 256 Scripts/payment-qr-helper/main.go | awk '{print $1}' > "$build/helper-sha256.txt"
