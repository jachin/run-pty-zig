# run-pty → Zig: Implementation & Testing Plan

Port of [lydell/run-pty](https://github.com/lydell/run-pty) (v6.0.2) to Zig.
Reference source lives in `run-pty/` (git-ignored). Target platform: **macOS** (Apple Silicon first, Intel supported). Windows is deferred.

`run-pty` runs several commands concurrently in pseudo-terminals (PTYs), shows one command's output at a time, and lets you switch between them (dashboard), kill them all, and restart them. It's a lighter, easier alternative to `tmux`/`concurrently`.

---

## 1. Dependencies (and their Zig equivalents)

The original has only **two runtime dependencies** — and neither is needed in Zig:

| Original dep | What it does | Zig equivalent |
|---|---|---|
| `@lydell/node-pty` | Native PTY allocation/spawn (C++ addon) | **`std.posix`** — `openpty`/`forkpty`, `TIOCSWINSZ`, `kill`, `waitpid`. No external dep. |
| `tiny-decoders` | JSON + schema validation for the config file | **`std.json`** (built-in) + a thin hand-rolled validator for the `status` regex map. |

**Key win: the Zig port has zero external dependencies.** Everything is in the standard library.

Dev-only deps in the original (eslint, prettier, typescript, vitest) are replaced by Zig's built-in tooling: `zig build` (compile), `zig build test` (test runner), and `zig fmt` (format).

---

## 2. Feature inventory

Everything the tool does, grouped by subsystem. Each maps to a phase below.

**A. Command-line & config**
- Delimiter-based CLI: `run-pty % cmd1 % cmd2` (first arg after flags is the delimiter, e.g. `%`).
- Single-argument = JSON config file path.
- JSON config fields: `command` (required, non-empty `string[]`), `title`, `cwd`, `status` (regex→indicator map), `defaultStatus`, `killAllSequence`.
- `--auto-exit` / `--auto-exit=N` / `--auto-exit=auto` (concurrency limit; default = CPU count).
- `-h`/`--help`.
- No shell interpretation: commands run as literal argv arrays.

**B. PTY lifecycle**
- Spawn each command in its own PTY with `cwd` and initial size (stdout cols/rows).
- Stream output; forward user input to the focused command.
- Resize all PTYs on terminal resize.
- Detect exit; compute exit code (`128 + signal` when killed by a signal).
- Kill: send `killAllSequence` (default Ctrl-C); double-press within 500ms → force `SIGKILL`.

**C. Status indicators**
- Built-in: waiting 🥱, running 🟢, killing ⭕, restarting 🔄, aborted ⛔️, exit ⚪/🔴 (0/130 vs other).
- Each is a 3-way value: emoji (2 cols) / colored 1-char (ANSI) / plain 1-char (`NO_COLOR`).
- `status` rules: per output line, match regexes (ANSI stripped first); last match wins; `null` resets to 🟢.
- `defaultStatus`: initial indicator before output.

**D. Interactive UI (TTY)**
- Two screens: **dashboard** (list of all commands + footer) and **focused command** (full output + shortcut footer).
- Raw-mode keyboard: Ctrl-C (kill/kill-all), Ctrl-Z (dashboard), arrows (move selection), Enter (focus/restart), Esc (deselect), label keys `1-9 a-z A-Z` (jump to command).
- Mouse (SGR/1006): click to select/focus on the dashboard.
- Incremental dashboard redraw (diff against previous frame) wrapped in synchronized-output (DEC 2026) to avoid flicker.
- Request/response matching: forward child terminal queries (cursor position, colors, etc.) to the real terminal and back.
- Alternate-screen bookkeeping per command (restore on focus).
- Signal handling (SIGINT/TERM/HUP, debounced) → kill-all; restore terminal on exit.

**E. Non-interactive / CI mode**
- When stdin is not a TTY and `--auto-exit` is set: stream output plainly, answer terminal queries with fake responses, print a summary, exit 0 (all success) / 1 (any failure or early exit).

**F. Modes decision**
- stdin is TTY → interactive.
- else `--auto-exit` → non-interactive.
- else → error "requires stdin to be a TTY".

---

## 3. Architecture (Zig module layout)

Mirrors the original's separation of pure logic from I/O, which is what makes it testable.

```
src/
  main.zig            # entry: build std.process.Init, call run()
  root.zig            # re-exports the public API (run)
  run.zig             # run(): parse args → dispatch to interactive/non-interactive
  args.zig            # parseArgs, parseInputFile, CommandDescription, commandToPresentationName
  labels.zig          # ALL_LABELS, summarizeLabels
  ansi.zig            # escape constants, removeGraphicRenditions, truncate,
                      #   UNFINISHED_ESCAPE, ESCAPES_REQUEST/RESPONSE, CLEAR/NOT_SIMPLE_LOG/ALT regexes
  indicators.zig      # status indicator values + extractStatus (emoji/color/plain)
  render.zig          # statusText, drawDashboard, drawDashboardCommandLines, drawSummary,
                      #   footer texts (running/killing/exit/waiting/historyStart)
  command.zig         # Command struct: state machine (Status), history buffers,
                      #   pushHistory, updateStatusFromRules, start/kill
  pty.zig             # PTY alloc/spawn/resize/kill/wait via std.posix
  interactive.zig     # runInteractively: raw mode, poll event loop, onStdin, selection,
                      #   request/response, signal handlers, terminal restore
  noninteractive.zig  # runNonInteractively: CI mode
  signals.zig         # SIGINT/TERM/HUP setup + debounce
```

**Cross-cutting design decisions**
- **Event loop:** poll-based (`std.posix.poll`) over stdin + each PTY master fd. Simple, portable, predictable. (Revisit `std.Io` async later if needed.)
- **Memory:** one arena allocator for process lifetime; per-command history buffers capped by `MAX_HISTORY` (default 1,000,000, `RUN_PTY_MAX_HISTORY` override).
- **Single-threaded:** one event loop thread; each PTY is just a readable fd in the poll set.
- **State machines** as Zig enums (tagged unions):
  - `Status = Waiting | Running{pty} | Killing{pty, slow, lastKillPress, restartAfterKill} | Exit{code, wasKilled}`
  - `Current = Command{index} | Dashboard{previousRender}`
  - `Selection = Invisible{index} | Mousedown{index} | Keyboard{index} | ByIndicator{indicator, keyboardIndex}`

---

## 4. Phased implementation plan

Ordered so each phase is independently shippable and testable. Phases 1–3 are pure (no I/O) and fully unit-testable; 4–6 add I/O.

### Phase 1 — Data model & parsing (pure) ✅ DONE
**Build:** `labels.zig`, `args.zig` (`parseArgs`, `parseInputFile`, `CommandDescription`, `commandToPresentationName`), the `Status`/`Current`/`Selection`/`AutoExit`/`ParseResult` types.
**Status:** `types.zig`, `labels.zig`, `args.zig` implemented; `zig build` + `zig build test` green (10 args + 1 labels tests, no leaks). `build.zig` restructured so each test-bearing file is its own test root (Zig 0.17 only compiles imported files' `test` blocks when the import is used in a body). *Follow-up:* port the 10 JSON fixtures in `run-pty/test/fixtures/` as table-driven `parseInputFile` cases.
**Test (unit):**
- `parseArgs`: no args→Help; `-h`→Help; unknown flag→Error; `--auto-exit=0`→Error; delimiter splitting (`%`); single-arg→JSON file path; `--auto-exit`/`=N`/`=auto`.
- `parseInputFile`: all 10 fixtures in `run-pty/test/fixtures/` (empty, empty-array, empty-command, missing-command, wrong-command-type, bad-json-type, invalid-json-syntax, invalid-regex, key-typo, kitchen-sink) → assert correct value or the right error message.
- `commandToPresentationName`: quoting of args with special chars.
- `summarizeLabels`: 1 label, 2 labels (`1-2`), many (`1-9,a-z`).

### Phase 2 — ANSI / escape processing (pure string functions) ✅ CORE DONE
**Build:** `ansi.zig` (all escape constants, `removeGraphicRenditions`, ANSI-aware `truncate`, `splitUnfinishedEscape`), `indicators.zig` (`Env`, `Indicator`, built-in indicators, `pick`, `extractStatus`).
**Status:** `ansi.zig` (13 tests) + `indicators.zig` (16 tests) green. **Note:** Zig 0.17 has **no regex engine**, so the original's regexes are hand-rolled scans. The core string functions are done; the more involved matchers — `ESCAPES_REQUEST`/`ESCAPES_RESPONSE` (query/report splitting) and `CLEAR_REGEX`/`NOT_SIMPLE_LOG_ESCAPE`/`ALTERNATE_SCREEN_REGEX` (history management) — are deferred to the phases that consume them (Phase 4 history, Phase 5/6 request-response) and will be implemented as manual scanners there.
**Test (unit):**
- `removeGraphicRenditions` strips SGR codes, keeps text.
- `truncate` counts only visible chars, preserves codes, appends `…`.
- `UNFINISHED_ESCAPE` splits a trailing partial sequence (e.g. a lone `ESC[` at a chunk boundary).
- `ESCAPES_REQUEST`/`RESPONSE` split output into data vs. query vs. report.
- `extractStatus`: `NO_COLOR`→stripped 2nd string; emoji-capable→1st string; else 2nd string.

### Phase 3 — Rendering (pure, snapshot-style) 🟡 MOSTLY DONE
**Build:** `command.zig` (data-model layer: `Status`, `Command`, `CommandText`, `Current`, `Selection`, `isDone`, `statusHasTerminal`, `getLastLine`) + `render.zig` (text helpers `dim`/`bold`/`invert`/`shortcut`, `statusText`, `cwdText`, `commandTitleWithIndicator`/`commandTitleOnlyWithIndicator`, `historyStart`, footer texts `waitingText`/`runningText`/`killingText`/`exitText`, `drawSummary`).
**Status:** `command.zig` (20 tests) + `render.zig` (30 tests) green. **Deferred:** `drawDashboard`/`drawDashboardCommandLines` (the complex selection/highlight/truncation layout) and `exitTextAndHistory` — these are implemented when the interactive dashboard is wired up in Phase 6, since they're only exercised there. `invert` is a simplified whole-string wrap (the original splits on embedded reset codes).
**Test (unit, snapshot-style):** Port the JS `describe` blocks — `dashboard` (empty, one command, auto-exit ×3, restart-failed, kill-all, 62 commands), `summary` (success/failure/aborted combos), `focused command` (running/killing/exit/waiting, with/without cwd, auto-exit restart rules), `exit text and history`. Compare rendered strings with `std.testing.expectEqualStrings`; normalize ANSI to readable markers first (like the JS `replaceAnsi`) so expectations stay readable.

### Phase 4 — PTY layer (platform I/O) ✅ DONE
**Build:** `pty.zig` (`openpty`+`fork`+`execvp` spawn, `read`/`write`/`resize`/`kill`, blocking `wait` + non-blocking `tryWait`, exit-code decode 128+signal) + `scanners.zig` (hand-rolled `matchesClear`/`isNotSimpleLog`/`splitAlternateScreen`) + `command.zig` PTY methods (`start`, `kill` with double-press, `markExited`, `updateStatusFromRules`, `pushHistory`).
**Status:** `pty.zig` (3), `scanners.zig` (3), `command.zig` lifecycle/double-press/pushHistory/updateStatusFromRules tests all green. Key 0.17 findings: `openpty`/`forkpty`/`execvp` must be `extern "c"` (not in `std.c`); `std.posix` has `read` but **no** `write` (use `std.c.write(fd,ptr,len)`); `ioctl` request is `c_int` so Darwin values need `@bitCast`; `std.time.milliTimestamp` is gone (use `clock_gettime(CLOCK_MONOTONIC=6)`); `timespec` fields are `sec`/`nsec`; `std.ArrayList` is the unmanaged variant (use `std.array_list.Managed`); tagged unions have no `.tag`/`std.meta.tagEnum` (use `switch`); `?T` doesn't support `!=` (compare null-ness).
**Note:** `pushHistory` tracks state (alt-screen, simple-log, status-from-rules) but leaves history-string management to the render layer; `updateStatusFromRules` uses substring matching (not per-line regex). Both are conservative approximations of the original's regexes.

### Phase 5 — Non-interactive / CI mode (`--auto-exit`)
**Build:** `noninteractive.zig` (spawn with concurrency limit, `poll` loop over PTY masters, stream output, print `exitTextAndHistory` + `drawSummary`, exit code) + `render.zig` `exitTextAndHistory` + `scanners.zig` `respondToRequestFake` + `root.zig`/`main.zig` TTY dispatch.
**Status:** ✅ Working end-to-end. Verified manually: `--auto-exit=2 % true % echo hello </dev/null` → exit **0**; `--auto-exit=2 % false % echo hello </dev/null` → exit **1**. Helper-function tests green. Key 0.17 findings: `std.posix.poll`/`pollfd` available (POLL* bits must be defined manually); `std.Io.Writer` must be `flush()`ed before `std.process.exit` (the `defer` in `main` is skipped by `noreturn`); `args[0]` (program name) must be skipped before `parseArgs` or `partitionArgs` stops early.
**Deferred:** request/response forwarding (`ESCAPES_REQUEST`/`ESCAPES_RESPONSE` splitting) and `attemptedKillAll` (signal handlers) — these need the interactive signal handling from Phase 6.

### Phase 6 — Interactive mode (TUI event loop)
**Build:** `interactive.zig` (raw mode via `termios`; `poll` loop over stdin + PTYs; `onStdin` key/mouse dispatcher; dashboard↔command switching; selection state; request/response forwarding; synchronized-output wrapping of redraws) + signal handlers.
**Status:** ✅ Complete. `interactive.zig` implements: `Session` struct, `switchToDashboard`/`switchToCommand`, `killAll`/`restart`/`restartExited`/`restartByIndicator` (with `restart_after_kill` clearing), `onStdin` key dispatcher (Ctrl-Z/Ctrl-C/arrows/Enter/Escape/label keys), SGR/1006 mouse parsing, `printDataWithExtraText`, `poll` loop over stdin + PTY masters, terminal resize detection, signal handlers (SIGINT/TERM/HUP → killAll), raw mode + terminal restoration, exit-when-done. `drawDashboard`/`drawDashboardCommandLines`/`getIndicatorChoice(s)` in `render.zig` (5 tests).
**Remaining (known limitations):** request/response forwarding (`ESCAPES_REQUEST`/`ESCAPES_RESPONSE` splitting), synchronized-output mode, process-group kill for forced kill, per-line regex status rules (currently ANSI-stripped substring).
**Test:**
- Primarily **manual**, matching the original.
- **Scripted integration (best-effort):** drive the binary through a PTY from the test, send `Ctrl-Z`/arrows/`Ctrl-C`, and assert on the resulting escape-stream output.

### Phase 7 — Polish & hardening
- `NO_COLOR` end-to-end; `RUN_PTY_MAX_HISTORY`; `--auto-exit=auto` (CPU count via `sysconf`).
- Wide-character / emoji / CJK width handling in the dashboard.
- A README for the Zig tool (usage, JSON format, flags).
- **Deferred (Windows):** conpty + `conptyInheritCursor`, `cmd.exe` wrapping/quoting, win32-input-mode conversion, emoji-on-Windows detection. Keep the code structured so these slot in behind `if (comptime builtin.os.tag == .windows)`.

---

## 5. Testing strategy (Zig specifics)

- **Runner:** Zig's built-in — `test {}` blocks, run via `zig build test`. No vitest/jest.
- **Pure functions (Phases 1–3):** direct `std.testing.expectEqual` / `expectEqualStrings`. For the snapshot-style render tests, normalize ANSI codes to readable glyphs before comparing (port the JS `replaceAnsi` idea) so expectations are human-checkable. Store large expected outputs as inline multi-line strings or fixture files under `test/`.
- **Integration (Phases 4–5):** use `std.process.Child` to spawn either the built binary (Phase 5) or real commands in a PTY (Phase 4); assert on exit code and captured stdout/stderr.
- **Interactive (Phase 6):** manual + a best-effort scripted PTY harness. Accept that full TUI automation is flaky; keep the automated set small and high-signal.
- **Layout:** mirror the original — `test/` with a `fixtures/` dir (reuse the same JSON fixtures) and per-module `test {}` blocks colocated with the source (Zig idiom), plus a `test/` dir for integration tests that need the built binary.

---

## 6. macOS-specific notes

- **Build:** already handled — native `arm64`, ad-hoc code signing (automatic), min-OS pinned to Ventura 13.0 (see `build.zig`).
- **PTY:** `openpty`/`forkpty` from Darwin; `TIOCSWINSZ` for resize; `kqueue` available but `poll` is simpler and sufficient.
- **Signals:** `sigaction` for SIGINT/TERM/HUP; keep the 10ms debounce (npm/npx deliver double SIGINTs).
- **Terminal restore:** on exit emit show-cursor + disable-mouse + reset-colors.
- **Emoji width:** Apple terminals render emoji at 2 cols — the `ICON_WIDTH`/`EMOJI_WIDTH_FIX` logic applies.

---

## 7. Risks & open questions

1. **Request/response matching** (forwarding child terminal queries to the real terminal and back) is the fiddliest interactive detail. *Decision needed:* implement full forwarding, or start with fake responses (like CI mode) and upgrade?
2. **Poll vs. `std.Io` async:** poll is simpler now; confirm we don't hit a scaling wall with many PTYs (unlikely for a dev tool).
3. **Snapshot test fidelity:** matching the original's exact byte output (cursor positions, padding) may require care with the emoji-width fix. Plan to diff against the JS tool's actual output where useful.
4. **Scope of "done":** propose declaring the port feature-complete when Phases 1–5 pass (full non-interactive + all pure logic) and Phase 6 is manually verified, since interactive automation is inherently limited.

---

## Suggested first milestone

**Phase 1 + Phase 2** (data model, parsing, ANSI processing) with their unit tests — a fully green, pure, I/O-free foundation that compiles on macOS and gives us a testing harness to build on. Then proceed to Phase 3 (rendering) and Phase 4 (PTY).
