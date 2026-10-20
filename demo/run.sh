#!/bin/sh
# Build run-pty-zig and launch it with the demo config.
# Usage: ./demo/run.sh [--auto-exit=N]
set -e

DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$DIR"

# Build if needed.
if [ ! -x zig-out/bin/run_pty_zig ] || [ build.zig -nt zig-out/bin/run_pty_zig ]; then
    echo "Building run-pty-zig..."
    zig build
fi

# Launch with the demo config.
exec zig-out/bin/run_pty_zig --auto-exit=auto demo/config.json
