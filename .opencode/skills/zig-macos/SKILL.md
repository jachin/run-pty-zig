---
name: zig-macos
description: Set up and build Zig projects on macOS (Apple Silicon and Intel). Load when starting a Zig project on a Mac, choosing a target/architecture, dealing with code signing, or — most commonly — when a built binary's minimum macOS version is too high (only runs on the newest macOS) and you need to pin a lower deployment floor. Covers installing Zig (Homebrew), the build.zig / build.zig.zon layout, the ResolvedTarget/query API, target-triple version syntax, and verifying minos with otool.
---

# Zig on macOS

Practical notes for building Zig on a Mac, verified on **Zig 0.17.0** (Homebrew) on Apple Silicon. The build-system API has shifted across Zig releases — if a snippet below doesn't compile, the version is likely different; check the std docs for your version.

## 1. Install

```sh
brew install zig        # stable (e.g. 0.17.0); pulls llvm@22 + lld@22
zig version
```

Homebrew's bottle is the fastest path. For a specific version, download the minisig-signed tarball from https://ziglang.org/download/ (pick the `aarch64-macos` file on Apple Silicon).

## 2. Project layout (`zig init`)

```
build.zig        # build script — a DSL that mutates the build graph `b`
build.zig.zon    # package manifest: name, version, fingerprint, min zig version, deps, paths
src/main.zig     # CLI entry point (pub fn main(init: std.process.Init))
src/root.zig     # library module (business logic, importable)
```

- `zig build` → compiles, installs to `zig-out/bin/<name>`
- `zig build run -- args...` → build + run, passing args after `--`
- `zig build test` → runs `test {}` blocks
- `zig build --help` → lists all `-D` options (target, cpu, optimize, …)

The `zig init` template splits CLI (`main.zig`) from logic (`root.zig`) into two modules. For a pure CLI tool you can collapse to one module; keep the split when the logic is substantial or reusable.

## 3. macOS build facts (mostly automatic)

- **Architecture**: the default target is *native* — `aarch64` on Apple Silicon, `x86_64` on Intel. No config needed.
- **Code signing**: the linker (lld) **ad-hoc-signs automatically**. This is *required* on Apple Silicon — an unsigned arm64 binary won't run. Nothing to do; verify with `codesign -dv <bin>` (look for `Signature=adhoc`).
- **C library**: Darwin `libSystem` is linked automatically when you use `std.posix`.
- **Binary type**: `file <bin>` → `Mach-O 64-bit executable arm64`.

## 4. The minimum-OS-version gotcha (the big one)

**Symptom**: a freshly built binary only runs on the newest macOS. `otool -l <bin> | grep -A3 LC_BUILD_VERSION` shows `minos` equal to the SDK version (e.g. `27.0.1`), not a usable floor.

**Why**: when you build for the *native* target, Zig resolves the OS version to the current system/SDK version and uses that as the minimum. That's too restrictive for a tool you want to ship.

**The trap**: editing the *resolved* target does nothing.
```zig
target.result.os.version_range.semver.min = ...   // NO — the compiler ignores this
```
The compiler derives the linker's min version from the **query**, not the resolved result.

**The fix** — set the version on the *query* and re-resolve:
```zig
var target = b.standardTargetOptions(.{});
// Only override the native default; respect an explicit -Dtarget.
if (target.result.os.tag == .macos and target.query.isNative()) {
    target.query.os_version_min = .{ .semver = .{ .major = 13, .minor = 0, .patch = 0 } };
    target = b.resolveTargetQuery(target.query);
}
```

Key API facts (0.17):
- `b.standardTargetOptions(.{})` returns a `std.Build.ResolvedTarget` = `struct { query: Target.Query, result: Target }`.
- `Target.Query` fields: `os_tag: ?Os.Tag`, `os_version_min: ?OsVersion`, `os_version_max: ?OsVersion`.
- `OsVersion` is a tagged union: `.none`, `.semver: SemanticVersion`, `.windows`.
- `query.isNative()` is true only when no target/cpu/abi was specified — guard on it so a user's `-Dtarget=...` still wins.
- `b.resolveTargetQuery(query)` re-derives `result` from the (now non-native) query.

Set `os_version_max` the same way if you also want to cap the upper bound.

## 5. Target-triple syntax (`-Dtarget=`)

Format: `arch-os.version-abi`. The OS token uses the **first** `.` to separate the name from the version; the version's own `.` (major.minor) is part of the version.

| Triple | Meaning |
|---|---|
| `aarch64-macos.13.0-none` | Apple Silicon, min macOS 13.0 |
| `x86_64-macos.11.0-none` | Intel, min macOS 11.0 |
| `aarch64-macos.13.0...15.0-none` | min 13.0, max 15.0 (`...` separates the range) |

macOS ABI is `none` (there is no `macabi`). A bare `aarch64-macos-none` (no version) uses Zig's default version for that target.

## 6. Verify

```sh
otool -l zig-out/bin/<name> | grep -A3 LC_BUILD_VERSION   # minos + sdk
codesign -dv zig-out/bin/<name>                            # Signature=adhoc
file zig-out/bin/<name>                                    # Mach-O ... arm64 / x86_64
```

`minos` is your deployment floor; `sdk` is the SDK it was built against (informational).

## 7. Beyond the build (for PTY/terminal tools)

The actual run-pty-style work lives in `std.posix`, all available on macOS: `openpty`/`forkpty` for PTY allocation, `tcgetattr`/`tcsetattr` + `termios` for raw mode, `TIOCGWINSZ` for window size, and signal handling. These are version-stable C bindings — the macOS-specific build concerns above are what usually bite first.

## References
- Zig download / releases: https://ziglang.org/download/
- Zig std docs (match your version): https://ziglang.org/documentation/0.17.0/std/
- `std.Build` / `std.Target` source: `<zig>/lib/zig/std/Build.zig`, `std/Target.zig`, `std/Target/Query.zig`
- macOS `LC_BUILD_VERSION`: `man 5 mach-o` / `otool`
