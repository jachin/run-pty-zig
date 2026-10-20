---
sessionId: session-261020-145107-1g7o
---

# Requirements

### Overview & Goals
Audit every issue in `lydell/run-pty` and ensure this Zig port matches fixes for closed issues and addresses relevant unresolved issues where the behavior belongs in this project.

### Scope
- Inventory all upstream issues, recording status, described behavior, fix/reference, and applicability to this macOS Zig port.
- Reproduce each applicable issue against this codebase; implement fixes for confirmed gaps that can be responsibly resolved here.
- Add regression tests for every implemented fix.
- Exclude issues that are non-actionable here (upstream packaging/platform-specific changes outside this port, duplicates, or behavior intentionally outside the project scope), documenting the reason in the audit result.

# Technical Design

### Current Implementation
The CLI enters through `src/main.zig` and `src/root.zig`; parsing and JSON config handling live in `src/args.zig`. Process/PTY behavior is encapsulated in `src/pty.zig`, with command lifecycle in `src/command.zig`. Output interpretation is split across `src/ansi.zig` and `src/scanners.zig`; presentation and orchestration use `src/render.zig`, `src/interactive.zig`, and `src/noninteractive.zig`. `build.zig` defines per-module test executables aggregated by `zig build test`.

### Proposed Changes
Start with an issue-by-issue audit of the full GitHub issue query, including closed and open issues. Map each issue to its relevant implementation module, compare its expected/fixed behavior with this port, then implement only confirmed applicable behavioral gaps while preserving the project’s Zig and macOS conventions. For each fix, add a focused regression test to the module’s existing test suite, extending `build.zig` only if a new test target is necessary.

# Testing

### Validation Approach
Run `zig build test` after the issue-specific regression tests are added. Validate each selected issue with a test that captures the reported input or lifecycle condition and asserts the expected observable behavior.

### Key Scenarios
- Closed issues: confirm the upstream fix’s expected behavior and prove this implementation matches it.
- Open issues: verify whether the report reproduces and is applicable before treating it as a fix.
- Regressions: exercise nearby parser, output scanner, PTY lifecycle, or interactive/noninteractive behavior where the fix touches those paths.

# Delivery Steps

### ✓ Step 1: Inventory upstream issues and map reported behavior
A complete issue audit identifies applicable behaviors and the project modules that need parity fixes.
- Retrieve all issues from the upstream repository, including open and closed states, and record titles, status, issue descriptions, and relevant fix references.
- Map each actionable report to its corresponding implementation in `src/args.zig`, `src/pty.zig`, `src/scanners.zig`, `src/ansi.zig`, `src/command.zig`, `src/render.zig`, `src/interactive.zig`, or `src/noninteractive.zig`.
- Compare closed-issue behavior against this port and determine whether unresolved reports reproduce and fit the port’s scope.
- Record excluded issues with a concise applicability rationale; use this verified inventory to scope later stages.

### ✓ Step 2: Align parsing and output interpretation with upstream fixes
Applicable parser and terminal-output issue gaps are fixed with regression coverage in their existing Zig modules.
- Fix confirmed CLI/config parsing gaps in `src/args.zig` and output/escape interpretation gaps in `src/ansi.zig` or `src/scanners.zig` as identified by the inventory.
- Add focused tests alongside the affected module’s existing tests for every behavior changed.
- Verify the issue-specific expected inputs and results without broad unrelated refactoring.

### ✓ Step 3: Align PTY lifecycle and execution behavior with upstream fixes
Applicable process-management and command-execution issue gaps are fixed and covered by tests.
- Address confirmed PTY, child-process, exit-status, or command-lifecycle gaps in `src/pty.zig` and `src/command.zig`.
- Add regression tests for each implemented behavior, respecting macOS-specific constraints of this project.
- Keep changes bounded to the issue reports verified during the inventory.

### ✓ Step 4: Align UI flows and validate the complete regression suite
Applicable rendering and interaction issues are addressed, and the complete test suite verifies all implemented parity fixes.
- Fix confirmed dashboard, status rendering, keyboard interaction, or noninteractive-mode gaps in `src/render.zig`, `src/interactive.zig`, or `src/noninteractive.zig`.
- Add per-fix regression tests to the affected module; update `build.zig` only if needed to run a new test target.
- Run `zig build test` and ensure all issue-specific regressions and existing module tests pass.