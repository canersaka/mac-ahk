# MacAHK

A native macOS macro recorder. Record everything you do — keystrokes,
clicks, drags, scrolls (with momentum), and trackpad gestures — then
replay it on a loop, at any speed, from a hotkey, the menu bar, or the
app window.

The design goal is *minimally invasive*: no kernel extensions, no
background daemons, no login items, no screen recording. It uses exactly
the two permissions macOS defines for this job (Input Monitoring to
record, Accessibility to replay) and nothing runs unless the app is open.

## What makes it different

Most macro tools interpret your input ("click at 200,300"). MacAHK
serializes the **raw CGEvent** — the actual bytes the window server saw —
and replays them verbatim. That means:

- scroll events keep their pixel deltas, phases, and momentum
- drags replay as real drags, not teleporting clicks
- trackpad gestures (pinch, rotate, swipe, smart-zoom, pressure) are
  captured, not dropped
- keystrokes keep exact modifier and repeat state

## Build the app

You need a Mac with the Xcode command line tools
(`xcode-select --install`). Then:

```
cd MacAHK
./build_app.sh
```

That builds the app and installs it straight into /Applications (use `--no-install` to skip that, or `--dmg` to also produce a shareable disk image). First
launch will walk you through the two permission grants (both point at
System Settings → Privacy & Security). Grant them **to MacAHK itself**,
not your terminal, then relaunch the app.

## Use

- **Record** (toolbar or menu bar): 3-second countdown, do your thing,
  **Esc** to finish, name it. Interactions with the MacAHK window itself
  are automatically excluded from recordings.
- **Play**: select a macro and hit Play, double-click it, use the menu
  bar item, or press its hotkey. Loops (0 = forever) and 0.25×–4× speed
  are in the macro's detail pane. **Esc always aborts instantly**, and
  any keys still held down get released so nothing sticks.
- **Hotkeys**: right-click a macro → *Set Hotkey…* and press a combo.
  Hotkeys work globally while the app runs, even with the window closed
  (it lives in the menu bar). There's also a **record hotkey** (set it in
  the status bar) that starts *and* stops recording from anywhere — its
  own keystrokes are filtered out of the recording.
- **Step editor**: every macro is an editable list of steps. Drag steps
  to reorder, select one and hit − to delete it, or hit ＋ to insert any
  action by hand: clicks (single/double/triple, any button), key
  presses, typed text, scrolls, pointer moves, and waits. Each step's
  delay is editable. *New Macro* in the sidebar starts from an empty
  list, no recording needed.
- Macros are plain JSON in `~/Library/Application Support/MacAHK/`.

## Pixel conditions

Steps, `waituntil`, and jumps can react to what's on screen: **pixel
color matches** (hover the cursor to pick a point and its color) and
**area looks like snapshot** (frame a region, capture a reference image,
playback compares live pixels against it with a tolerance slider). This
is the one feature that needs the **Screen Recording** permission — it's
requested only when you actually add a pixel condition, never at launch,
and it's used for nothing else. In scripts: `onlyif pixel 100 200
#FF8800 10` or `waituntil pixel 100 200 #00FF00, 30`.



## Known limits

- Replayed trackpad gestures are posted back through the window server;
  most apps honor them, but apps that read raw multitouch data directly
  from the trackpad driver will ignore synthetic gestures. There is no
  public API that can do better.
- macOS Secure Input blocks recording in password fields, by design.
- Permissions are tied to the app's code signature: after rebuilding
  from source you may need to re-toggle the grants in System Settings.

## Script version

The original single-file Python version (records clicks/keys with
timing, GUI, CLI playback) still lives at `mac_ahk.py` — handy if you
want something hackable. The native app supersedes it.
