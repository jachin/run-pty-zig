# Terminal & PTY Escape Sequence Reference

Reference for all terminal control sequences used by run-pty-zig. Sourced from
ECMA-48 / ISO 6429, the xterm ctlseqs documentation (Thomas Dickey), and the
macOS `man 4 termios` / `man 4 tty` pages.

## Sequence Structure

All multi-byte sequences begin with `ESC` (0x1B). The type is determined by
the byte(s) following ESC:

| Type | Format | Terminator | Example |
|------|--------|------------|---------|
| Fe | ESC + byte 0x40–0x5F | (single byte) | ESC c (RIS) |
| CSI | ESC [ + params + intermediates + final | final byte 0x40–0x7E | ESC [ 1;31 m |
| OSC | ESC ] + string | ST (ESC \) or BEL (0x07) | ESC ] 0 ; title ST |
| DCS | ESC P + string | ST | ESC P 0 q ST |
| APC | ESC _ + string | ST | (unused by xterm) |
| PM | ESC ^ + string | ST | (privacy) |
| SOS | ESC X + string | ST | (rare) |

CSI parameter bytes: 0x30–0x3F (`0-9:;<=>?`).
CSI intermediate bytes: 0x20–0x2F (space through `/`).
CSI final bytes: 0x40–0x7E (`@` through `~`).

Private sequences use `?` as the first parameter byte (e.g. `ESC [ ? 25 h`).

## C0 Control Codes (single-byte)

| Code | Hex | Name | C escape | Effect |
|------|-----|------|----------|--------|
| BEL | 0x07 | Bell | `\a` | Audible/visual bell |
| BS | 0x08 | Backspace | `\b` | Cursor left |
| HT | 0x09 | Horizontal Tab | `\t` | Next tab stop |
| LF | 0x0A | Line Feed | `\n` | Cursor down (scroll if at bottom) |
| VT | 0x0B | Vertical Tab | `\v` | Treated as LF |
| FF | 0x0C | Form Feed | `\f` | New page |
| CR | 0x0D | Carriage Return | `\r` | Cursor to column 0 |
| SO | 0x0E | Shift Out | | Select G1 as GL |
| SI | 0x0F | Shift In | | Select G0 as GL |
| ESC | 0x1B | Escape | `\x1B` | Starts all escape sequences |

## C1 Control Codes (8-bit, or 7-bit Fe equivalents)

| 8-bit | 7-bit | Name | Effect |
|-------|-------|------|--------|
| 0x84 | ESC D | IND | Index (cursor down) |
| 0x85 | ESC E | NEL | Next Line (CR + LF) |
| 0x88 | ESC H | HTS | Tab Set |
| 0x8D | ESC M | RI | Reverse Index (cursor up) |
| 0x90 | ESC P | DCS | Device Control String |
| 0x98 | ESC X | SOS | Start of String |
| 0x9A | ESC Z | DECID | Return Terminal ID |
| 0x9B | ESC [ | CSI | Control Sequence Introducer |
| 0x9C | ESC \ | ST | String Terminator |
| 0x9D | ESC ] | OSC | Operating System Command |
| 0x9E | ESC ^ | PM | Privacy Message |
| 0x9F | ESC _ | APC | Application Program Command |

## CSI Commands (standard, ECMA-48)

