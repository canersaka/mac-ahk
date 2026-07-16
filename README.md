# mac-ahk

A small macro recorder for macOS. Record your mouse clicks and keystrokes
with their real timing, save them as named macros, replay them on a loop at
any speed, and bind them to global hotkeys.

Think "the 20% of AutoHotkey people actually use", without the scripting
language, and without installing anything invasive: no kernel extensions,
no background daemons, no login items, no screen recording permission.
It's one Python file and one dependency, and nothing runs unless the app
is open.

## Install

```
pip3 install pynput --break-system-packages
```

Then grant your terminal app (Terminal, iTerm, etc.) two permissions under
**System Settings → Privacy & Security**:

- **Accessibility** — required to synthesize clicks and keystrokes
- **Input Monitoring** — required to record them

You only do this once. If recording silently captures nothing or playback
does nothing, it's almost always a missing permission — toggle it off and
on again and restart the terminal.

## Use

```
python3 mac_ahk.py
```

- **Record** starts a 3-second countdown (so you can switch to the target
  window), then captures everything you do. Press **Esc** to finish, give
  the macro a name, done. Clicks on the mac-ahk window itself are filtered
  out of the recording.
- **Play** replays the selected macro (double-clicking a macro also plays
  it). Set the loop count (0 = repeat forever) and drag the speed slider
  from 0.25× to 4×. **Esc aborts playback at any moment**, even mid-loop.
- **Hotkey…** binds a global key combo to the selected macro, so you can
  fire it while the app sits in the background.
- The status bar shows a live cursor position readout, useful for checking
  coordinates.
- Optionally tick **Capture mouse movement** to record the full cursor
  path (smoother, more human playback, bigger macro files). Off by
  default — clicks jump straight to their target.

Macros are plain JSON in `~/.mac-ahk/`, so you can inspect them, edit
timings by hand, or check them into a dotfiles repo.

## CLI

For cron jobs or scripting:

```
python3 mac_ahk.py list
python3 mac_ahk.py play "my macro" --loops 10 --speed 1.5
```

## Safety notes

- Esc is a hard stop for both recording and playback.
- Playback releases any keys still held down when it ends, so an aborted
  run can't leave a modifier stuck.
- Keystrokes typed into password fields are not recordable — macOS Secure
  Input blocks all listeners there by design. Don't put passwords in
  macros anyway.

## Limits (honesty section)

This replays input as *you*, into whatever is focused on screen. It does
not click buttons in background windows, read pixels, or wait for UI state
— those need the Accessibility tree or screen capture, which is exactly
the invasive surface this tool avoids. If you outgrow it, look at
Hammerspoon or Keyboard Maestro.
