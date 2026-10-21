# Requirements

### Overview & Goals
Make `./demo/run.sh` reliably build and launch the demo from a clean checkout or when the executable is stale.

### Scope
- Align the launcher's executable path with the artifact installed by `build.zig` (`zig-out/bin/run-pty`).
- Preserve the existing lazy rebuild behavior and demo config invocation.
- Validate the script end-to-end; avoid changing CLI behavior or build artifact naming.

# Technical Design

### Current Implementation
`build.zig` creates an executable named `run-pty` and calls `b.installArtifact(exe)`, so the default output is `zig-out/bin/run-pty`. `README.md` documents that installed name, and the existing local-run example in `.junie/plans/idiomatic-zig-refactor.md` uses the same path. In contrast, `demo/run.sh` checks timestamps and executes `zig-out/bin/run_pty_zig`, which is the Zig module/import identifier rather than the executable filename.

### Proposed Changes
Update `demo/run.sh` to consistently test, timestamp-check, and execute `zig-out/bin/run-pty`. Keep its `zig build` fallback and `demo/config.json`/`--auto-exit=auto` launch arguments unchanged. Validate from a state without the built artifact and again when the artifact is current, confirming rebuild detection and successful launch.

# Testing

### Validation Approach
Run `./demo/run.sh` after removing or temporarily moving the generated executable to confirm the script builds and launches it, then run again with a current binary to ensure it skips the build. Also run `zig build test` to ensure no project regression.

### Key Scenarios
- Missing binary: launcher runs `zig build`, then executes `zig-out/bin/run-pty`.
- Current binary: launcher does not rebuild and still launches the demo config.
- Stale source/build file: launcher detects the newer input and rebuilds before launching.

# Delivery Steps

### Step 1: Correct demo executable path and rebuild checks
`demo/run.sh` consistently uses the executable path produced by the Zig build.
- Replace `zig-out/bin/run_pty_zig` with `zig-out/bin/run-pty` in the existence/executable check, timestamp comparisons, and final `exec`.
- Preserve the existing build-on-missing-or-stale behavior and CLI arguments.

### Step 2: Verify clean and incremental demo launches
The demo launcher builds when needed and successfully invokes the configured demo with the current artifact.
- Run `./demo/run.sh` from a missing-artifact state and confirm the build produces `zig-out/bin/run-pty` and the demo starts.
- Run the launcher again with a current artifact and confirm it launches without rebuilding; exercise stale-input detection where practical.
- Run `zig build test` and `git diff --check`.