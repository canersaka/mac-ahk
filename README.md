# MacAHK

My take on AutoHotkey for the Mac. It records everything I do (keystrokes, clicks, drags, scrolls with momentum, trackpad gestures) and replays it on a loop, at any speed, from a hotkey, the menu bar, or the app window. On top of that it does text expansion, app-aware waits, clipboard tricks, image search, and it can import a good chunk of real AutoHotkey scripts.

I wanted it to be minimally invasive: no kernel extensions, no background daemons, no login items. It uses the two permissions macOS defines for this job (Input Monitoring to record, Accessibility to replay), plus an optional Screen Recording grant that is only requested if you actually use the screen-reading features. Nothing runs unless the app is open.

## Why it replays better than most recorders

Most macro tools interpret your input ("click at 200,300"). MacAHK serializes the raw CGEvent, the actual bytes the window server saw, and replays them verbatim. That means:

- scroll events keep their pixel deltas, phases, and momentum
- drags replay as real drags, not teleporting clicks
- trackpad gestures (pinch, rotate, swipe, smart zoom, pressure) are captured, not dropped
- keystrokes keep exact modifier and repeat state

## Feature tour

**Recording.** Hit Record (toolbar, menu bar, or a global record hotkey you can set in the status bar), do your thing, press Esc to finish, name it. There is a 3 second countdown so you can switch to the target app, and anything you do inside the MacAHK window itself is excluded automatically. Optionally record the full mouse path, not just clicks.

**Playback.** Play from the app, the menu bar, or a per-macro global hotkey. Loops (0 means forever) and 0.25x to 4x speed. Esc always aborts instantly (checked straight from the keyboard state, so it works no matter which app is frontmost), and any keys still held down get released so nothing sticks. With the macro's editor open, the step being executed is highlighted live and kept in view.

**Step editor.** Every macro is an editable list of steps. Drag to reorder, double-click to edit, duplicate, delete. Editing a step can also change what it does entirely — recorded events included, via the "Replace with" dropdown. Add any action by hand:

- clicks (single/double/triple, any button), pointer moves, scrolls
- key presses and typed text
- open an app by name, bundle id, or path (activates it if already running)
- open a URL in the default handler
- set the clipboard, or paste it with a synthetic Cmd+V
- click an image on screen: capture a small snapshot once, and playback scans the whole screen for wherever it is now and clicks its center (a full ImageSearch)
- show a notification banner or beep, great as checkpoints in long macros
- wait, wait-until, go-to-step (with an optional jump limit), stop playback

**Repeats and timing.** Any step can repeat N times with a fixed interval or a randomized range, so a click loop does not look metronomic. Every step's delay is editable.

**Conditions.** Any step can carry an "only if" condition, and the same conditions power wait-until and conditional jumps:

- a key, mouse button, or modifier combo is held (or not held)
- the pointer is inside a region
- a pixel matches a color, or an area looks like a saved snapshot
- an image is somewhere on screen
- a specific app is frontmost
- a window title containing some text exists
- the clipboard contains some text

Every condition can be negated. The app-aware ones are what make macros robust: "wait until Safari is frontmost", "only click if the Save dialog is up", that kind of thing.

**Hotstrings.** System-wide text expansion, exactly like AHK's `::btw::by the way`. Manage them from the status bar (add, edit, toggle, delete), or import them straight from an AHK script. Type the trigger anywhere and it is erased and replaced by the expansion. Expansion pauses automatically while recording or playing so it never corrupts a macro.

**Scripting.** Every macro can be exported as plain text (right-click, Copy as Script) and scripts can be imported to create macros. The language is line-based and covers clicks, keys, send, scroll, run, winwait, clipboard, paste, notify, beep, waituntil, goto, repeat, and only-if conditions. It also accepts a useful subset of AutoHotkey v1 directly: hotkey labels like `F6::`, `Send` with `{Enter}` style tokens, `^!a` modifier symbols, `Sleep`, `Run`, `WinActivate`, `WinWait`, `IfWinActive`, `MsgBox`, and `::hotstrings::`. Anything that does not translate is listed as a warning instead of silently vanishing.

```
; example: click loop while F6 is held
F6::
run Safari
winwait Safari, 5
click 500, 400
repeat 1000, 0.1, 0.3
onlyif key f6
notify done
::btw::by the way
```

**Storage.** Macros are plain JSON files in `~/Library/Application Support/MacAHK/`, one per macro, so they are easy to back up, diff, and share. Hotstrings live in a single `hotstrings.json` next to them.

## Build and install

You need a Mac with the Xcode command line tools (`xcode-select --install`). Then:

```
cd MacAHK
./build_app.sh
```

That builds the app and installs it into /Applications. Use `--no-install` to skip the install step, or `--dmg` to also produce a shareable disk image.

First launch walks you through the permission grants (both point at System Settings, Privacy & Security). Grant them to MacAHK itself, not your terminal, then relaunch the app. If a toggle seems stuck after a rebuild, run `./build_app.sh --reset-perms` and grant fresh.

## Permissions, in plain terms

- **Input Monitoring**: needed to record your input. Requested at first launch.
- **Accessibility**: needed to post synthetic input during playback and hotstring expansion. Requested at first launch.
- **Screen Recording**: only needed by the pixel color, snapshot, and image search features. Requested the first time you configure one of those, never at launch, and used for nothing else. Window titles in the "window title contains" condition are also only visible with this grant; without it the condition still matches app names.

## Known limits

- Replayed trackpad gestures are posted back through the window server; most apps honor them, but apps that read raw multitouch data directly from the trackpad driver will ignore synthetic gestures. There is no public API that can do better.
- macOS Secure Input blocks recording in password fields, by design. Hotstrings will not expand there either.
- The full-screen image search is honest work, not magic: expect a few hundred milliseconds per scan, so prefer the fixed-region snapshot condition when you know where things are.
- Permissions are tied to the app's code signature: after rebuilding from source you may need to re-toggle the grants in System Settings.

## Script version

The original single-file Python version (records clicks and keys with timing, GUI, CLI playback) still lives at `mac_ahk.py`, with its one dependency in `requirements.txt`. It is handy if you want something hackable from a terminal; the native app supersedes it.
