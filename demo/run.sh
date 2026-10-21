#!/bin/sh
# Build run-pty-zig and launch it with the demo config.
# Usage: ./demo/run.sh [--auto-exit=N]
set -e

DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$DIR"

# Build if needed.
needs_build=0
if [ ! -x zig-out/bin/run-pty ] || [ build.zig -nt zig-out/bin/run-pty ]; then
    needs_build=1
else
    for f in src/*.zig; do
        if [ "$f" -nt zig-out/bin/run-pty ]; then
            needs_build=1
            break
        fi
    done
fi
if [ "$needs_build" = 1 ]; then
    echo "Building run-pty-zig..."
    zig build
fi

# Launch with the demo config.
exec zig-out/bin/run-pty --auto-exit=auto demo/config.json
