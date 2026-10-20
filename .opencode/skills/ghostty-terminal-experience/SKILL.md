---
name: ghostty-terminal-experience
description: Improve command-line and PTY application experiences when run-pty-zig is running inside Ghostty. Covers identifying Ghostty safely, using terminal protocols for notifications, progress, titles, hyperlinks, working-directory context, and keyboard input, while preserving compatibility with other terminals.
---

# Ghostty Terminal Experience

Use this skill when designing or implementing features in run-pty-zig that can make use of Ghostty's terminal capabilities. Treat Ghostty as a standards-compatible terminal with additional supported protocols, not as a dependency: all features must continue to work in other terminals.

## Start by establishing the boundary

run-pty-zig launches child processes on PTYs and displays their output; Ghostty is the user's terminal emulator. Keep those responsibilities separate:

- run-pty-zig can emit terminal control sequences to its own stdout and can set child-process environment variables.
- Child commands write to their individual PTYs. Their control sequences normally pass through run-pty-zig as output; do not mistake them for requests to run-pty-zig.
- Ghostty interprets supported sequences and renders the result. Do not reimplement terminal rendering, image protocols, or Ghostty UI features inside this application.
- Never assume Ghostty is present. Provide a useful fallback and avoid changing behavior for other terminal emulators.

## Detect Ghostty conservatively

Use `TERM_PROGRAM=ghostty` as an optional integration hint. `TERM=xterm-ghostty` is a terminal type used for terminfo and should not be treated as the only proof of the running emulator. Environment variables may be absent, inherited, overridden, or spoofed; they are hints, not security boundaries.

When a feature has a standard sequence supported across terminals, prefer emitting that standard sequence without emulator detection. Gate Ghostty-specific behavior on the hint only when the behavior is genuinely Ghostty-specific. Never use user-controlled environment values to construct an escape sequence.

## Enhancements to consider

### Desktop notifications

Ghostty supports terminal notifications through OSC 9 and OSC 777 forms. A notification can let a user know that a background command finished or failed while another command is focused. Consider this for command completion, not for every line or status change.

- Send a notification only when the user has switched away from that command or otherwise cannot already see the event.
- Use a short, sanitized title/body; avoid including arbitrary child output, secrets, or untrusted control characters.
- Make notifications optional or configurable and provide a quiet default for frequently completing processes.
- Confirm exact OSC syntax and platform behavior against the current Ghostty documentation/source before implementation.

### Progress indication

Ghostty supports the widely used OSC 9;4 progress protocol. A PTY dashboard could expose an overall or focused-command progress state if the application has reliable progress information. Do not infer percentages from arbitrary output; use determinate progress only when a command explicitly provides it, otherwise use an indeterminate state where supported. Always reset/clear progress on completion, error, cancellation, and shutdown.

### Window and tab titles

OSC 0 and OSC 2 can set terminal title text. A title reflecting the selected command or dashboard state may help distinguish sessions. Keep titles concise, sanitize control characters, and restore/clear the title when the dashboard exits if doing so matches existing terminal behavior. Titles are shared terminal UI state, so avoid repeatedly overwriting them with noisy updates.

### Clickable links

OSC 8 hyperlinks can make file paths, URLs, or dashboard references clickable in supporting terminals. Use explicit, validated targets and readable link text. Close each hyperlink with an empty OSC 8 target, including on error paths. Do not wrap arbitrary child output as a link or trust terminal text to supply a safe URL.

### Working-directory context

OSC 7 communicates a current working directory to terminal emulators. This can improve shell/navigation integrations, but run-pty-zig has multiple child working directories while the terminal itself has only one current location. Do not emit a child-specific OSC 7 value on every command switch unless the intended user-visible semantics are clear. Prefer setting each child process's actual `cwd` correctly and consider OSC 7 only for a dashboard-owned, well-defined directory.

### Keyboard input compatibility

Ghostty supports modern keyboard protocols, including Kitty keyboard protocol features. A PTY multiplexer must not assume keys are encoded identically in all terminal modes. Preserve byte-exact pass-through for user input where appropriate; do not enable a keyboard protocol globally unless run-pty-zig can parse its replies, restore prior mode, and correctly distinguish dashboard shortcuts from child input. Add tests for modified keys, escape-key timing, and mode reset before adopting a protocol.

### Other protocols

Ghostty supports additional protocols such as clipboard access, focus reporting, synchronized output, and graphics. These should not be added merely because they exist:

- Clipboard protocols can expose or modify sensitive user data; require explicit user intent and avoid unsolicited clipboard reads/writes.
- Focus reports are useful only if the app has a concrete focus-dependent behavior and handles disable/reset correctly.
- Synchronized output is intended to avoid partial redraws; use it only around bounded dashboard redraws and always send the matching end sequence.
- Graphics protocols are for terminal applications that render images. They are not a substitute for run-pty-zig's textual process dashboard.

## Implementation checklist

1. Identify whether the requirement belongs to run-pty-zig, the child process, or Ghostty itself.
2. Prefer a documented, broadly supported terminal protocol; use Ghostty-specific behavior only when it provides a clear improvement.
3. Verify current syntax and support in Ghostty's official documentation and the local reference checkout before coding. The checkout is ignored by Git and may be stale; check its revision or fetch/update it only when explicitly requested.
4. Preserve non-Ghostty behavior and provide a fallback when detection or support is unavailable.
5. Sanitize untrusted text, bound sequence sizes, and never allow child output to trigger privileged app-side actions.
6. Ensure every temporary terminal mode/state is restored on normal exit, error, interrupt, and forced shutdown.
7. Test both Ghostty-enabled behavior and the no-Ghostty/fallback path. Prefer focused tests for exact emitted bytes and state cleanup.

## Reference sources

- Ghostty documentation: <https://ghostty.org/docs>
- Ghostty terminal feature documentation: <https://ghostty.org/docs/vt>
- Local reference checkout (ignored by Git): `ghostty/`
- Useful local implementation references include `ghostty/src/terminal/` for protocol parsing, `ghostty/src/apprt/gtk/desktop_notifications.zig` for notification integration, and `ghostty/src/input/key_encode.zig` for keyboard encoding. These are implementation details, not a stable API contract.
- Existing project terminal sequence reference: `.opencode/skills/terminal-codes/SKILL.md`