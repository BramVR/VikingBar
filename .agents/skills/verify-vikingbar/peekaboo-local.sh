#!/bin/sh
# Keep this proof on the permission-checked local runtime.
set -eu

peekaboo_bin=$(command -v peekaboo)
for argument in "$@"; do
    if [ "$argument" = --no-remote ]; then
        exec "$peekaboo_bin" "$@"
    fi
done
exec "$peekaboo_bin" "$@" --no-remote
