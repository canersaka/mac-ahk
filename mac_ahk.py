#!/usr/bin/env python3
"""
mac-ahk — a tiny macro recorder/player for macOS.

Record mouse clicks and keystrokes with their real timing, save them as
named macros, replay them with a loop count and speed multiplier, and
bind them to global hotkeys. One window, no daemons, no screen recording.

Needs: pip install pynput
Permissions (one-time, for your terminal app):
  System Settings -> Privacy & Security -> Accessibility
  System Settings -> Privacy & Security -> Input Monitoring

Run the GUI:      python3 mac_ahk.py
Play from CLI:    python3 mac_ahk.py play "macro name" [--loops N] [--speed X]
List macros:      python3 mac_ahk.py list
"""

import argparse
import json
import queue
import re
import sys
import threading
import time
from pathlib import Path

try:
    from pynput import keyboard, mouse
    from pynput.keyboard import Key, KeyCode
except ImportError:
    print("pynput is missing. Install it with:\n"
          "  pip3 install pynput --break-system-packages")
    sys.exit(1)

STORE_DIR = Path.home() / ".mac-ahk"
MOVE_INTERVAL = 0.02  # max mouse-move sample rate while recording (50 Hz)

MODIFIER_KEYS = {
    Key.cmd: "cmd", Key.cmd_l: "cmd", Key.cmd_r: "cmd",
    Key.ctrl: "ctrl", Key.ctrl_l: "ctrl", Key.ctrl_r: "ctrl",
    Key.alt: "alt", Key.alt_l: "alt", Key.alt_r: "alt",
    Key.shift: "shift", Key.shift_l: "shift", Key.shift_r: "shift",
}


# ---------------------------------------------------------------- storage

def slugify(name):
    slug = re.sub(r"[^a-zA-Z0-9._-]+", "-", name.strip()).strip("-")
    return slug or "macro"


def macro_path(name):
    return STORE_DIR / (slugify(name) + ".json")


def load_macros():
    """Return {name: data} for every saved macro, sorted by name."""
    STORE_DIR.mkdir(exist_ok=True)
    macros = {}
    for f in sorted(STORE_DIR.glob("*.json")):
        try:
            data = json.loads(f.read_text())
            if isinstance(data, dict) and "events" in data:
                macros[data.get("name", f.stem)] = data
        except (json.JSONDecodeError, OSError):
            continue
    return macros


def save_macro(data):
    STORE_DIR.mkdir(exist_ok=True)
    macro_path(data["name"]).write_text(json.dumps(data, indent=1))


def delete_macro(name):
    try:
        macro_path(name).unlink()
    except FileNotFoundError:
        pass


# ------------------------------------------------------- key serialization

def encode_key(key):
    """Turn a pynput key object into a JSON-safe dict."""
    if isinstance(key, Key):
        return {"kind": "special", "name": key.name}
    if isinstance(key, KeyCode):
        if key.char is not None:
            return {"kind": "char", "char": key.char}
        return {"kind": "vk", "vk": key.vk}
    return None


def decode_key(spec):
    if spec["kind"] == "special":
        return getattr(Key, spec["name"], None)
    if spec["kind"] == "char":
        return spec["char"]
    if spec["kind"] == "vk":
        return KeyCode.from_vk(spec["vk"])
    return None


# ----------------------------------------------------------------- recorder

