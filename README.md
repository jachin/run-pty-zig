# run-pty-zig

**Version 0.1.3**

Run several commands concurrently in pseudo-terminals (PTYs), showing one command's output at a time, with a dashboard to switch between them. A lighter, easier alternative to `tmux`/`concurrently`.

This is a port of [lydell/run-pty](https://github.com/lydell/run-pty) to [Zig](https://ziglang.org/) (0.17+), targeting macOS (Apple Silicon and Intel). Zero external dependencies — everything is in the Zig standard library.

## Install

### Homebrew (macOS)

```sh
brew tap jachin/run-pty-zig
brew install run-pty
```

### From source

```sh
git clone https://github.com/jachin/run-pty-zig
cd run-pty-zig
zig build install --prefix /usr/local
```

The binary is installed as `run-pty`.

## Usage

### Delimiter syntax

The first non-flag argument is the delimiter (e.g. `%`). Commands are separated by it:

```sh
run-pty % npm run watch % npm run server
```

### JSON config file

Pass a single argument that is a path to a JSON file:

```sh
run-pty ./config.json
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
| `RUN_PTY_MAX_HISTORY` | Maximum bytes of output history to retain per command (default: 1,000,000). |

### Devbox-managed commands

`run-pty` starts each command as a literal argv array with `execvp`; it inherits the exported environment and `PATH` ordering of the `run-pty` process. A command's `cwd` changes its working directory before it starts, but does not activate Devbox, load shell startup files, or rebuild `PATH`.

To run a config with all commands inside the project's Devbox environment, launch `run-pty` from `devbox run`:

```sh
cd /path/to/project
devbox run -- run-pty ./run-pty.json
```

For a one-off command or non-interactive batch:

```sh
devbox run -- run-pty --auto-exit % gleam build % rebar3 version
```

If `run-pty` itself is launched outside Devbox, wrap each command that needs Devbox packages:

```sh
run-pty --auto-exit % devbox run -- gleam build
```

The equivalent JSON command is `"command": ["devbox", "run", "--", "gleam", "build"]`. Shell syntax such as variable expansion, pipes, or `&&` requires an explicit shell in the argv, for example `"command": ["devbox", "run", "--", "sh", "-c", "gleam build && gleam run"]`.

To compare tool selection, run this check directly and then as a command under `run-pty` (using `devbox run -- run-pty --auto-exit % sh -c '<check>'`):

```sh
devbox run -- sh -c 'printf "PATH=%s\n" "$PATH"; command -v gleam; gleam --version; command -v erl; erl -noshell -eval "io:format(\"OTP=~s ERTS=~s compiler=~s~n\", [erlang:system_info(otp_release), erlang:system_info(version), code:lib_dir(compiler)]), halt()."; command -v erlc; command -v rebar3; rebar3 version'
```

`erlc -version` is not a supported version query on the tested Erlang release; use the `erl` runtime/compiler information and `rebar3 version` instead. When comparing results, the resolved paths matter as much as the version strings.

Restarts inherit the environment held by the running `run-pty` process; they do not pick up later changes made in another terminal. Exit and relaunch `run-pty` through `devbox run` to refresh that inherited environment. A command that explicitly invokes `devbox run` performs its own Devbox setup each time it starts.

#### GleamingSigns investigation

The inspected `overseer-pty.json` backend command runs `devbox run -- sh -c`, then changes to `overseer/backend` and starts `watchexec`; the watcher launches `scripts/dev.sh`. Direct Devbox, run-pty-to-Devbox, and a print-only watcher probe all resolved `gleam`, `erl`, `erlc`, and `rebar3` from the project's `.devbox/nix/profile/default/bin`, with matching `PATH` ordering. The observed versions were Gleam `1.19.2`, Erlang/OTP `28` (ERTS `16.4.0.6`, compiler library `9.0.6.3`), and rebar3 `3.27.3`.

This comparison did not demonstrate a run-pty environment or executable-resolution mismatch, so no run-pty workaround or GleamingSigns script change is indicated. GleamingSigns declares `gleam@latest`; if a different Gleam version is intended, pin that intended version in its `devbox.json` rather than rewriting `PATH` in run-pty. In the tested Devbox shell, `cd` changed the actual directory but `$PWD` remained at the project root; `pwd` reported `overseer/backend`, and the compiler paths remained unchanged. Avoid relying on `$PWD` after that `cd` in this particular launch chain.

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
