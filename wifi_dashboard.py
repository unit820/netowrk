#!/usr/bin/env python3
"""
WiFi Tactical Dashboard — controls wifi.sh daemon backend.
Educational use only.
"""

import json
import math
import os
import queue
import shutil
import signal
import subprocess
import sys
import threading
import time
import tkinter as tk
from tkinter import messagebox, ttk


# ---------------------------------------------------------------------------
# Theme
# ---------------------------------------------------------------------------
BG = "#05080c"
BG_DEEP = "#030508"
PANEL = "#0b1118"
PANEL_HI = "#111a24"
FG = "#3dffa0"
FG_SOFT = "#6dffc0"
FG_DIM = "#2a4a3a"
RED = "#ff4466"
RED_BRIGHT = "#ff6680"
RED_GLOW = "#ff2244"
YELLOW = "#ffd54f"
CYAN = "#4fc3f7"
BORDER = "#1e2d3d"
BORDER_HI = "#2a4055"
ACCENT = "#00e676"
OFFLINE = "#5a6a7a"
NEW_NET = "#80deea"

SPEED_PROFILES = {
    "low": {"radar_ms": 120, "sweep_step": 2, "sonar_every": 30, "attack_every": 12},
    "medium": {"radar_ms": 90, "sweep_step": 4, "sonar_every": 22, "attack_every": 8},
    "high": {"radar_ms": 55, "sweep_step": 6, "sonar_every": 16, "attack_every": 5},
    "turbo": {"radar_ms": 35, "sweep_step": 9, "sonar_every": 10, "attack_every": 3},
    "ultra": {"radar_ms": 30, "sweep_step": 10, "sonar_every": 8, "attack_every": 2},
    "hyper": {"radar_ms": 25, "sweep_step": 11, "sonar_every": 6, "attack_every": 2},
    "extreme": {"radar_ms": 18, "sweep_step": 13, "sonar_every": 4, "attack_every": 1},
}

# Fixed UI refresh — decoupled from attack speed so the dashboard stays smooth.
UI_RADAR_MS = 140
UI_POLL_SCAN_MS = 550
UI_POLL_ACTIVE_MS = 650
UI_POLL_IDLE_MS = 900
UI_TREE_REFRESH_SEC = 2.0

FAST_SPEEDS = frozenset({"high", "turbo", "ultra", "hyper", "extreme"})

SONAR_GREEN = "#2dff8a"
SONAR_GLOW = "#1a6b4a"
SCAN_CYAN = "#56e8ff"
ATTACK_ORANGE = "#ff6b35"
ATTACK_DEEP = "#8b0000"
PHOSPHOR = "#1a3d2e"