class Recorder:
    """Captures mouse and keyboard events with timestamps.

    Esc always ends a recording and is not stored. Click events that land
    inside `exclude_rect` (the app's own window) are dropped so stopping
    a recording with the Stop button doesn't leave stray clicks in the
    macro.
    """

    def __init__(self, record_moves=False, on_stop=None):
        self.record_moves = record_moves
        self.on_stop = on_stop  # called from listener thread when Esc hit
        self.events = []
        self.exclude_rect = None  # (x1, y1, x2, y2)
        self._t0 = None
        self._last_move = 0.0
        self._lock = threading.Lock()
        self._mouse_listener = None
        self._key_listener = None
        self.running = False

    def _now(self):
        return time.perf_counter() - self._t0

    def _add(self, ev):
        with self._lock:
            self.events.append(ev)

    def start(self):
        self.events = []
        self._t0 = time.perf_counter()
        self._last_move = 0.0
        self.running = True
        self._mouse_listener = mouse.Listener(
            on_click=self._on_click, on_scroll=self._on_scroll,
            on_move=self._on_move if self.record_moves else None)
        self._key_listener = keyboard.Listener(
            on_press=self._on_press, on_release=self._on_release)
        self._mouse_listener.start()
        self._key_listener.start()

    def stop(self):
        if not self.running:
            return
        self.running = False
        if self._mouse_listener:
            self._mouse_listener.stop()
        if self._key_listener:
            self._key_listener.stop()
        if self.exclude_rect:
            x1, y1, x2, y2 = self.exclude_rect
            self.events = [
                ev for ev in self.events
                if not (ev["type"] in ("click", "scroll")
                        and x1 <= ev["x"] <= x2 and y1 <= ev["y"] <= y2)]

    # listener callbacks (run on pynput threads)

    def _on_click(self, x, y, button, pressed):
        if not self.running:
            return
        self._add({"t": self._now(), "type": "click", "x": x, "y": y,
                   "button": button.name, "pressed": pressed})

    def _on_scroll(self, x, y, dx, dy):
        if not self.running:
            return
        self._add({"t": self._now(), "type": "scroll", "x": x, "y": y,
                   "dx": dx, "dy": dy})

    def _on_move(self, x, y):
        if not self.running:
            return
        t = self._now()
        if t - self._last_move >= MOVE_INTERVAL:
            self._last_move = t
            self._add({"t": t, "type": "move", "x": x, "y": y})

    def _on_press(self, key):
        if not self.running:
            return
        if key == Key.esc:
            if self.on_stop:
                self.on_stop()
            return
        spec = encode_key(key)
        if spec:
            self._add({"t": self._now(), "type": "key", "pressed": True,
                       "key": spec})

    def _on_release(self, key):
        if not self.running or key == Key.esc:
            return
        spec = encode_key(key)
        if spec:
            self._add({"t": self._now(), "type": "key", "pressed": False,
                       "key": spec})


# ------------------------------------------------------------------- player

class Player:
    """Replays a recorded event list. Esc aborts at any time."""

    def __init__(self, on_progress=None, on_done=None):
        self.on_progress = on_progress  # fn(loop, total_loops)
        self.on_done = on_done          # fn(aborted: bool)
        self._abort = threading.Event()
        self._thread = None
        self.running = False

    def play(self, events, loops=1, speed=1.0):
        if self.running or not events:
            return False
        self._abort.clear()
        self.running = True
        self._thread = threading.Thread(
            target=self._run, args=(list(events), loops, speed), daemon=True)
        self._thread.start()
        return True

    def stop(self):
        self._abort.set()

    def _run(self, events, loops, speed):
        mouse_ctl = mouse.Controller()
        key_ctl = keyboard.Controller()
        esc_listener = keyboard.Listener(
            on_press=lambda k: self._abort.set() if k == Key.esc else None)
        esc_listener.start()
        aborted = False
        try:
            loop = 0
            while not self._abort.is_set():
                loop += 1
                if self.on_progress:
                    self.on_progress(loop, loops)
                prev_t = 0.0
                for ev in events:
                    delay = (ev["t"] - prev_t) / speed
                    prev_t = ev["t"]
                    if delay > 0 and self._abort.wait(delay):
                        break
                    self._fire(ev, mouse_ctl, key_ctl)
                if loops and loop >= loops:
                    break
            aborted = self._abort.is_set()
        finally:
            # release anything left held down so keys don't stick
            for ev in events:
                if ev["type"] == "key":
                    k = decode_key(ev["key"])
                    if k is not None:
                        try:
                            key_ctl.release(k)
                        except Exception:
                            pass
            esc_listener.stop()
            self.running = False
            if self.on_done:
                self.on_done(aborted)

    @staticmethod
    def _fire(ev, mouse_ctl, key_ctl):
        try:
            if ev["type"] == "click":
                mouse_ctl.position = (ev["x"], ev["y"])
                btn = getattr(mouse.Button, ev["button"], mouse.Button.left)
                if ev["pressed"]:
                    mouse_ctl.press(btn)
                else:
                    mouse_ctl.release(btn)
            elif ev["type"] == "move":
                mouse_ctl.position = (ev["x"], ev["y"])
            elif ev["type"] == "scroll":
                mouse_ctl.position = (ev["x"], ev["y"])
                mouse_ctl.scroll(ev["dx"], ev["dy"])
            elif ev["type"] == "key":
                k = decode_key(ev["key"])
                if k is None:
                    return
                if ev["pressed"]:
                    key_ctl.press(k)
                else:
                    key_ctl.release(k)
        except Exception:
            pass  # a single bad event shouldn't kill the whole run


