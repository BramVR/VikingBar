#!/bin/sh
# Keep native proof captures on the classic engine when a stale Bridge owner blocks ScreenCaptureKit.
set -eu

peekaboo_bin=$(command -v peekaboo)
if [ "${1:-}" = see ]; then
    for argument in "$@"; do
        if [ "$argument" = --capture-engine ]; then
            exec "$peekaboo_bin" "$@"
        fi
    done
    exec "$peekaboo_bin" "$@" --capture-engine classic
fi

exec "$peekaboo_bin" "$@"
