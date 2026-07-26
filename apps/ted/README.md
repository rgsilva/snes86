# TED — the text editor

A modeless, nano-spirit visual editor in Turbo Pascal 3, built
controller-first for snes86: the d-pad moves the cursor, SELECT opens the
on-screen keyboard, and **Y (Esc) opens the status-row menu** (Save / save
As / Load / seaRch / Goto / Undo / Quit) so commands cost zero keyboard
trips. It runs on the standard 108 KB machine; saving to `B:` writes
battery-backed cartridge SRAM, so edits survive power-off.

```
C:\TED> TED [file]
```

Limits: 2000 lines, 255 chars per line, text bounded by free RAM. Long
lines pan under the cursor; TABs display at 8-column stops but stay TAB
bytes in the file.

## Keys

Editing is modeless: printable characters insert, Enter splits the line,
Backspace / Del edit and join. Movement:

| Key | Action |
| --- | --- |
| arrows | move (left/right cross line ends) |
| Home / End | start / end of line |
| PgUp / PgDn | move 23 lines |

### Direct commands (keyboard-only)

Every menu function has a direct binding — F-keys are the advertised set
(they're on the on-screen keyboard's F-row too), with Ctrl fallbacks for
plain typing. `^X` means Ctrl+X.

| Function | F-key | Ctrl | Menu letter |
| --- | --- | --- | --- |
| Help (bindings, 2 pages) | F1 | — | — |
| Save | F2 | ^S | S |
| Load | F3 | ^L or ^O | L |
| Save As | F4 | ^A | A |
| Search | F5 | ^F | R |
| Goto line | F6 | ^G | G |
| Undo line | F7 | ^U | U |
| Menu | F10 | Esc | — |
| Quit | — | ^Q | Q |

Ctrl+H is Backspace, Ctrl+I is Tab and Ctrl+M is Enter, as tradition
demands — that's why Help, Menu and Quit lean on F1/F10/^Q instead of the
letters you might expect.

The Esc menu still works exactly as before: d-pad (or arrow keys) +
Enter, or the highlighted hotkey letter.

## Undo

`Undo` restores the current line to its state when the cursor arrived on
it — a one-line, one-level safety net, not a history.

## Tests

- `ted-host` / `ted-host-keys` (snes/test/suite.sh): round-trip files
  through TED under runpc via piped stdin; the `-keys` leg drives every
  Ctrl binding. F-keys can't ride runpc's stdin (the scancode is derived
  from the ASCII there), so:
- `t_ted.lua` / `t_tedfk.lua` (Mesen): the SNES-side legs; `t_tedfk`
  injects real F-key scancode words into the INT16 ring and walks every
  F binding plus ^Q.

`ted.com` is not committed — every image build compiles it from source
(`make recompile` drives the real TP3 IDE under runpc; note TP3 stamps
its load segment into the binary, so compare behavior, not bytes).