# ------------------------------------------------------------------ hotkeys

class HotkeyManager:
    """One GlobalHotKeys listener rebuilt whenever bindings change."""

    def __init__(self, trigger):
        self.trigger = trigger  # fn(macro_name), called from listener thread
        self._listener = None
        self.enabled = True

    def rebuild(self, macros):
        if self._listener:
            self._listener.stop()
            self._listener = None
        mapping = {}
        for name, data in macros.items():
            combo = data.get("hotkey")
            if combo:
                mapping[combo] = (lambda n=name:
                                  self.trigger(n) if self.enabled else None)
        if mapping:
            try:
                self._listener = keyboard.GlobalHotKeys(mapping)
                self._listener.start()
            except ValueError:
                self._listener = None

    def shutdown(self):
        if self._listener:
            self._listener.stop()
            self._listener = None


# ---------------------------------------------------------------------- gui

def run_gui():
    import tkinter as tk
    from tkinter import messagebox, simpledialog, ttk

    root = tk.Tk()
    root.title("mac-ahk")
    root.geometry("560x420")
    root.minsize(480, 360)

    macros = load_macros()
    ui_queue = queue.Queue()
    state = {"mode": "idle", "recorder": None, "selected": None}

    # ---- layout ----
    main = ttk.Frame(root, padding=10)
    main.pack(fill="both", expand=True)

    left = ttk.Frame(main)
    left.pack(side="left", fill="both", expand=True)
    ttk.Label(left, text="Macros").pack(anchor="w")
    listbox = tk.Listbox(left, activestyle="dotbox", exportselection=False)
    listbox.pack(fill="both", expand=True, pady=(2, 6))

    lb_buttons = ttk.Frame(left)
    lb_buttons.pack(fill="x")

    right = ttk.Frame(main, padding=(12, 0, 0, 0))
    right.pack(side="right", fill="y")

    record_btn = ttk.Button(right, text="●  Record")
    record_btn.pack(fill="x", pady=(18, 4))
    play_btn = ttk.Button(right, text="▶  Play")
    play_btn.pack(fill="x", pady=4)
    stop_btn = ttk.Button(right, text="■  Stop  (Esc)", state="disabled")
    stop_btn.pack(fill="x", pady=4)

    opts = ttk.LabelFrame(right, text="Playback", padding=8)
    opts.pack(fill="x", pady=(14, 4))
    ttk.Label(opts, text="Loops (0 = forever)").pack(anchor="w")
    loops_var = tk.IntVar(value=1)
    ttk.Spinbox(opts, from_=0, to=99999, textvariable=loops_var,
                width=8).pack(anchor="w", pady=(0, 6))
    ttk.Label(opts, text="Speed").pack(anchor="w")
    speed_var = tk.DoubleVar(value=1.0)
    speed_label = ttk.Label(opts, text="1.0×")
    ttk.Scale(opts, from_=0.25, to=4.0, variable=speed_var,
              command=lambda _v: speed_label.config(
                  text=f"{speed_var.get():.2f}×")).pack(fill="x")
    speed_label.pack(anchor="w")

    rec_opts = ttk.LabelFrame(right, text="Recording", padding=8)
    rec_opts.pack(fill="x", pady=4)
    moves_var = tk.BooleanVar(value=False)
    ttk.Checkbutton(rec_opts, text="Capture mouse movement",
                    variable=moves_var).pack(anchor="w")

    status_var = tk.StringVar(value="Ready.")
    pos_var = tk.StringVar(value="")
    statusbar = ttk.Frame(root, padding=(10, 4))
    statusbar.pack(fill="x", side="bottom")
    ttk.Label(statusbar, textvariable=status_var).pack(side="left")
    ttk.Label(statusbar, textvariable=pos_var).pack(side="right")

    # ---- helpers ----
    def refresh_list():
        listbox.delete(0, "end")
        for name, data in macros.items():
            hk = data.get("hotkey")
            n_events = len(data.get("events", []))
            label = f"{name}   ({n_events} events"
            label += f", {hk})" if hk else ")"
            listbox.insert("end", label)

    def selected_name():
        sel = listbox.curselection()
        if not sel:
            return None
        return list(macros.keys())[sel[0]]

    def set_mode(mode):
        state["mode"] = mode
        busy = mode != "idle"
        record_btn.config(state="disabled" if busy else "normal")
        play_btn.config(state="disabled" if busy else "normal")
        stop_btn.config(state="normal" if busy else "disabled")
        hotkeys.enabled = not busy

    # ---- recording ----
    def start_record():
        if state["mode"] != "idle":
            return
        set_mode("countdown")

        def tick(n):
            if n == 0:
                begin()
                return
            status_var.set(f"Recording starts in {n}…  switch to your "
                           "target window")
            root.after(1000, tick, n - 1)

        def begin():
            rec = Recorder(record_moves=moves_var.get(),
                           on_stop=lambda: ui_queue.put(("rec_done", None)))
            state["recorder"] = rec
            rec.start()
            set_mode("recording")
            status_var.set("Recording — press Esc (or Stop) to finish.")

        tick(3)

    def finish_record():
        rec = state["recorder"]
        state["recorder"] = None
        if rec is None:
            set_mode("idle")
            return
        rec.exclude_rect = (root.winfo_rootx(), root.winfo_rooty(),
                            root.winfo_rootx() + root.winfo_width(),
                            root.winfo_rooty() + root.winfo_height())
        rec.stop()
        set_mode("idle")
        if not rec.events:
            status_var.set("Nothing recorded.")
            return
        name = simpledialog.askstring(
            "Save macro", f"Recorded {len(rec.events)} events.\nName:",
            parent=root)
        if not name:
            status_var.set("Recording discarded.")
            return
        data = {"name": name, "created": time.strftime("%Y-%m-%d %H:%M"),
                "hotkey": macros.get(name, {}).get("hotkey"),
                "events": rec.events}
        macros[name] = data
        save_macro(data)
        refresh_list()
        hotkeys.rebuild(macros)
        status_var.set(f"Saved '{name}'.")

    # ---- playback ----
    player = Player(
        on_progress=lambda lp, total: ui_queue.put(("progress", (lp, total))),
        on_done=lambda aborted: ui_queue.put(("play_done", aborted)))

    def start_play(name=None):
        if state["mode"] != "idle":
            return
        name = name or selected_name()
        if not name:
            status_var.set("Select a macro first.")
            return
        data = macros.get(name)
        if not data:
            return
        state["selected"] = name
        set_mode("playing")
        player.play(data["events"], loops=loops_var.get(),
                    speed=max(speed_var.get(), 0.05))

    def stop_all():
        if state["mode"] == "recording":
            finish_record()
        elif state["mode"] == "playing":
            player.stop()

    # ---- hotkeys ----
    hotkeys = HotkeyManager(
        trigger=lambda name: ui_queue.put(("hotkey", name)))
    hotkeys.rebuild(macros)

    def assign_hotkey():
        name = selected_name()
        if not name:
            status_var.set("Select a macro first.")
            return
        dlg = tk.Toplevel(root)
        dlg.title("Set hotkey")
        dlg.geometry("340x120")
        dlg.transient(root)
        ttk.Label(dlg, text=f"Press a key combo for '{name}'\n"
                            "(Esc cancels, Backspace clears)",
                  justify="center").pack(pady=10)
        combo_var = tk.StringVar(value="…")
        ttk.Label(dlg, textvariable=combo_var,
                  font=("Menlo", 14)).pack()

        pressed_mods = set()
        result = {}

        def on_press(key):
            if key in MODIFIER_KEYS:
                pressed_mods.add(MODIFIER_KEYS[key])
                combo_var.set("+".join(sorted(pressed_mods)) + "+…")
                return
            if key == Key.esc:
                result["combo"] = "cancel"
            elif key == Key.backspace and not pressed_mods:
                result["combo"] = None
            else:
                parts = [f"<{m}>" for m in sorted(pressed_mods)]
                if isinstance(key, Key):
                    parts.append(f"<{key.name}>")
                elif key.char:
                    parts.append(key.char.lower())
                else:
                    parts.append(f"<{key.vk}>")
                result["combo"] = "+".join(parts)
            return False  # stop listener

        def on_release(key):
            pressed_mods.discard(MODIFIER_KEYS.get(key))

        cap = keyboard.Listener(on_press=on_press, on_release=on_release)
        hotkeys.enabled = False
        cap.start()

        def poll():
            if "combo" in result:
                cap.stop()
                hotkeys.enabled = True
                dlg.destroy()
                if result["combo"] != "cancel":
                    macros[name]["hotkey"] = result["combo"]
                    save_macro(macros[name])
                    refresh_list()
                    hotkeys.rebuild(macros)
                    status_var.set(
                        f"Hotkey for '{name}': {result['combo'] or 'none'}")
                return
            if dlg.winfo_exists():
                dlg.after(50, poll)
            else:
                cap.stop()
                hotkeys.enabled = True

        poll()

    def remove_macro():
        name = selected_name()
        if not name:
            return
        if messagebox.askyesno("Delete", f"Delete macro '{name}'?",
                               parent=root):
            delete_macro(name)
            macros.pop(name, None)
            refresh_list()
            hotkeys.rebuild(macros)
            status_var.set(f"Deleted '{name}'.")

    ttk.Button(lb_buttons, text="Hotkey…",
               command=assign_hotkey).pack(side="left")
    ttk.Button(lb_buttons, text="Delete",
               command=remove_macro).pack(side="right")

    record_btn.config(command=start_record)
    play_btn.config(command=lambda: start_play())
    stop_btn.config(command=stop_all)
    listbox.bind("<Double-Button-1>", lambda _e: start_play())

    # ---- event pump: listener threads -> tk ----
    def pump():
        try:
            while True:
                kind, payload = ui_queue.get_nowait()
                if kind == "rec_done":
                    finish_record()
                elif kind == "hotkey":
                    start_play(payload)
                elif kind == "progress":
                    lp, total = payload
                    total_s = str(total) if total else "∞"
                    status_var.set(f"Playing '{state['selected']}' — loop "
                                   f"{lp}/{total_s} — Esc stops.")
                elif kind == "play_done":
                    set_mode("idle")
                    status_var.set("Stopped." if payload else "Done.")
        except queue.Empty:
            pass
        root.after(50, pump)

    # live cursor position readout, handy for sanity-checking coordinates
    mouse_reader = mouse.Controller()

    def track_pos():
        try:
            x, y = mouse_reader.position
            pos_var.set(f"cursor: {int(x)}, {int(y)}")
        except Exception:
            pos_var.set("")
        root.after(150, track_pos)

    def on_close():
        stop_all()
        hotkeys.shutdown()
        root.destroy()

    root.protocol("WM_DELETE_WINDOW", on_close)
    refresh_list()
    pump()
    track_pos()
    root.mainloop()