| Sequence | Mnemonic | Effect |
|----------|----------|--------|
| ESC [ n A | CUU | Cursor Up n (default 1) |
| ESC [ n B | CUD | Cursor Down n (default 1) |
| ESC [ n C | CUF | Cursor Forward n (default 1) |
| ESC [ n D | CUB | Cursor Back n (default 1) |
| ESC [ n E | CNL | Cursor Next Line n (default 1) |
| ESC [ n F | CPL | Cursor Previous Line n (default 1) |
| ESC [ n G | CHA | Cursor to column n (default 1) |
| ESC [ n ; m H | CUP | Cursor to row n, col m (default 1;1) |
| ESC [ n I | CHT | Cursor Forward Tab n (default 1) |
| ESC [ n J | ED | Erase in Display: 0=below, 1=above, 2=all, 3=scrollback |
| ESC [ n K | EL | Erase in Line: 0=right, 1=left, 2=all |
| ESC [ n L | IL | Insert n lines (default 1) |
| ESC [ n M | DL | Delete n lines (default 1) |
| ESC [ n P | DCH | Delete n characters (default 1) |
| ESC [ n S | SU | Scroll up n lines (default 1) |
| ESC [ n T | SD | Scroll down n lines (default 1) |
| ESC [ n X | ECH | Erase n characters (default 1) |
| ESC [ n Z | CBT | Cursor Backward Tab n (default 1) |
| ESC [ n ` | HPA | Horizontal Position Absolute (col n) |
| ESC [ n a | HPR | Horizontal Position Relative |
| ESC [ n b | REP | Repeat preceding graphic char n times |
| ESC [ n c | DA | Device Attributes (Primary) |
| ESC [ n d | VPA | Vertical Position Absolute (row n) |
| ESC [ n e | VPR | Vertical Position Relative |
| ESC [ n ; m f | HVP | Horizontal + Vertical Position |
| ESC [ n g | TBC | Tab Clear: 0=current, 3=all |
| ESC [ n m | SGR | Select Graphic Rendition (see below) |
| ESC [ n n | DSR | Device Status Report: 5=OK, 6=cursor pos |
| ESC [ n @ | ICH | Insert n characters (default 1) |
| ESC [ n SP @ | SL | Shift left n columns |
| ESC [ n SP A | SR | Shift right n columns |
| ESC [ n ^ | SD | Scroll down (ECMA-48 form) |

## CSI Device Status Report (DSR) — queries the terminal sends BACK

| Request | Response |
|---------|----------|
| ESC [ 5 n | ESC [ 0 n (terminal OK) |
| ESC [ 6 n | ESC [ row ; col R (cursor position) |
| ESC [ 0 n | ESC [ 0 n (terminal OK, xterm) |
| ESC [ 1 5 n | ESC [ 0 n (power status, xterm) |

## SGR (Select Graphic Rendition) — ESC [ Pm m

Multiple parameters separated by `;`. No params = `0` (reset).

| Code | Effect | Reset |
|------|--------|-------|
| 0 | Reset all attributes | — |
| 1 | Bold / increased intensity | 22 |
| 2 | Faint / dim | 22 |
| 3 | Italic | 23 |
| 4 | Underline | 24 |
| 5 | Slow blink | 25 |
| 6 | Rapid blink | 25 |
| 7 | Reverse video (invert) | 27 |
| 8 | Conceal (hidden text) | 28 |
| 9 | Strikethrough | 29 |
| 21 | Doubly underlined (or: not bold on some) | 24 |
| 22 | Normal intensity (not bold, not faint) | — |
| 23 | Not italic | — |
| 24 | Not underlined | — |
| 25 | Not blinking (show cursor) | — |
| 27 | Not reversed | — |
| 28 | Reveal (not concealed) | — |
| 29 | Not struck through | — |
| 30–37 | Foreground color (black,red,green,yellow,blue,magenta,cyan,white) | 39 |
| 38;5;n | Foreground 256-color (n=0–255) | 39 |
| 38;2;r;g;b | Foreground 24-bit RGB | 39 |
| 39 | Default foreground | — |
| 40–47 | Background color (same order as 30–37) | 49 |
| 48;5;n | Background 256-color | 49 |
| 48;2;r;g;b | Background 24-bit RGB | 49 |
| 49 | Default background | — |
| 53 | Overlined (not in Terminal.app) | 55 |
| 58;5;n / 58;2;r;g;b | Underline color (Kitty, VTE, iTerm2) | 59 |
| 90–97 | Bright foreground (gray,red,green,yellow,blue,magenta,cyan,white) | 39 |
| 100–107 | Bright background | 49 |

### 256-color palette layout
- 0–15: standard + bright colors
- 16–231: 6×6×6 color cube: `16 + 36*r + 6*g + b` (r,g,b in 0–5)
- 232–255: grayscale ramp (24 steps)

## DEC Private Modes (CSI ? Pm h / l)

`h` = set (enable), `l` = reset (disable).

| Mode | Name | Effect |
|------|------|--------|
| 1 | DECCKM | Application Cursor Keys (arrows send ESC O A/B/C/D) |
| 2 | DECANM | Designate USASCII for G0–G3 (VT100 mode) |
| 3 | DECCOLM | 132-column mode (vs 80) |
| 4 | DECSCLM | Smooth (slow) scroll |
| 5 | DECSCNM | Reverse video (whole screen) |
| 6 | DECOM | Origin Mode (cursor home = top of scrolling region) |
| 7 | DECAWM | Auto-wrap at right margin |
| 8 | DECARM | Auto-repeat keys |
| 9 | — | X10 mouse: report button press only |
| 25 | DECTCEM | Show (h) / Hide (l) cursor |
| 38 | DECTEK | Enter Tektronix mode |
| 47 | — | Use Alternate Screen Buffer (old xterm) |
| 1000 | — | X11 mouse: report press + release |
| 1001 | — | Hilite mouse tracking |
| 1002 | — | Cell-motion mouse tracking (button drag) |
| 1003 | — | All-motion mouse tracking (track all movement) |
| 1004 | — | Report FocusIn (ESC [ I) / FocusOut (ESC [ O) |
| 1005 | — | UTF-8 mouse mode (for 3-byte coords) |
| 1006 | — | SGR mouse mode: ESC [ < b ; x ; y M / m |
| 1007 | — | Alternate scroll mode (scroll instead of arrow in alt screen) |
| 1015 | — | urxvt mouse mode |
| 1016 | — | SGR mouse pixel mode |
| 2004 | — | Bracketed paste: ESC [ 200 ~ ... ESC [ 201 ~ |
| 2026 | — | Synchronized update (batch output, prevent flicker) |
| 1047 | — | Use Alternate Screen Buffer (save/restore cursor) |
| 1048 | — | Save/restore cursor position (like ESC 7 / ESC 8) |
| 1049 | — | Save cursor + switch to Alternate Screen + clear it |

## Mouse Tracking (SGR mode, mode 1006)

Format: `ESC [ < b ; x ; y M` (press) or `ESC [ < b ; x ; y m` (release)

| b | Button / Event |
|---|----------------|
| 0 | Left button press |
| 1 | Middle button press |
| 2 | Right button press |
| 3 | Left button release |
| 4 | Middle button release |
| 5 | Right button release |
| 6 | Button 4 (wheel up) press |
| 7 | Button 4 release |
| 64 | Button 4 (wheel up) press (alt) |
| 65 | Button 4 release (alt) |
| 66 | Button 5 (wheel down) press (alt) |
| 67 | Button 5 release (alt) |
| 68 | Button 6 (wheel up) press |
| 69 | Button 6 release |
| 70 | Button 7 (wheel down) press |
| 71 | Button 7 release |

Modifiers are OR'd into b: 4=Shift, 8=Meta/Alt, 16=Ctrl.
Coordinates are 1-based. In SGR mode, no +32 offset.

## OSC (Operating System Command) — ESC ] Pt ST (or ESC ] Pt BEL)

| Code | Name | Effect |
|------|------|--------|
| 0 | — | Set window + icon title |
| 1 | — | Set icon title |
| 2 | — | Set window title |
| 4 | — | Query/set palette color: `4;n;?` (query) or `4;n;rgb:r/g/b` (set) |
| 10 | — | Query/set foreground: `10;?` or `10;rgb:r/g/b` |
| 11 | — | Query/set background: `11;?` or `11;rgb:r/g/b` |
| 12 | — | Query/set cursor color |
| 133 | — | Semantic prompt markers (shell integration) |
| 52 | — | Clipboard: `52;c;base64data` (set), `52;q` (query) |

Response format: `ESC ] P r ; P q ST` where Pr=0 (error) or 1 (success).

## DCS (Device Control String) — ESC P Pt ST

| Sequence | Name | Effect |
|----------|------|--------|
| ESC P 1 $ r Pt ST | DECRQSS response | Report status string |
| ESC P 0 $ r ST | DECRQSS error | Invalid request |
| ESC P 1 + r Pt ST | XTGETTCAP response | Termcap/terminfo data |
| ESC P 0 + r ST | XTGETTCAP error | Invalid request |
| ESC P 1 + R Pt ST | XTGETXRES response | Xterm resource values |

## DA (Device Attributes) — terminal identification

| Request | xterm Response | Meaning |
|---------|----------------|---------|
| ESC [ 0 c | ESC [ ? 6 ; 0 c | VT102 (primary DA) |
| ESC [ 0 c | ESC [ ? 6 2 ; 2 9 c | VT220 with ANSI color |
| ESC [ 0 c | ESC [ ? 6 3 ; 2 9 c | VT320 |
| ESC [ 0 c | ESC [ ? 6 4 ; 2 9 c | VT420 |
| ESC [ > 0 c | ESC [ > 6 4 ; 8 c | VT520 (secondary DA) |
| ESC [ = 0 c | — | Tertiary DA (VT400+) |

## ESC (Fe) Single-Character Functions

| Sequence | Name | Effect |
|----------|------|--------|
| ESC 7 | DECSC | Save cursor position + SGR state |
| ESC 8 | DECRC | Restore cursor position + SGR state |
| ESC c | RIS | Full Reset (terminal to initial state) |
| ESC = | DECKPAM | Application Keypad mode |
| ESC > | DECKPNM | Normal Keypad mode |
| ESC D | IND | Index (cursor down, wrap to next line) |
| ESC E | NEL | Next Line (CR + LF) |
| ESC M | RI | Reverse Index (cursor up) |
| ESC H | HTS | Set tab stop at current column |
| ESC SP F | S7C1T | Send C1 as 7-bit sequences |
| ESC SP G | S8C1T | Send C1 as 8-bit sequences |
| ESC # 8 | DECALN | Screen Alignment Test (fill with 'E') |
| ESC % G | — | Select UTF-8 character set |
| ESC ( B | — | Designate G0 = USASCII |
| ESC ) 0 | — | Designate G1 = DEC Line Drawing |

## termios Flags (macOS / BSD)

### Input flags (iflag)

| Flag | Value | Effect |
|------|-------|--------|
| IGNBRK | 0x0001 | Ignore BREAK signal |
| BRKINT | 0x0002 | INT on BREAK |
| IGNPAR | 0x0004 | Ignore parity errors |
| PARMRK | 0x0008 | Mark parity errors |
| ISTRIP | 0x0010 | Strip 8th bit |
| INLCR | 0x0040 | NL → CR-NL on input |
| IGNCR | 0x0080 | Ignore CR |
| ICRNL | 0x0100 | CR → NL on input |
| IXON | 0x0400 | Enable XON/XOFF (Ctrl-Q/Ctrl-S) |
| IXANY | 0x0800 | Any char resumes output |
| IXOFF | 0x1000 | Enable start/stop output |
| IMAXBEL | 0x2000 | Bell instead of discard on input overflow |
| IUTF8 | 0x4000 | Enable UTF-8 input (Linux) |

### Output flags (oflag)

| Flag | Value | Effect |
|------|-------|--------|
| OPOST | 0x0001 | Enable output processing |
| OLCUC | 0x0002 | Map lowercase to uppercase (output) |
| ONLCR | 0x0004 | NL → CR-NL on output |
| OCRNL | 0x0010 | Map CR to NL (output) |
| ONOCR | 0x0020 | No CR in column 1 |
| ONLRET | 0x0040 | NL performs CR function |
| OFILL | 0x0100 | Use fill char for timing |
| OFDSUS | 0x0200 | Stop output after EOF |
| NLDLY | 0x1000 | NL delay (bits 4-5) |
| CRDLY | 0x4000 | CR delay (bits 6-7) |
| TABDLY | 0x10000 | Tab expansion (bits 8-9) |
| BSDLY | 0x40000 | BS delay (bits 10-11) |
| VTDLY | 0x100000 | VT delay (bits 12-13) |
| FFDLY | 0x400000 | FF delay (bits 14-15) |

### Control flags (cflag)

| Flag | Value | Effect |
|------|-------|--------|
| CIGNPAR | 0x0001 | Ignore parity errors (input) |
| PARENB | 0x0002 | Enable parity generation/detection |
| PARODD | 0x0004 | Use odd parity |
| CSIZE | 0x0060 | Character size (mask) |
| CS5 | 0x0020 | 5 bits |
| CS6 | 0x0040 | 6 bits |
| CS7 | 0x0060 | 7 bits |
| CS8 | 0x0060 | 8 bits |
| CSTOPB | 0x0100 | 2 stop bits |
| CREAD | 0x0800 | Enable receiver |
| HUPCL | 0x1000 | Hang up on last close |
| CLOCAL | 0x2000 | Ignore modem status lines |

### Local flags (lflag)

| Flag | Value | Effect |
|------|-------|--------|
| SIGHUP | 0x0001 | Send SIGHUP on hangup |
| VLTIME | 0x0002 | (not a flag, cc index) |
| VMIN | 0x0004 | (not a flag, cc index) |
| DISFLN | 0x0004 | Flush output lines on DISCARD |
| DTATIME | 0x0008 | (not a flag) |
| ECHO | 0x0008 | Echo input chars |
| ECHOE | 0x0010 | Echo ERASE char |
| ECHOK | 0x0020 | Echo KILL char |
| ECHONL | 0x0040 | Echo NL even if no ECHO |
| ECHOCTL | 0x0080 | Echo control chars in hat notation |
| ECHOKE | 0x0100 | Redraw line after KILL |
| FLUSHO | 0x0200 | Discard output |
| PENDIN | 0x0400 | Re-transmit pending input |
| NOFLSH | 0x0800 | Disable flushing on SIGINT/SIGQUIT/SIGTSTP |
| TOSTOP | 0x1000 | Send SIGTTOU for background write |
| IEXTEN | 0x2000 | Enable extended input control |
| EXTCREF | 0x4000 | (not standard) |
| ICANON | 0x0200 | Canonical mode (line-buffered input) |
| XCASE | 0x0400 | Map lowercase to uppercase (input, with ECHO) |
| ALTWERASE | 0x0800 | Alternate word erase |
| ECHOCTL | 0x0080 | (see above) |
| ISIG | 0x0800 | Enable signal generation (Ctrl-C→SIGINT, etc.) |

**Note:** On macOS, `lflag` is 64 bits. The values above are the standard
POSIX values. `ICANON=0x0200`, `ECHO=0x0008`, `ISIG=0x0800`.

## Raw Mode (what run-pty-zig sets)

To enter raw mode for a TUI:
- Clear `ICANON` (0x0200) — disable line buffering
- Clear `ECHO` (0x0008) — disable echo
- KEEP `ISIG` (0x0800) — so Ctrl-C still generates SIGINT (safety net)
- Clear `ICRNL` (0x0100) from iflag — don't translate CR→NL
- Clear `INLCR` (0x0040) from iflag — don't translate NL→CR-NL
- Clear `IXON` (0x0400) from iflag — disable Ctrl-S/Ctrl-Q flow control
- Clear `OPOST` (0x0001) from oflag — disable output post-processing
- Set `VMIN=1`, `VTIME=0` — read returns after 1 byte, no timeout

## PTY / ioctl

| ioctl | Value (macOS) | Effect |
|-------|---------------|--------|
| TIOCGWINSZ | 0x40087468 | Get window size (rows, cols) |
| TIOCSWINSZ | 0x80087467 | Set window size |
| TIOCSCTTY | 0x0000746d | Make PTY the controlling terminal |

`struct winsize` fields: `row` (u16), `col` (u16), `xpixel` (u16), `ypixel` (u16).

## Terminal Detection

### Environment variables

| Variable | Meaning |
|----------|---------|
| TERM | Terminal type: `xterm-256color`, `screen-256color`, `dumb`, `vt100`, `linux`, `alacritty`, `ghostty`, `wezterm`, `kitty`, `iterm2`, `st-256color` |
| COLORTERM | `truecolor` or `24bit` indicates 24-bit color support |
| TERM_PROGRAM | Set by some emulators: `iTerm.app`, `WezTerm`, `ghostty`, `Hyper`, `WarpTerminal` |
| NO_COLOR | If set (even to empty string in some conventions), disable color. run-pty-zig: non-empty = disable. |
| CLICOLOR | If set to `0`, disable auto-color (macOS ls convention) |
| CLICOLOR_FORCE | If set to non-zero, force color even when not a TTY |
| VTE_VERSION | Set by VTE-based terminals (GNOME Terminal, Tilix, etc.) |
| KITTY_WINDOW_ID | Set by kitty terminal |
| TERMINFO_DIRS | Search path for terminfo databases |

### DA query (runtime detection)

Send `ESC [ 0 c` (Primary DA) or `ESC [ > 0 c` (Secondary DA) and read the
response. The response identifies the terminal family:
- `ESC [ ? 6 ; 0 c` → VT102
- `ESC [ ? 6 2 ; 2 9 c` → VT220 + ANSI color
- `ESC [ ? 6 3 ; 2 9 c` → VT320
- `ESC [ ? 6 4 ; 2 9 c` → VT420
- `ESC [ ? 6 5 ; 2 9 c` → VT510+

### Capability detection strategy

1. Check `TERM` for known terminal names
2. Check `COLORTERM` / `TERM_PROGRAM` for color level
3. Check `NO_COLOR` to disable
4. Optionally send DA query for runtime verification
5. Fall back to conservative defaults (8-color, no Unicode width assumptions)

## References

- ECMA-48 / ISO/IEC 6429: https://www.ecma-international.org/publications-and-standards/standards/ecma-48/
- xterm ctlseqs (Thomas Dickey): https://invisible-island.net/xterm/ctlseqs/ctlseqs.html
- Wikipedia ANSI escape code: https://en.wikipedia.org/wiki/ANSI_escape_code
- macOS man pages: `man 4 termios`, `man 4 tty`, `man 2 ioctl`
- vttest (xterm test suite): https://invisible-island.net/vttest/
