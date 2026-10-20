# run-pty-zig

Run several commands concurrently in pseudo-terminals (PTYs), showing one command's output at a time, with a dashboard to switch between them. A lighter, easier alternative to `tmux`/`concurrently`.

This is a port of [lydell/run-pty](https://github.com/lydell/run-pty) to [Zig](https://ziglang.org/) (0.17+), targeting macOS (Apple Silicon and Intel). Zero external dependencies — everything is in the Zig standard library.

## Build

```sh
zig build
```

The binary is at `zig-out/bin/run_pty_zig`.

## Usage

### Delimiter syntax

The first non-flag argument is the delimiter (e.g. `%`). Commands are separated by it:

```sh
run_pty_zig % npm run watch % npm run server
```

### JSON config file

Pass a single argument that is a path to a JSON file:

```sh
run_pty_zig ./config.json
```

The JSON format is a top-level array of command objects:

```json
[
  {
    "command": ["npm", "run", "watch"],
    "title": "Frontend",
    "cwd": "./frontend",
    "status": [
      { "pattern": "compiled", "status": ["✅", "ok"] }
    ],
    "defaultStatus": ["🟢", "run"],
    "killAllSequence": "q"
  }
]
```

### Flags

| Flag | Description |
|---|---|
| `--auto-exit=N` | Exit when all commands have finished; at most N run in parallel. |
| `--auto-exit=auto` | Same, but N = CPU count. |
| `-h`, `--help` | Show help. |

### Environment variables

| Variable | Effect |
|---|---|
| `NO_COLOR` | Use plain single-character indicators instead of emoji/ANSI color. |

### Keyboard shortcuts (interactive mode)

| Key | Action |
|---|---|
| `Ctrl-Z` | Show dashboard |
| `Ctrl-C` | Kill all commands (double-press to force) |
| `↑` / `↓` | Move selection |
| `←` / `→` | Toggle indicator selection (group by status) |
| `Enter` | Focus selected command / restart exited |
| `Escape` | Unselect |
| `1`–`9`, `a`–`z` | Focus command by label |

## Testing

```sh
zig build test
```

## License

MIT (same as the original).