# ---------------------------------------------------------------------- cli

def run_cli(argv):
    parser = argparse.ArgumentParser(prog="mac_ahk.py",
                                     description="macro recorder/player")
    sub = parser.add_subparsers(dest="cmd")
    p_play = sub.add_parser("play", help="play a saved macro")
    p_play.add_argument("name")
    p_play.add_argument("--loops", type=int, default=1,
                        help="0 = repeat until Esc")
    p_play.add_argument("--speed", type=float, default=1.0)
    sub.add_parser("list", help="list saved macros")
    args = parser.parse_args(argv)

    if args.cmd == "list":
        for name, data in load_macros().items():
            hk = data.get("hotkey") or "-"
            print(f"{name:30s} {len(data['events']):5d} events   hotkey: {hk}")
        return

    if args.cmd == "play":
        macros = load_macros()
        data = macros.get(args.name)
        if not data:
            print(f"No macro named '{args.name}'. Saved macros:")
            for n in macros:
                print(f"  {n}")
            sys.exit(1)
        done = threading.Event()
        player = Player(
            on_progress=lambda lp, total:
                print(f"loop {lp}/{total or '∞'}", flush=True),
            on_done=lambda _aborted: done.set())
        print("Playing in 3 seconds — Esc aborts.")
        time.sleep(3)
        player.play(data["events"], loops=args.loops,
                    speed=max(args.speed, 0.05))
        done.wait()
        return

    run_gui()


if __name__ == "__main__":
    if sys.platform != "darwin":
        print("Heads up: this is built for macOS; recording/playback "
              "hooks may not work elsewhere.")
    run_cli(sys.argv[1:])