class SonarAudio:
    """Submarine-style sonar audio — runs off the UI thread."""
    _lock = threading.Lock()
    _last: dict[str, float] = {}
    _cooldowns = {"sonar": 1.8, "scan_ping": 1.1, "contact": 0.1, "attack": 0.55, "lock": 0.35}

    @classmethod
    def _throttle(cls, key: str, minimum: float) -> bool:
        now = time.time()
        if now - cls._last.get(key, 0) < minimum:
            return True
        cls._last[key] = now
        return False

    @classmethod
    def _beep(cls, freq: int, length_ms: int) -> None:
        try:
            subprocess.run(
                ["beep", "-f", str(freq), "-l", str(length_ms)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=0.6,
            )
        except (FileNotFoundError, OSError, subprocess.TimeoutExpired):
            print("\a", end="", flush=True)

    @classmethod
    def _speaker(cls, freq: int, length_ms: int) -> None:
        try:
            subprocess.run(
                ["timeout", f"{max(0.05, length_ms / 1000):.2f}",
                 "speaker-test", "-t", "sine", "-f", str(freq), "-l", "1"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=0.8,
            )
        except (FileNotFoundError, OSError, subprocess.TimeoutExpired):
            cls._beep(freq, length_ms)

    @classmethod
    def _sequence(cls, steps: list) -> None:
        for item in steps:
            if len(item) == 3:
                freq, length_ms, gap_ms = item
            else:
                freq, length_ms = item
                gap_ms = 18
            cls._speaker(freq, length_ms)
            if gap_ms > 0:
                time.sleep(gap_ms / 1000.0)

    @classmethod
    def _play_async(cls, fn) -> None:
        threading.Thread(target=fn, daemon=True).start()

    @classmethod
    def play(cls, kind: str, speed: str = "high", phase: str = "idle") -> None:
        with cls._lock:
            cd = cls._cooldowns.get(kind, 0.3)
            if cls._throttle(kind, cd):
                return

        fast = speed in FAST_SPEEDS

        if kind == "sonar" or kind == "scan_ping":
            def _scan_ping():
                if phase == "scanning":
                    # Classic submarine active ping + echo return
                    cls._sequence([
                        (95, 120, 80),
                        (140, 40, 30),
                        (210, 35, 25),
                        (320, 55, 180),
                        (180, 30, 20),
                        (120, 90, 0),
                    ])
                else:
                    # Passive hull sonar — low rumble + faint ping
                    cls._sequence([
                        (55, 90, 40),
                        (72, 60, 120),
                        (110, 35, 30),
                        (88, 110, 0),
                    ])
            cls._play_async(_scan_ping)

        elif kind == "contact":
            def _contact():
                cls._sequence([
                    (880, 18, 10),
                    (1320, 16, 8),
                    (1760, 22, 6),
                    (2200, 30, 0),
                ])
            cls._play_async(_contact)

        elif kind == "attack":
            def _attack():
                # Red alert klaxon + rapid fire-control pulses
                if fast:
                    cls._sequence([
                        (110, 140, 20),
                        (95, 140, 20),
                        (110, 140, 35),
                    ])
                    for _ in range(3):
                        cls._sequence([
                            (200, 35, 6),
                            (260, 35, 6),
                            (320, 45, 14),
                        ])
                else:
                    cls._sequence([
                        (85, 200, 30),
                        (70, 200, 30),
                        (85, 250, 50),
                        (120, 80, 20),
                        (160, 80, 20),
                        (200, 100, 0),
                    ])
            cls._play_async(_attack)

        elif kind == "lock":
            def _lock():
                cls._sequence([
                    (380, 30, 12),
                    (520, 30, 12),
                    (680, 35, 12),
                    (860, 40, 12),
                    (1040, 55, 0),
                ])
            cls._play_async(_lock)


def play_sound(kind: str, speed: str = "high", phase: str = "idle") -> None:
    SonarAudio.play(kind, speed, phase)


# ---------------------------------------------------------------------------
# Backend client
# ---------------------------------------------------------------------------
class Backend:
    def __init__(self, state_dir: str):
        self.state_dir = state_dir
        self.radar_dir = os.path.join(state_dir, "radar")
        self.cmd_queue_dir = os.path.join(state_dir, "cmd_queue")
        os.makedirs(self.cmd_queue_dir, exist_ok=True)
        self._lock = threading.Lock()
        self._seq = 0

    def send(self, cmd: str, timeout: float = 8.0, retries: int = 2) -> str:
        attempt = 0
        while attempt <= retries:
            res = self._send_once(cmd, timeout)
            if res != "TIMEOUT":
                return res
            attempt += 1
            time.sleep(0.3 * attempt)
        return "TIMEOUT"

    def _send_once(self, cmd: str, timeout: float) -> str:
        with self._lock:
            self._seq += 1
            req_id = f"{int(time.time() * 1000)}_{os.getpid()}_{self._seq}"
            cmd_path = os.path.join(self.cmd_queue_dir, f"{req_id}.cmd")
            result_path = os.path.join(self.cmd_queue_dir, f"{req_id}.result")
            legacy_result = os.path.join(self.state_dir, "result")

            try:
                os.remove(result_path)
            except FileNotFoundError:
                pass

            for attempt in range(3):
                try:
                    with open(cmd_path, "w", encoding="utf-8") as fh:
                        fh.write(cmd.strip() + "\n")
                    break
                except OSError as exc:
                    if attempt >= 2:
                        return f"DISK_ERROR: {exc}"
                    time.sleep(0.2)

            deadline = time.time() + timeout
            while time.time() < deadline:
                if os.path.exists(result_path):
                    try:
                        with open(result_path, encoding="utf-8") as fh:
                            return fh.read().strip()
                    except OSError:
                        pass
                time.sleep(0.05)
        return "TIMEOUT"

    def wait_for_phase(self, phases: tuple, timeout: float = 60.0, poll: float = 0.4) -> dict:
        deadline = time.time() + timeout
        last = {}
        while time.time() < deadline:
            last = self.read_status()
            if last.get("phase") in phases:
                return last
            time.sleep(poll)
        return last

    def read_status(self) -> dict:
        path = os.path.join(self.state_dir, "status.json")
        try:
            with open(path, encoding="utf-8") as fh:
                return json.load(fh)
        except (FileNotFoundError, json.JSONDecodeError):
            return {"phase": "idle", "message": "Connecting..."}

    def read_ifaces(self) -> list:
        path = os.path.join(self.state_dir, "ifaces.json")
        try:
            with open(path, encoding="utf-8") as fh:
                data = json.load(fh)
                return data.get("ifaces", [])
        except (FileNotFoundError, json.JSONDecodeError):
            return []

    def read_networks(self) -> list:
        path = os.path.join(self.state_dir, "networks.tsv")
        nets = []
        try:
            with open(path, encoding="utf-8") as fh:
                for line in fh:
                    parts = line.rstrip("\n").split("\t")
                    if len(parts) >= 6:
                        status = parts[7] if len(parts) >= 8 else "online"
                        nets.append(
                            {
                                "idx": int(parts[0]),
                                "bssid": parts[1],
                                "channel": parts[2],
                                "enc": parts[3],
                                "power": parts[4],
                                "essid": parts[5],
                                "packets": int(parts[6]) if len(parts) >= 7 and parts[6].isdigit() else 0,
                                "status": status,
                            }
                        )
        except FileNotFoundError:
            pass
        return nets

    def read_last_error(self) -> str:
        path = os.path.join(self.state_dir, "last_error")
        try:
            with open(path, encoding="utf-8") as fh:
                return fh.read().strip()
        except FileNotFoundError:
            return ""

    def read_tx_status(self) -> dict:
        path = os.path.join(self.state_dir, "tx_status.json")
        try:
            with open(path, encoding="utf-8") as fh:
                return json.load(fh)
        except (FileNotFoundError, json.JSONDecodeError):
            return {}

    def read_radar(self) -> dict:
        rd = self.radar_dir

        def rf(name, default=""):
            p = os.path.join(rd, name)
            try:
                with open(p, encoding="utf-8") as fh:
                    return fh.read().strip()
            except FileNotFoundError:
                return default

        def rn(name, default=0):
            raw = rf(name, str(default))
            try:
                return int(float(raw or default))
            except (ValueError, TypeError):
                return default

        contacts = []
        cp = os.path.join(rd, "contacts")
        try:
            with open(cp, encoding="utf-8") as fh:
                for line in fh:
                    parts = line.split()
                    if len(parts) >= 5:
                        contacts.append(
                            {
                                "r": int(parts[0]),
                                "a": int(parts[1]),
                                "label": parts[2],
                                "power": parts[3],
                                "target": int(parts[4]),
                            }
                        )
        except FileNotFoundError:
            pass

        return {
            "mode": rf("mode", "idle"),
            "remaining": rn("remaining", 0),
            "total": rn("total", 0),
            "status": rf("status", ""),
            "packet_phase": rn("packet_phase", 0),
            "target_essid": rf("target_essid", ""),
            "contacts": contacts,
        }


# ---------------------------------------------------------------------------
# Radar canvas
# ---------------------------------------------------------------------------
class RadarCanvas(tk.Canvas):
    def __init__(self, master, **kw):
        kw.setdefault("bg", BG_DEEP)
        kw.setdefault("highlightthickness", 1)
        kw.setdefault("highlightbackground", BORDER)
        super().__init__(master, **kw)
        self.sweep_angle = 0.0
        self.speed = "high"
        self._last_size = (0, 0)
        self._static_key = ""
        self.bind("<Configure>", self._on_resize, add="+")

    def set_speed(self, speed: str) -> None:
        self.speed = speed if speed in SPEED_PROFILES else "high"

    def _on_resize(self, _event=None) -> None:
        w = max(self.winfo_width(), 200)
        h = max(self.winfo_height(), 160)
        if (w, h) != self._last_size:
            self._last_size = (w, h)
            self._static_key = ""

    def _mode_theme(self, phase: str, mode: str, live: int) -> dict:
        if phase == "attacking" or mode == "attack":
            return {
                "sweep": RED_BRIGHT,
                "sweep_dim": RED_GLOW,
                "ring": "#5a2020",
                "ring_hi": "#7a3030",
                "blip": RED_BRIGHT,
                "blip_soft": "#cc4455",
                "center": ATTACK_ORANGE,
                "hud": RED_BRIGHT,
                "bg_ring": ATTACK_DEEP,
            }
        if phase == "scanning" or mode == "scan" or live:
            return {
                "sweep": SONAR_GREEN,
                "sweep_dim": SONAR_GLOW,
                "ring": PHOSPHOR,
                "ring_hi": FG_DIM,
                "blip": SCAN_CYAN,
                "blip_soft": FG_SOFT,
                "center": SONAR_GREEN,
                "hud": SCAN_CYAN,
                "bg_ring": "#0a1a12",
            }
        return {
            "sweep": FG_SOFT,
            "sweep_dim": FG_DIM,
            "ring": FG_DIM,
            "ring_hi": BORDER_HI,
            "blip": FG_SOFT,
            "blip_soft": FG_DIM,
            "center": FG_DIM,
            "hud": CYAN,
            "bg_ring": BORDER,
        }

    def _redraw_static(self, w: int, h: int, theme: dict) -> None:
        self.delete("static")
        cx, cy = w // 2, h // 2
        max_r = max(40, min(cx, cy) - 36)
        self.create_oval(
            cx - max_r - 10, cy - max_r - 10, cx + max_r + 10, cy + max_r + 10,
            outline=theme["bg_ring"], width=2, tags="static",
        )
        for ring in range(1, 5):
            r = max_r * ring / 4
            self.create_oval(
                cx - r, cy - r, cx + r, cy + r,
                outline=theme["ring"], width=1, tags="static",
            )
        for deg in range(0, 360, 45):
            a = math.radians(deg - 90)
            x1 = cx + (max_r - 6) * math.cos(a)
            y1 = cy + (max_r - 6) * math.sin(a)
            x2 = cx + max_r * math.cos(a)
            y2 = cy + max_r * math.sin(a)
            self.create_line(x1, y1, x2, y2, fill=theme["ring_hi"], width=1, tags="static")
        self.create_line(cx - max_r, cy, cx + max_r, cy, fill=theme["ring_hi"], width=1, tags="static")
        self.create_line(cx, cy - max_r, cx, cy + max_r, fill=theme["ring_hi"], width=1, tags="static")
        self.create_oval(cx - 6, cy - 6, cx + 6, cy + 6, outline=theme["center"], width=1, tags="static")

    def draw(self, radar: dict, status: dict) -> None:
        w = max(self.winfo_width(), 200)
        h = max(self.winfo_height(), 160)
        if (w, h) != self._last_size:
            self._last_size = (w, h)
            self._static_key = ""

        cx, cy = w // 2, h // 2
        max_r = max(40, min(cx, cy) - 36)
        mode = radar.get("mode", "idle")
        contacts = radar.get("contacts", [])
        target_essid = radar.get("target_essid", "")
        phase = status.get("phase", "idle")
        live = status.get("live_watch", 0)
        attack_speed = status.get("attack_speed", self.speed)
        theme = self._mode_theme(phase, mode, live)
        is_attack = phase == "attacking" or mode == "attack"
        is_scan = phase == "scanning" or mode == "scan" or (live and not is_attack)
        theme_key = f"{is_attack}:{is_scan}:{w}:{h}"

        if theme_key != self._static_key:
            self._static_key = theme_key
            self._redraw_static(w, h, theme)

        self.delete("dyn")

        if is_attack or is_scan:
            self.sweep_angle = (self.sweep_angle + 5) % 360.0
        else:
            self.sweep_angle = (self.sweep_angle + 1.5) % 360.0

        rad = math.radians(self.sweep_angle - 90)
        sx = cx + max_r * math.cos(rad)
        sy = cy + max_r * math.sin(rad)
        sweep_col = theme["sweep"] if (is_attack or is_scan) else theme["sweep_dim"]
        self.create_line(cx, cy, sx, sy, fill=sweep_col, width=2, tags="dyn")

        def pos(radius_idx, angle_deg):
            r = max_r * (radius_idx / 7.0)
            a = math.radians(angle_deg - 90)
            return cx + r * math.cos(a), cy + r * math.sin(a)

        target_xy = None
        font_sm = max(7, min(10, w // 80))
        for c in contacts:
            x, y = pos(c["r"], c["a"])
            if c.get("target"):
                target_xy = (x, y)
                self.create_oval(
                    x - 7, y - 7, x + 7, y + 7,
                    fill=RED_BRIGHT, outline=YELLOW, width=2, tags="dyn",
                )
                self.create_text(
                    x, y - 14, text=c["label"][:14],
                    fill=YELLOW, font=("DejaVu Sans Mono", font_sm, "bold"), tags="dyn",
                )
            else:
                col = theme["blip"] if is_scan else theme["blip_soft"]
                self.create_oval(x - 4, y - 4, x + 4, y + 4, fill=col, outline="", tags="dyn")

        if is_attack and target_xy:
            tx, ty = target_xy
            self.create_line(cx, cy, tx, ty, fill=YELLOW, width=1, dash=(4, 4), tags="dyn")

        msg = status.get("message", "")
        rem = status.get("scan_remaining", 0)
        total = status.get("scan_total", 0)
        cnt = status.get("contacts", len(contacts))
        net_cnt = status.get("net_count", cnt)
        font_md = max(8, min(11, w // 70))

        if is_scan and total:
            hud = f"SONAR {rem}/{total}s  ·  {cnt} contacts"
        elif is_attack:
            target = target_essid or status.get("attack_target", "")
            tx_ok = status.get("tx_ok", 1)
            hud = f"TARGET → {target}" if tx_ok else f"TX FAIL → {target}"
        elif live:
            hud = f"PASSIVE  ·  {net_cnt} network(s)"
        else:
            hud = msg or "STANDBY"

        mode_lbl = "STRIKE" if is_attack else ("SCAN" if is_scan else "IDLE")
        self.create_text(
            14, 16, anchor="nw", text=hud, fill=theme["hud"],
            font=("DejaVu Sans Mono", font_md, "bold"), tags="dyn",
        )
        self.create_text(
            w - 14, 16, anchor="ne", text=f"● {mode_lbl}",
            fill=theme["hud"], font=("DejaVu Sans Mono", font_sm, "bold"), tags="dyn",
        )
        self.create_text(
            14, h - 14, anchor="sw",
            text=f"BRG {int(self.sweep_angle):03d}°  ·  {attack_speed.upper()}",
            fill=FG_DIM, font=("DejaVu Sans Mono", font_sm), tags="dyn",
        )


# ---------------------------------------------------------------------------
# Serialized command worker (prevents concurrent backend timeouts)
# ---------------------------------------------------------------------------
class CommandWorker:
    def __init__(self, backend: Backend):
        self.backend = backend
        self._queue: queue.Queue = queue.Queue()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def submit(self, fn) -> None:
        self._queue.put(fn)

    def _run(self) -> None:
        while True:
            fn = self._queue.get()
            try:
                fn()
            except Exception as exc:
                print(f"Command worker error: {exc}", file=sys.stderr)
            finally:
                self._queue.task_done()


# ---------------------------------------------------------------------------
# Main dashboard
# ---------------------------------------------------------------------------
class WifiDashboard(tk.Tk):
    def __init__(self, state_dir: str, daemon_pid: str):
        super().__init__()
        self.backend = Backend(state_dir)
        self.cmd_worker = CommandWorker(self.backend)
        self.daemon_pid = int(daemon_pid)
        self.state_dir = state_dir
        self.agreed = tk.BooleanVar(value=False)
        self.scan_var = tk.StringVar(value="30")
        self.speed_var = tk.StringVar(value="high")
        self.packets_var = tk.StringVar(value="0")
        self.sensitivity_var = tk.StringVar(value="high")
        self.shift_dwell_var = tk.StringVar(value="5")
        self.shift_packets_var = tk.StringVar(value="0")
        self.iface_var = tk.StringVar()
        self._running = True
        self.selected_indices: set[int] = set()
        self._nets_cache = ()
        self._last_phase = "idle"
        self._speed_sent = "high"
        self._last_tx_ok = None
        self._last_tx_msg = ""
        self._cmd_busy = False
        self._cmd_busy_since = 0.0
        self._speed_pending = False
        self._monitor_waiting = False
        self._monitor_deadline = 0.0
        self._net_rev = 0
        self._known_bssids: set[str] = set()
        self._prev_bssids: set[str] = set()
        self._bssid_names: dict[str, str] = {}
        self._last_net_rev = -1
        self._sensitivity_sent = "high"
        self._shift_dwell_sent = ""
        self._shift_packets_sent = "0"
        self._status_cache: dict = {}
        self._last_tree_refresh = 0.0
        self._tree_row_cache: dict = {}

        self.title("WiFi Tactical Sonar")
        self.configure(bg=BG)
        self.geometry("1280x800")
        self.minsize(900, 580)
        self.grid_rowconfigure(1, weight=1)
        self.grid_columnconfigure(0, weight=1)

        self._build_ui()
        self.after(500, self._startup_check)
        self.after(800, self._load_ifaces)
        self._poll()
        self._animate_radar()

        self.protocol("WM_DELETE_WINDOW", self._on_close)
        signal.signal(signal.SIGINT, self._sigint_handler)

    def _sigint_handler(self, _signum=None, _frame=None) -> None:
        self.after(0, self._force_close)

    def _build_ui(self) -> None:
        style = ttk.Style(self)
        style.theme_use("clam")
        style.configure("TFrame", background=BG)
        style.configure("TLabel", background=BG, foreground=FG, font=("DejaVu Sans Mono", 10))
        style.configure("TButton", font=("DejaVu Sans Mono", 10, "bold"), padding=6)
        style.configure("Treeview", background=PANEL_HI, foreground=FG_SOFT, fieldbackground=PANEL_HI,
                        font=("DejaVu Sans Mono", 9), rowheight=26, borderwidth=0)
        style.configure("Treeview.Heading", background=PANEL, foreground=CYAN,
                        font=("DejaVu Sans Mono", 9, "bold"), relief="flat")
        style.map("Treeview",
                  background=[("selected", "#1a3a2a")],
                  foreground=[("selected", FG)])

        top = tk.Frame(self, bg=PANEL, highlightthickness=1, highlightbackground=BORDER)
        top.grid(row=0, column=0, sticky="ew", padx=12, pady=(10, 6))

        tk.Label(top, text="WiFi Sonar", bg=PANEL, fg=FG,
                 font=("DejaVu Sans Mono", 14, "bold")).pack(side=tk.LEFT, padx=12, pady=8)
        tk.Label(top, text="Educational use only", bg=PANEL, fg=FG_DIM,
                 font=("DejaVu Sans Mono", 8)).pack(side=tk.LEFT, padx=(0, 12))

        self.live_lbl = tk.Label(top, text="", bg=PANEL, fg=FG_DIM,
                                 font=("DejaVu Sans Mono", 9, "bold"))
        self.live_lbl.pack(side=tk.RIGHT, padx=(0, 8), pady=8)

        self.status_lbl = tk.Label(top, text="idle", bg=PANEL, fg=CYAN,
                                   font=("DejaVu Sans Mono", 9))
        self.status_lbl.pack(side=tk.RIGHT, padx=12, pady=8)

        top.grid(row=0, column=0, sticky="ew", padx=12, pady=(10, 6))
        self.grid_rowconfigure(1, weight=1)
        self.grid_columnconfigure(0, weight=1)

        body = tk.Frame(self, bg=BG)
        body.grid(row=1, column=0, sticky="nsew", padx=8, pady=(0, 8))
        body.grid_rowconfigure(0, weight=1)
        body.grid_columnconfigure(0, weight=1)

        self._h_paned = tk.PanedWindow(
            body, orient=tk.HORIZONTAL, bg=BORDER, sashwidth=5,
            sashrelief=tk.RAISED, opaqueresize=True,
        )
        self._h_paned.grid(row=0, column=0, sticky="nsew")

        left_shell = tk.Frame(self._h_paned, bg=PANEL, width=280)
        left_canvas = tk.Canvas(left_shell, bg=PANEL, highlightthickness=0, width=268)
        left_scroll = ttk.Scrollbar(left_shell, orient=tk.VERTICAL, command=left_canvas.yview)
        left = tk.Frame(left_canvas, bg=PANEL)
        left_win = left_canvas.create_window((0, 0), window=left, anchor="nw")

        def _left_configure(_event=None):
            left_canvas.configure(scrollregion=left_canvas.bbox("all"))
            cw = max(240, left_canvas.winfo_width())
            left_canvas.itemconfig(left_win, width=cw)

        left.bind("<Configure>", _left_configure)
        left_canvas.configure(yscrollcommand=left_scroll.set)
        left_canvas.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        left_scroll.pack(side=tk.RIGHT, fill=tk.Y)

        def _left_wheel(event):
            left_canvas.yview_scroll(int(-1 * (event.delta / 120)), "units")

        left_canvas.bind("<Enter>", lambda _e: left_canvas.bind_all("<MouseWheel>", _left_wheel))
        left_canvas.bind("<Leave>", lambda _e: left_canvas.unbind_all("<MouseWheel>"))

        self._vr_paned = tk.PanedWindow(
            self._h_paned, orient=tk.HORIZONTAL, bg=BORDER, sashwidth=5,
            sashrelief=tk.RAISED, opaqueresize=True,
        )
        self._h_paned.add(left_shell, minsize=230, width=290)
        self._h_paned.add(self._vr_paned, minsize=500)

        tk.Label(left, text="CONTROLS", bg=PANEL, fg=CYAN, font=("DejaVu Sans Mono", 11, "bold")).pack(
            anchor="w", padx=12, pady=(12, 6))

        tk.Label(left, text="Wireless Adapter", bg=PANEL, fg=FG_DIM, font=("Consolas", 9)).pack(
            anchor="w", padx=10)
        self.iface_combo = ttk.Combobox(left, textvariable=self.iface_var, state="readonly", width=32)
        self.iface_combo.pack(padx=10, pady=4, fill=tk.X)

        tk.Button(left, text="⟳ Refresh Adapters", bg=BORDER, fg=FG, relief=tk.FLAT,
                  command=self._load_ifaces).pack(padx=10, pady=4, fill=tk.X)

        tk.Button(left, text="▶ Enable Monitor Mode", bg="#1a4a1a", fg=FG, relief=tk.FLAT,
                  command=self._enable_monitor).pack(padx=10, pady=4, fill=tk.X)

        tk.Label(left, text="Scan Duration (seconds)", bg=PANEL, fg=FG_DIM,
                 font=("Consolas", 9)).pack(anchor="w", padx=10, pady=(12, 0))
        tk.Entry(left, textvariable=self.scan_var, bg="#0a1a0a", fg=FG,
                 insertbackground=FG, relief=tk.FLAT, font=("Consolas", 11)).pack(
            padx=10, pady=4, fill=tk.X)

        btn_row = tk.Frame(left, bg=PANEL)
        btn_row.pack(padx=10, pady=4, fill=tk.X)
        tk.Button(btn_row, text="◎ START SCAN", bg="#0a5a0a", fg=FG, relief=tk.FLAT,
                  command=self._start_scan).pack(side=tk.LEFT, expand=True, fill=tk.X, padx=(0, 4))
        tk.Button(btn_row, text="■ STOP", bg="#5a1a1a", fg=RED_BRIGHT, relief=tk.FLAT,
                  command=self._stop_scan).pack(side=tk.LEFT, expand=True, fill=tk.X)

        tk.Label(left, text="Signal Sensitivity", bg=PANEL, fg=CYAN, font=("DejaVu Sans Mono", 11, "bold")).pack(
            anchor="w", padx=12, pady=(12, 2))
        tk.Label(left, text="HIGH/MAX = weak distant APs  ·  scans all bands",
                 bg=PANEL, fg=FG_DIM, font=("DejaVu Sans Mono", 7)).pack(anchor="w", padx=12)
        sens_row = tk.Frame(left, bg=PANEL)
        sens_row.pack(padx=10, pady=4, fill=tk.X)
        self.sensitivity_combo = ttk.Combobox(
            sens_row, textvariable=self.sensitivity_var, state="readonly", width=14,
            values=("normal", "high", "max"),
        )
        self.sensitivity_combo.pack(side=tk.LEFT, fill=tk.X, expand=True)
        self.sensitivity_combo.current(1)
        self.sensitivity_combo.bind("<<ComboboxSelected>>", self._on_sensitivity_change)

        tk.Label(left, text="Attack Speed", bg=PANEL, fg=CYAN, font=("Consolas", 11, "bold")).pack(
            anchor="w", padx=10, pady=(14, 2))
        tk.Label(left, text="LOW = slow | TURBO = 1.5s | ULTRA = 1s | HYPER = 0.5s | EXTREME = 0.1s",
                 bg=PANEL, fg=FG_DIM, font=("Consolas", 7)).pack(anchor="w", padx=10)

        tk.Label(left, text="Packets per Network", bg=PANEL, fg=CYAN, font=("Consolas", 11, "bold")).pack(
            anchor="w", padx=10, pady=(10, 2))
        tk.Label(left, text="0 = unlimited continuous | e.g. 500 = 500 deauth pkts",
                 bg=PANEL, fg=FG_DIM, font=("Consolas", 7)).pack(anchor="w", padx=10)

        pkt_row = tk.Frame(left, bg=PANEL)
        pkt_row.pack(padx=10, pady=4, fill=tk.X)
        tk.Entry(pkt_row, textvariable=self.packets_var, bg="#0a1a0a", fg=FG,
                 insertbackground=FG, relief=tk.FLAT, font=("Consolas", 11), width=10).pack(
            side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 4))
        tk.Button(pkt_row, text="Apply to Selected", bg="#1a3a1a", fg=FG, relief=tk.FLAT,
                  command=self._apply_packets).pack(side=tk.LEFT, fill=tk.X, expand=True)

        speed_row = tk.Frame(left, bg=PANEL)
        speed_row.pack(padx=10, pady=4, fill=tk.X)
        self.speed_combo = ttk.Combobox(
            speed_row, textvariable=self.speed_var, state="readonly", width=14,
            values=("low", "medium", "high", "turbo", "ultra", "hyper", "extreme"),
        )
        self.speed_combo.pack(side=tk.LEFT, fill=tk.X, expand=True)
        self.speed_combo.current(2)
        self.speed_combo.bind("<<ComboboxSelected>>", self._on_speed_change)

        tk.Label(left, text="Attack ALL — shift time (sec)", bg=PANEL, fg=CYAN,
                 font=("DejaVu Sans Mono", 11, "bold")).pack(anchor="w", padx=12, pady=(10, 2))
        tk.Label(left, text="Time on each network before switching to the next",
                 bg=PANEL, fg=FG_DIM, font=("DejaVu Sans Mono", 7)).pack(anchor="w", padx=12)
        shift_row = tk.Frame(left, bg=PANEL)
        shift_row.pack(padx=10, pady=4, fill=tk.X)
        tk.Entry(shift_row, textvariable=self.shift_dwell_var, bg="#0a1a0a", fg=FG,
                 insertbackground=FG, relief=tk.FLAT, font=("DejaVu Sans Mono", 11)).pack(
            side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 4))
        tk.Button(shift_row, text="Apply", bg="#1a3a1a", fg=FG, relief=tk.FLAT,
                  command=self._apply_shift_dwell).pack(side=tk.LEFT, fill=tk.X)

        tk.Label(left, text="Attack ALL — packets before shift", bg=PANEL, fg=CYAN,
                 font=("DejaVu Sans Mono", 11, "bold")).pack(anchor="w", padx=12, pady=(8, 2))
        tk.Label(left, text="Exact pkts per network, then auto-switch  ·  0 = use time rule",
                 bg=PANEL, fg=FG_DIM, font=("DejaVu Sans Mono", 7)).pack(anchor="w", padx=12)
        pkt_preset_row = tk.Frame(left, bg=PANEL)
        pkt_preset_row.pack(padx=10, pady=(4, 2), fill=tk.X)
        for label, val in (("20", 20), ("100", 100), ("500", 500)):
            tk.Button(
                pkt_preset_row, text=label, bg=BORDER, fg=FG, relief=tk.FLAT,
                command=lambda v=val: self._pick_shift_packets_preset(v),
            ).pack(side=tk.LEFT, expand=True, fill=tk.X, padx=(0, 3))
        tk.Button(
            pkt_preset_row, text="Custom", bg="#1a2a3a", fg=CYAN, relief=tk.FLAT,
            command=self._focus_shift_packets_custom,
        ).pack(side=tk.LEFT, expand=True, fill=tk.X)
        pkt_shift_row = tk.Frame(left, bg=PANEL)
        pkt_shift_row.pack(padx=10, pady=4, fill=tk.X)
        self._shift_pkt_entry = tk.Entry(
            pkt_shift_row, textvariable=self.shift_packets_var, bg="#0a1a0a", fg=FG,
            insertbackground=FG, relief=tk.FLAT, font=("DejaVu Sans Mono", 11),
        )
        self._shift_pkt_entry.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 4))
        tk.Button(pkt_shift_row, text="Apply", bg="#1a3a1a", fg=FG, relief=tk.FLAT,
                  command=self._apply_shift_packets).pack(side=tk.LEFT, fill=tk.X)

        tk.Label(left, text="Attack Targets", bg=PANEL, fg=CYAN, font=("Consolas", 11, "bold")).pack(
            anchor="w", padx=10, pady=(12, 4))

        tk.Button(left, text="⚡ Attack Selected", bg="#5a2a0a", fg=YELLOW, relief=tk.FLAT,
                  command=self._attack_selected).pack(padx=10, pady=3, fill=tk.X)
        tk.Button(left, text="⚡ Attack ALL (loop)", bg="#5a0a0a", fg=RED_BRIGHT, relief=tk.FLAT,
                  command=self._attack_all).pack(padx=10, pady=3, fill=tk.X)
        tk.Button(left, text="■ STOP ATTACK", bg="#3a1a1a", fg=RED, relief=tk.FLAT,
                  command=self._stop_attack).pack(padx=10, pady=3, fill=tk.X)

        tk.Label(left, text="", bg=PANEL).pack(expand=True)

        disc = tk.Frame(left, bg=PANEL)
        disc.pack(fill=tk.X, padx=10, pady=8)
        tk.Checkbutton(
            disc, text="I agree — educational/legal use only",
            variable=self.agreed, bg=PANEL, fg=FG_DIM, selectcolor=PANEL,
            activebackground=PANEL, activeforeground=FG, font=("Consolas", 8),
        ).pack(anchor="w")

        tk.Button(left, text="↩ Restore & Exit", bg=BORDER, fg=FG_DIM, relief=tk.FLAT,
                  command=self._on_close).pack(padx=10, pady=(4, 10), fill=tk.X)

        center = tk.Frame(self._vr_paned, bg=BG)
        right = tk.Frame(self._vr_paned, bg=PANEL)
        self._vr_paned.add(center, minsize=300)
        self._vr_paned.add(right, minsize=240, width=340)

        center.grid_rowconfigure(1, weight=1)
        center.grid_columnconfigure(0, weight=1)

        hdr = tk.Frame(center, bg=BG)
        hdr.grid(row=0, column=0, sticky="ew", padx=4, pady=(0, 4))
        tk.Label(hdr, text="Tactical Radar", bg=BG, fg=FG_SOFT,
                 font=("DejaVu Sans Mono", 11, "bold")).pack(side=tk.LEFT)
        tk.Label(hdr, text="Scan = green sonar  ·  Attack = red weapons track",
                 bg=BG, fg=FG_DIM, font=("DejaVu Sans Mono", 8)).pack(side=tk.LEFT, padx=10)

        self.radar = RadarCanvas(center)
        self.radar.grid(row=1, column=0, sticky="nsew", padx=4, pady=4)

        right.grid_rowconfigure(4, weight=2)
        right.grid_rowconfigure(6, weight=1)
        right.grid_columnconfigure(0, weight=1)

        tk.Label(right, text="NETWORKS", bg=PANEL, fg=CYAN,
                 font=("DejaVu Sans Mono", 11, "bold")).grid(row=0, column=0, sticky="w", padx=12, pady=(12, 2))

        tk.Label(right, text="● online (live)   networks appear & vanish in real time during scan",
                 bg=PANEL, fg=FG_DIM, font=("DejaVu Sans Mono", 7)).grid(row=1, column=0, sticky="w", padx=12)

        self.selected_lbl = tk.Label(
            right, text="Selected: (none)", bg=PANEL, fg=YELLOW,
            font=("Consolas", 9), anchor="w", wraplength=340, justify=tk.LEFT,
        )
        self.selected_lbl.grid(row=2, column=0, sticky="ew", padx=10, pady=(0, 4))

        sel_btns = tk.Frame(right, bg=PANEL)
        sel_btns.grid(row=3, column=0, sticky="ew", padx=10, pady=(0, 4))
        tk.Button(sel_btns, text="Select All", bg=BORDER, fg=FG, relief=tk.FLAT,
                  command=self._select_all).pack(side=tk.LEFT, expand=True, fill=tk.X, padx=(0, 3))
        tk.Button(sel_btns, text="Clear", bg=BORDER, fg=FG_DIM, relief=tk.FLAT,
                  command=self._clear_selection).pack(side=tk.LEFT, expand=True, fill=tk.X)

        tree_frame = tk.Frame(right, bg=PANEL)
        tree_frame.grid(row=4, column=0, sticky="nsew", padx=10, pady=(0, 4))

        cols = ("idx", "st", "essid", "ch", "pwr", "pkts", "bssid")
        self.tree = ttk.Treeview(
            tree_frame, columns=cols, show="headings", height=8, selectmode="extended",
        )
        self._tree_cols = (
            ("idx", "#", 26, False), ("st", "●", 28, False), ("essid", "ESSID", 90, True),
            ("ch", "CH", 32, False), ("pwr", "dBm", 38, False), ("pkts", "Pkts", 42, False),
            ("bssid", "BSSID", 100, True),
        )
        for c, t, w, stretch in self._tree_cols:
            self.tree.heading(c, text=t)
            self.tree.column(c, width=w, minwidth=24, stretch=stretch,
                             anchor="center" if c not in ("essid", "bssid") else "w")

        self.tree.tag_configure("online", foreground=FG_SOFT)
        self.tree.tag_configure("offline", foreground=OFFLINE)
        self.tree.tag_configure("new", foreground=NEW_NET)

        tree_scroll = ttk.Scrollbar(tree_frame, orient=tk.VERTICAL, command=self.tree.yview)
        self.tree.configure(yscrollcommand=tree_scroll.set)
        self.tree.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        tree_scroll.pack(side=tk.RIGHT, fill=tk.Y)

        self.tree.bind("<<TreeviewSelect>>", self._on_select)
        self.tree.bind("<Double-1>", self._on_double_click)

        tk.Label(right, text="LOG", bg=PANEL, fg=CYAN, font=("Consolas", 11, "bold")).grid(
            row=5, column=0, sticky="w", padx=10, pady=(8, 4))
        self.log = tk.Text(right, height=8, bg=BG_DEEP, fg=FG_DIM, relief=tk.FLAT,
                           font=("DejaVu Sans Mono", 8), wrap=tk.WORD,
                           insertbackground=FG, selectbackground="#1a3a2a")
        self.log.grid(row=6, column=0, sticky="nsew", padx=10, pady=(0, 10))
        self.log.configure(state=tk.DISABLED)

        right.bind("<Configure>", self._on_right_resize)

    def _on_right_resize(self, event=None) -> None:
        try:
            w = max(260, event.width if event else self.tree.winfo_width())
        except tk.TclError:
            return
        self.selected_lbl.configure(wraplength=max(180, w - 24))
        essid_w = max(60, int(w * 0.28))
        bssid_w = max(80, int(w * 0.32))
        self.tree.column("essid", width=essid_w)
        self.tree.column("bssid", width=bssid_w)

    def _log(self, msg: str) -> None:
        self.log.configure(state=tk.NORMAL)
        self.log.insert(tk.END, f"[{time.strftime('%H:%M:%S')}] {msg}\n")
        self.log.see(tk.END)
        self.log.configure(state=tk.DISABLED)

    def _startup_check(self) -> None:
        ping = self.backend.send("PING", timeout=5)
        if ping != "OK":
            self._log(f"Backend check: {ping} (daemon PID {self.daemon_pid})")
        else:
            self._log("Backend connected.")
        self.cmd_worker.submit(self._sync_settings_to_backend)

    def _sync_settings_to_backend(self) -> None:
        sens = self.sensitivity_var.get().strip().lower()
        if sens in ("normal", "high", "max"):
            res = self.backend.send(f"SET_SENSITIVITY {sens}", timeout=10)
            self._sensitivity_sent = sens
            self.after(0, lambda: self._log(f"Sensitivity: {sens.upper()} ({res})"))
        self._apply_shift_dwell(send_only=True)
        self._apply_shift_packets(send_only=True)

    def _on_sensitivity_change(self, _event=None) -> None:
        sens = self.sensitivity_var.get().strip().lower()
        if sens not in ("normal", "high", "max") or sens == self._sensitivity_sent:
            return

        def work():
            res = self.backend.send(f"SET_SENSITIVITY {sens}", timeout=12)
            if res == "OK":
                self._sensitivity_sent = sens
            self.after(0, lambda: self._log(f"Sensitivity -> {sens.upper()} ({res})"))

        self.cmd_worker.submit(work)

    def _apply_shift_dwell(self, send_only: bool = False) -> None:
        try:
            sec = float(self.shift_dwell_var.get().strip())
            if sec < 0.1 or sec > 120:
                raise ValueError
        except ValueError:
            if not send_only:
                messagebox.showerror("Error", "Shift time must be 0.1 to 120 seconds.")
            return

        val = f"{sec:g}"

        def work():
            res = self.backend.send(f"SET_SHIFT_DWELL {val}", timeout=12)
            if res == "OK":
                self._shift_dwell_sent = val
            self.after(0, lambda: self._log(f"Attack ALL shift: {val}s per network ({res})"))

        self.cmd_worker.submit(work)

    def _pick_shift_packets_preset(self, pkts: int) -> None:
        self.shift_packets_var.set(str(pkts))
        self._apply_shift_packets()
        self._log(f"Packet rule: send exactly {pkts} per network, then next")

    def _focus_shift_packets_custom(self) -> None:
        self._shift_pkt_entry.focus_set()
        self._shift_pkt_entry.icursor(tk.END)
        self._shift_pkt_entry.selection_range(0, tk.END)

    def _apply_shift_packets(self, send_only: bool = False) -> None:
        try:
            pkts = int(self.shift_packets_var.get().strip())
            if pkts < 0 or pkts > 1000000:
                raise ValueError
        except ValueError:
            if not send_only:
                messagebox.showerror("Error", "Packet count must be 0 to 1,000,000 (0 = use time rule).")
            return

        def work():
            res = self.backend.send(f"SET_SHIFT_PACKETS {pkts}", timeout=12)
            if res == "OK":
                self._shift_packets_sent = str(pkts)
            msg = f"Attack ALL packet rule: {pkts} pkts per network then shift ({res})" if pkts > 0 else \
                f"Attack ALL packet rule off — time shift ({res})"
            self.after(0, lambda: self._log(msg))

        self.cmd_worker.submit(work)

    def _ensure_shift_packets_synced(self) -> None:
        try:
            pkts = int(self.shift_packets_var.get().strip())
            if pkts < 0:
                return
            val = str(pkts)
            if val != self._shift_packets_sent:
                self.backend.send(f"SET_SHIFT_PACKETS {pkts}", timeout=5)
                self._shift_packets_sent = val
        except ValueError:
            pass

    def _ensure_shift_dwell_synced(self) -> None:
        try:
            sec = float(self.shift_dwell_var.get().strip())
            if sec < 0.1:
                return
            val = f"{sec:g}"
            if val != self._shift_dwell_sent:
                self.backend.send(f"SET_SHIFT_DWELL {val}", timeout=5)
                self._shift_dwell_sent = val
        except ValueError:
            pass

    def _clear_busy_if_stale(self, max_sec: float = 90.0) -> None:
        if self._cmd_busy and (time.time() - self._cmd_busy_since) > max_sec:
            self._cmd_busy = False
            self._log("Operation timeout — ready for new commands.")

    def _run_cmd(self, fn, *, block: bool = True) -> bool:
        self._clear_busy_if_stale()
        if block and self._cmd_busy:
            self._log("Busy — please wait for current operation to finish.")
            return False
        if block:
            self._cmd_busy = True
            self._cmd_busy_since = time.time()

        def wrapped():
            try:
                fn()
            finally:
                if block and not self._monitor_waiting:
                    self.after(0, lambda: setattr(self, "_cmd_busy", False))

        self.cmd_worker.submit(wrapped)
        return True

    def _load_ifaces(self) -> None:
        cached = self.backend.read_ifaces()
        if cached:
            labels = [f"{i['iface']}  {i['label']}" for i in cached]
            self._set_ifaces(labels, cached, "cached")

        def work():
            res = self.backend.send("LIST_IFACES", timeout=15)
            ifaces = self.backend.read_ifaces()
            labels = [f"{i['iface']}  {i['label']}" for i in ifaces]
            self.after(0, lambda: self._set_ifaces(labels, ifaces, res))

        self.cmd_worker.submit(work)

    def _set_ifaces(self, labels, ifaces, res) -> None:
        self.iface_combo["values"] = labels
        if labels:
            self.iface_combo.current(0)
        self._log(f"Adapters found: {len(ifaces)} ({res})")

    def _selected_iface(self) -> str:
        val = self.iface_var.get()
        return val.split()[0] if val else ""

    def _check_agreement(self) -> bool:
        if not self.agreed.get():
            messagebox.showwarning(
                "Disclaimer",
                "You must agree to educational/legal use only before attacking.",
            )
            return False
        return True

    def _on_speed_change(self, _event=None) -> None:
        speed = self.speed_var.get().strip().lower()
        if speed not in SPEED_PROFILES:
            return
        self.radar.set_speed(speed)
        if speed == self._speed_sent or self._speed_pending:
            return
        self._speed_pending = True

        def work():
            res = self.backend.send(f"SET_SPEED {speed}", timeout=12)
            if res == "OK":
                self._speed_sent = speed
            self._speed_pending = False
            self.after(0, lambda: self._log(f"Attack speed -> {speed.upper()} ({res})"))

        self.cmd_worker.submit(work)

    def _enable_monitor(self) -> None:
        iface = self._selected_iface()
        if not iface:
            messagebox.showerror("Error", "Select an adapter first.")
            return
        if self._monitor_waiting:
            self._log("Monitor enable already in progress...")
            return

        def work():
            self.after(0, lambda: self._log(f"Enabling monitor mode on {iface}..."))
            res = self.backend.send(f"ENABLE_MONITOR {iface}", timeout=15)
            if res in ("OK", "BUSY"):
                self._monitor_waiting = True
                self._monitor_deadline = time.time() + 90
                self.after(0, lambda: self._log("Monitor job started — waiting for confirmation..."))
            elif res == "TIMEOUT":
                self.after(0, lambda: self._log("Monitor: TIMEOUT — check daemon.log"))
            else:
                st = self.backend.read_status()
                self.after(0, lambda: self._log(f"Monitor: {res} — {st.get('message', '')}"))

        self._run_cmd(work, block=False)

    def _start_scan(self) -> None:
        try:
            dur = int(self.scan_var.get())
            if dur < 15:
                raise ValueError
        except ValueError:
            messagebox.showerror("Error", "Scan duration must be at least 15 seconds.")
            return

        st = self.backend.read_status()
        if self._monitor_waiting or st.get("phase") == "busy":
            messagebox.showwarning("Wait", "Monitor mode is still enabling. Please wait.")
            return
        if not st.get("mon_iface"):
            mon_path = os.path.join(self.backend.state_dir, "mon_iface")
            try:
                with open(mon_path, encoding="utf-8") as fh:
                    if not fh.read().strip():
                        messagebox.showerror("Error", "Enable monitor mode first.")
                        return
            except FileNotFoundError:
                messagebox.showerror("Error", "Enable monitor mode first.")
                return

        def work():
            self.after(0, lambda: self._log(f"Starting sonar scan ({dur}s)..."))
            res = self.backend.send(f"SCAN_START {dur}", timeout=20)
            st = self.backend.read_status()
            msg = st.get("message", "")
            if res == "ERROR":
                self.after(0, lambda: self._log(f"Scan failed: {msg}"))
            else:
                self.after(0, lambda: self._log(f"Scan started: {res} — {msg}"))

        self._run_cmd(work)

    def _stop_scan(self) -> None:
        def work():
            res = self.backend.send("SCAN_STOP", timeout=20)
            self.after(0, lambda: self._log(f"Scan stopped: {res}"))

        self._run_cmd(work)

    def _refresh_networks(self, force: bool = False) -> None:
        nets = self.backend.read_networks()
        st = self.backend.read_status()
        net_rev = st.get("net_rev", 0)
        cache_key = (
            net_rev,
            tuple(
                (n["idx"], n["bssid"], n.get("status"), n.get("power"), n.get("packets", 0))
                for n in nets
            ),
        )
        if not force and cache_key == self._nets_cache:
            return
        self._last_net_rev = net_rev
        self._nets_cache = cache_key
        self._last_tree_refresh = time.time()

        current_bssids = {n["bssid"] for n in nets}
        if self._known_bssids:
            for bssid in self._known_bssids - current_bssids:
                name = self._bssid_names.get(bssid, bssid)
                self._log(f"Removed (offline): {name}")
        for n in nets:
            if n["bssid"] not in self._known_bssids:
                self._log(f"Detected: {n['essid']} ch{n['channel']}")
            self._bssid_names[n["bssid"]] = n["essid"]
        self._known_bssids = current_bssids

        keep = {str(i) for i in self.selected_indices}
        existing = set(self.tree.get_children())
        new_ids = set()

        for n in nets:
            iid = str(n["idx"])
            new_ids.add(iid)
            st_icon = "●" if n.get("status", "online") == "online" else "○"
            tag = n.get("status", "online")
            try:
                pwr = int(n.get("power", -75))
            except (ValueError, TypeError):
                pwr = -90
            if pwr <= -88 and tag == "online":
                tag = "new"
            elif n["bssid"] not in getattr(self, "_prev_bssids", set()) and tag == "online":
                tag = "new"
            values = (
                n["idx"], st_icon, n["essid"], n["channel"], n["power"],
                n.get("packets", 0), n["bssid"],
            )
            row_key = (values, tag)
            if iid in existing:
                if self._tree_row_cache.get(iid) != row_key:
                    self.tree.item(iid, values=values, tags=(tag,))
                    self._tree_row_cache[iid] = row_key
            else:
                self.tree.insert("", tk.END, iid=iid, values=values, tags=(tag,))
                self._tree_row_cache[iid] = row_key

        for iid in existing - new_ids:
            self.tree.delete(iid)
            self._tree_row_cache.pop(iid, None)

        self._prev_bssids = current_bssids

        valid = [iid for iid in keep if self.tree.exists(iid)]
        if valid:
            self.tree.selection_set(valid)
            self.tree.focus(valid[0])
            self.tree.see(valid[0])
        elif keep:
            self.selected_indices.clear()
        self._update_selection_label()

    def _update_selection_label(self) -> None:
        sel = self.tree.selection()
        self.selected_indices = set()
        names = []
        for iid in sel:
            if not self.tree.exists(iid):
                continue
            self.selected_indices.add(int(iid))
            vals = self.tree.item(iid, "values")
            if vals:
                names.append(f"#{iid} {vals[2]}")
        if not names:
            self.selected_lbl.configure(text="Selected: (none)", fg=FG_DIM)
        elif len(names) == 1:
            self.selected_lbl.configure(text=f"Selected: {names[0]}", fg=YELLOW)
        else:
            preview = ", ".join(names[:3])
            extra = f" +{len(names) - 3} more" if len(names) > 3 else ""
            self.selected_lbl.configure(
                text=f"Selected ({len(names)}): {preview}{extra}", fg=YELLOW,
            )

    def _apply_packets(self) -> None:
        try:
            pkt_count = int(self.packets_var.get().strip())
            if pkt_count < 0:
                raise ValueError
        except ValueError:
            messagebox.showerror("Error", "Packet count must be 0 or higher (0 = unlimited).")
            return

        self._on_select()
        if not self.selected_indices:
            messagebox.showerror("Error", "Select one or more networks first.")
            return

        pairs = " ".join(f"{i}={pkt_count}" for i in sorted(self.selected_indices))

        def work():
            res = self.backend.send(f"SET_NETWORK_PACKETS {pairs}", timeout=15)
            self.after(0, lambda: (
                self._log(f"Packets set to {pkt_count} for {len(self.selected_indices)} network(s): {res}"),
                self._refresh_networks(force=True),
            ))

        self._run_cmd(work)

    def _update_tx_feedback(self, st: dict) -> None:
        phase = st.get("phase", "idle")
        if phase != "attacking":
            self._last_tx_ok = None
            return

        tx_ok = st.get("tx_ok", 1)
        tx_msg = st.get("tx_message", st.get("message", ""))
        if tx_ok != self._last_tx_ok or tx_msg != self._last_tx_msg:
            self._last_tx_ok = tx_ok
            self._last_tx_msg = tx_msg
            if tx_ok:
                self._log(f"TX OK: {tx_msg or st.get('message', '')}")
            else:
                self._log(f"TX FAIL: {tx_msg or 'Packets NOT connecting to network!'}")

        tx = self.backend.read_tx_status()
        target_idx = str(tx.get("target_idx", ""))
        if target_idx and self.tree.exists(target_idx):
            vals = list(self.tree.item(target_idx, "values"))
            if len(vals) >= 6:
                sent = tx.get("packets_sent", 0)
                target = tx.get("packets_target", 0)
                if target > 0:
                    vals[5] = f"{sent}/{target}"
                elif tx.get("tx_ok"):
                    vals[5] = f"{sent} TX"
                else:
                    vals[5] = "FAIL"
                self.tree.item(target_idx, values=vals)

    def _on_select(self, _event=None) -> None:
        self._update_selection_label()
        if self.selected_indices:
            self._log(f"Targets selected: {sorted(self.selected_indices)}")
            if len(self.selected_indices) == 1:
                iid = str(next(iter(self.selected_indices)))
                if self.tree.exists(iid):
                    vals = self.tree.item(iid, "values")
                    if len(vals) >= 6:
                        pkts = str(vals[5]).split("/")[0].replace(" FAIL", "").replace(" TX", "")
                        if pkts.isdigit():
                            self.packets_var.set(pkts)

    def _select_all(self) -> None:
        ids = self.tree.get_children()
        if ids:
            self.tree.selection_set(ids)
            self._on_select()
            self._log(f"All {len(ids)} networks selected")

    def _clear_selection(self) -> None:
        self.tree.selection_remove(self.tree.selection())
        self.selected_indices.clear()
        self.selected_lbl.configure(text="Selected: (none)", fg=FG_DIM)

    def _on_double_click(self, _event=None) -> None:
        self._on_select()
        if self.selected_indices:
            self._log("Double-click — ready to attack selected target(s)")

    def _ensure_speed_synced(self) -> None:
        speed = self.speed_var.get().strip().lower()
        if speed in SPEED_PROFILES and speed != self._speed_sent:
            self.backend.send(f"SET_SPEED {speed}", timeout=5)
            self._speed_sent = speed

    def _attack_selected(self) -> None:
        if not self._check_agreement():
            return

        self._on_select()
        if not self.selected_indices:
            messagebox.showerror(
                "Error",
                "Select one or more networks (Ctrl+Click for multiple).",
            )
            return

        indices = sorted(self.selected_indices)
        if len(indices) == 1:
            cmd = f"ATTACK_START single {indices[0]}"
            log_msg = f"Starting attack on #{indices[0]}..."
        else:
            idx_str = ",".join(str(i) for i in indices)
            cmd = f"ATTACK_START multi {idx_str}"
            log_msg = f"Starting multi-target attack on {len(indices)} networks: {idx_str}"

        def work():
            self._ensure_speed_synced()
            self.after(0, lambda: self._log(log_msg))
            res = self.backend.send(cmd, timeout=30)
            st = self.backend.read_status()
            self.after(0, lambda: self._log(
                f"Attack: {res} — {st.get('message', '')}"
            ))
            play_sound("lock", self.speed_var.get(), self._last_phase)

        self._run_cmd(work)

    def _attack_all(self) -> None:
        if not self._check_agreement():
            return
        nets = self.backend.read_networks()
        if not nets:
            messagebox.showerror("Error", "No networks — run a scan first.")
            return

        def work():
            self._ensure_speed_synced()
            self._ensure_shift_dwell_synced()
            self._ensure_shift_packets_synced()
            try:
                pkts = int(self.shift_packets_var.get().strip())
            except ValueError:
                pkts = 0
            if pkts > 0:
                self.after(0, lambda: self._log(
                    f"Starting Attack ALL — {pkts} packet(s) per network, then next..."
                ))
            else:
                self.after(0, lambda: self._log(
                    "Starting Attack ALL — time-based shift (set 20/100/500 for packet rule)..."
                ))
            res = self.backend.send("ATTACK_START all", timeout=30)
            self.after(0, lambda: self._log(f"Attack ALL: {res}"))

        self._run_cmd(work)

    def _stop_attack(self) -> None:
        self._log("Stopping attack...")
        self.status_lbl.configure(text="Status: STOPPING ATTACK...")
        self._cmd_busy = False

        def work():
            res = self.backend.send("ATTACK_STOP", timeout=30)
            for _ in range(5):
                st = self.backend.read_status()
                if st.get("phase") != "attacking":
                    break
                self.backend.send("ATTACK_STOP", timeout=15)
                time.sleep(0.3)
            st = self.backend.read_status()
            self.after(0, lambda: (
                self._log(f"Attack stopped: {res} — {st.get('message', '')}"),
                self.status_lbl.configure(
                    text=f"Status: {st.get('phase', 'ready').upper()} — {st.get('message', '')}"
                ),
            ))

        self._run_cmd(work)

    def _poll(self) -> None:
        if not self._running:
            return

        st = self.backend.read_status()
        self._status_cache = st
        phase = st.get("phase", "idle")
        msg = st.get("message", "")
        live = st.get("live_watch", 0)
        net_rev = st.get("net_rev", 0)
        now = time.time()

        if self._monitor_waiting:
            if phase in ("ready", "error") or now >= self._monitor_deadline:
                self._monitor_waiting = False
                self._cmd_busy = False
                mon_msg = msg
                if phase == "error":
                    detail = self.backend.read_last_error()
                    if detail:
                        mon_msg = detail
                self._log(f"Monitor: {phase.upper()} — {mon_msg}")
                if phase == "ready" and st.get("mon_iface"):
                    self._log(f"Verified: {st.get('mon_iface')} in monitor mode")

        if live:
            self.live_lbl.configure(text="● LIVE SCAN", fg=ACCENT)
        else:
            self.live_lbl.configure(text="", fg=FG_DIM)

        if not self._daemon_alive():
            if phase == "scanning":
                self.status_lbl.configure(
                    text="Status: ERROR — Backend crashed during scan. Restart: sudo ./wifi.sh"
                )
                if self._last_phase == "scanning":
                    self._log("ERROR: Daemon died during scan. Check session_data/active/daemon.log")
                    self._last_phase = "daemon_dead"
            elif self._last_phase != "daemon_dead":
                self.status_lbl.configure(text="Status: ERROR — Backend not running")
        elif self._last_phase == "daemon_dead":
            self._last_phase = phase

        speed = st.get("attack_speed", "")
        if speed and speed in SPEED_PROFILES and speed != self.speed_var.get():
            self.speed_var.set(speed)
            self.radar.set_speed(speed)
        sens = st.get("sensitivity", "")
        if sens in ("normal", "high", "max") and sens != self.sensitivity_var.get():
            self.sensitivity_var.set(sens)
            self._sensitivity_sent = sens
        shift = st.get("shift_dwell", 0)
        if shift and float(shift) > 0:
            shift_s = f"{float(shift):g}"
            if shift_s != self.shift_dwell_var.get():
                self.shift_dwell_var.set(shift_s)
                self._shift_dwell_sent = shift_s
        shift_pkts = st.get("shift_packets", 0)
        if shift_pkts is not None:
            shift_p = str(int(shift_pkts))
            if shift_p != self.shift_packets_var.get():
                self.shift_packets_var.set(shift_p)
                self._shift_packets_sent = shift_p
        self.status_lbl.configure(text=f"{phase.upper()}  ·  {msg}")
        self._update_tx_feedback(st)

        if net_rev != self._net_rev:
            self._net_rev = net_rev
            self._refresh_networks(force=True)
        elif phase in ("scanning", "attacking") or live:
            if now - self._last_tree_refresh >= UI_TREE_REFRESH_SEC:
                self._refresh_networks()

        if phase != self._last_phase:
            self._last_phase = phase
            if phase == "ready":
                self._refresh_networks(force=True)

        if phase == "scanning":
            poll_ms = UI_POLL_SCAN_MS
        elif live or phase == "attacking":
            poll_ms = UI_POLL_ACTIVE_MS
        else:
            poll_ms = UI_POLL_IDLE_MS
        self.after(poll_ms, self._poll)

    def _animate_radar(self) -> None:
        if not self._running:
            return
        try:
            radar = self.backend.read_radar()
            status = self._status_cache or self.backend.read_status()
            self.radar.set_speed(status.get("attack_speed", self.speed_var.get()))
            self.radar.draw(radar, status)
        except tk.TclError:
            return
        self.after(UI_RADAR_MS, self._animate_radar)

    def _cleanup_session_data(self) -> None:
        root = os.path.dirname(self.state_dir)
        if os.path.basename(self.state_dir) == "active" and os.path.isdir(root):
            shutil.rmtree(root, ignore_errors=True)

    def _shutdown_backend(self) -> None:
        if not self._daemon_alive():
            return
        try:
            self.backend.send("SCAN_STOP", timeout=8)
        except Exception:
            pass
        try:
            self.backend.send("ATTACK_STOP", timeout=8)
        except Exception:
            pass
        try:
            self.backend.send("SHUTDOWN", timeout=15)
        except Exception:
            pass
        try:
            os.kill(self.daemon_pid, 15)
        except (ProcessLookupError, OSError):
            pass

    def _daemon_alive(self) -> bool:
        try:
            os.kill(self.daemon_pid, 0)
            return True
        except (ProcessLookupError, OSError):
            return False

    def _force_close(self) -> None:
        if not self._running:
            return
        self._running = False

        def work():
            self._shutdown_backend()
            self._cleanup_session_data()

        threading.Thread(target=work, daemon=True).start()
        self.after(300, self.destroy)

    def _on_close(self) -> None:
        if not messagebox.askokcancel("Exit", "Stop all operations and restore adapter?"):
            return
        self._running = False
        self._shutdown_backend()
        self._cleanup_session_data()
        self.destroy()


def main() -> None:
    if len(sys.argv) < 3:
        print("Usage: wifi_dashboard.py <state_dir> <daemon_pid>", file=sys.stderr)
        sys.exit(1)
    app = WifiDashboard(sys.argv[1], sys.argv[2])
    app.mainloop()


if __name__ == "__main__":
    main()
