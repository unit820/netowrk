# WiFi Tactical Sonar

A Linux WiFi monitoring and deauthentication toolkit with a tactical sonar-style GUI dashboard. Scan nearby access points, visualize them on a live radar, and run controlled packet tests against your own lab networks.

> **Educational use only.** Only use this tool on networks you own or have explicit written permission to test. Unauthorized access to computer networks is illegal in most jurisdictions.

**Author:** Syed Hassan Bacha

---

## Features

- **GUI dashboard** — Tkinter tactical radar, network list, and live status
- **WiFi scanning** — `airodump-ng` with live network updates during scan
- **Monitor mode** — one-click adapter setup via `airmon-ng`
- **Attack modes**
  - Attack selected network(s)
  - Attack ALL (loop) with time-based or packet-based shifting
  - Packet presets: **20 / 100 / 500** per network, then auto-switch
- **Attack speed profiles** — `low` → `extreme`
- **Signal sensitivity** — `normal`, `high`, `max` (weak/distant AP detection)
- **TX verification** — confirms packets are actually transmitting
- **CLI mode** — interactive terminal workflow without GUI

---

## Requirements

### Hardware

- Linux machine (Kali, Parrot, Ubuntu, etc.)
- USB WiFi adapter with **monitor mode** and **packet injection** support  
  (e.g. adapters with Ralink RT3070 / RT5370 chipsets)

### System packages

```bash
# Debian / Kali / Ubuntu
sudo apt update
sudo apt install -y aircrack-ng iw wireless-tools iproute2 python3 python3-tk

# Optional
sudo apt install -y mdk4 beep
```

### Python

- **Python 3.8+**
- **No pip packages required** — see [`requirements.txt`](requirements.txt)

### Permissions

- **Root / sudo** is required for monitor mode and frame injection

---

## Installation

```bash
git clone https://github.com/YOUR_USERNAME/wifi-tactical-sonar.git
cd wifi-tactical-sonar

chmod +x wifi.sh wifi_dashboard.py
```

---

## Usage

### GUI (default)

```bash
sudo ./wifi.sh
```

This starts the background daemon and opens the **WiFi Tactical Sonar** dashboard.

**Typical workflow:**

1. Select wireless adapter → **Enable Monitor Mode**
2. Set scan duration → **START SCAN**
3. Select target network(s) in the list
4. (Attack ALL) Choose packet preset **20 / 100 / 500** or a custom value
5. Check the educational-use agreement
6. **Attack Selected** or **Attack ALL (loop)**
7. **Restore & Exit** when finished (restores adapter and cleans session data)

### CLI mode

```bash
sudo ./wifi.sh --cli
```

Interactive terminal flow: pick interface → monitor mode → scan → select targets → attack.

### Other modes

| Command | Description |
|---------|-------------|
| `sudo ./wifi.sh` | Launch GUI dashboard (default) |
| `sudo ./wifi.sh --cli` | Interactive CLI |
| `sudo ./wifi.sh --daemon <state_dir>` | Backend daemon only (used internally) |
| `sudo ./wifi.sh --radar <dir>` | Terminal radar viewer |

---

## Project structure

```
.
├── wifi.sh              # Main backend (Bash daemon, scan, attack logic)
├── wifi_dashboard.py    # Tkinter GUI frontend
├── requirements.txt     # Python / system dependency notes
├── README.md
└── session_data/        # Runtime data (auto-created, auto-deleted on exit)
```

### Architecture

```
wifi.sh
 ├── Background daemon (file-based IPC)
 │    ├── status.json, networks.tsv, radar/
 │    └── cmd_queue/*.cmd
 └── wifi_dashboard.py (GUI control panel)
```

---

## Attack ALL — packet shifting

When a packet preset is set (e.g. **100**):

1. Exactly **100 deauth packets** are sent to the current network
2. The tool automatically moves to the **next network**
3. The loop continues through all discovered networks

Set **0** to use time-based shifting instead (seconds per network).

---

## Troubleshooting

| Issue | Suggestion |
|-------|------------|
| `Required tool not found` | Install `aircrack-ng` and `iw` (see Requirements) |
| GUI does not open | Install `python3-tk`; ensure `DISPLAY` is set |
| `TX FAIL` on attack | Try a different adapter; run `aireplay-ng --test <iface>` |
| No networks found | Increase scan time; set sensitivity to **high** or **max** |
| Daemon crash log | Check `session_data/active/daemon.log` |

---

## Legal disclaimer

This software is provided for **education and authorized security testing only**. The author is not responsible for misuse. You are solely responsible for complying with local laws and obtaining proper authorization before testing any network.

---

## License

Add your license here (e.g. MIT, GPL-3.0) before publishing to GitHub.
