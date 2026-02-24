# PingShift - Reliable Network Monitor & Failover Daemon

PingShift is a **user-level, customizable network monitoring bash script** designed to silently observe your internet connection's health and dynamically swap to alternative known wireless or wired connections upon severe degradation or complete failure.

It utilizes robust bash-native processing tools including `nmcli`, `iproute2`, and `curl`, coupled with a fail-safe fallback using `systemd` user services, `notify-send`, and desktop audio.

---

## 🚀 Key Features

*   **Two-Tier Connection Quality Monitoring:**
    *   **Light Check (`ping`):** Frequent, ultra-low overhead checks to redundant DNS nameservers.
    *   **Heavy Check (`curl`):** Occasional bandwidth checks validating upload and download thresholds. Designed to limit SSD wear via a persistent payload or `/dev/shm`.
*   **Intelligent Network Failover:** Automatically leverages `nmcli` to identify active alternatives, attempting to switch to prioritized Wi-Fi SSIDs or ethernet interfaces if current data streams fail.
*   **Fully Extensible Config:** Customize endpoint URLs, loop multipliers, and threshold checks purely via `monitor.conf` or standard arguments.
*   **Safe Execution:** Operates exclusively as a user-level process utilizing `systemctl --user`. Never asks for `root` or `sudo`, preventing dangerous global disruptions.

---

## 🛠 Prerequisites & Dependencies

To ensure PingShift operates seamlessly, your Linux distribution must have the following core utilities installed in your `$PATH`:

*   `ping` (iputils-ping)
*   `curl`
*   `nmcli` (NetworkManager command-line configuration tool)
*   `ip` (iproute2 platform package)
*   `awk`
*   `notify-send` (libnotify)
*   `systemctl` (systemd initialization system)
*   *(Optional)* `paplay` (PulseAudio or PipeWire equivalents) for critical system-level alarm tones.

---

## 📦 Installation

To deploy PingShift to your Linux desktop session seamlessly, clone the repository and invoke the standalone install routine:

**Via HTTPS:**
```bash
git clone https://github.com/leodarkseid/pingshift.git
cd pingshift
```

**Via SSH:**
```bash
git clone git@github.com:leodarkseid/pingshift.git
cd pingshift
```

**Installation:**
```bash
chmod +x install.sh
./install.sh
```

**⚠️ Important:** 
1. **Do not run with `sudo`.** You must execute `./install.sh` as your normal desktop user. Admin permissions will cause installation termination, as root cannot typically spawn internal desktop notifications (`notify-send`).
2. The installation automatically builds and enables `pingshift.service` within your `~/.config/systemd/user/` registry, instantly daemonizing the primary loop!

---

## 🏃 Standalone Temporary Usage (No Installation Required)

You do **not** have to install PingShift as a systemd service to use it. You can simply run the script singularly in your terminal. This is great for testing, debugging, or temporary monitoring sessions:

```bash
./run.sh
```

When run this way, the monitor will stay active in your foreground terminal session. It will print its status and any network failover attempts directly to the screen. You can stop it at any time by pressing `Ctrl + C`.

---

## ⚙️ Configuration Reference (`monitor.conf`)

By default, PingShift utilizes reliable, safe thresholds predefined within `monitor.conf`. Standard behaviors can also be manually injected through Command Line Flags.

### Timing & Loop Thresholds
*   `CHECK_INTERVAL=15` — The wait interval (in seconds) between "Light Ping" tests.
*   `HEAVY_CHECK_MULTIPLIER=20` — Decides how many loops PingShift waits before launching the aggressive "Heavy" `curl` upload/download tests against standard targets. Defaults to doing this every `15s * 20 loops (300 seconds; or 5 minutes)`.

### Minimum Operation Requirements
*   `MAX_LATENCY=150` — (ms) Will trigger network failure protocols if ping latencies exceed this metric uniformly across fallback endpoints.
*   `MIN_DL_SPEED=1000000` — Minimum bytes-per-second (~1 MB/s) downstream during periodic heavy checks.
*   `MIN_UL_SPEED=500000` — Minimum bytes-per-second (~0.5 MB/s) upstream during periodic heavy checks.

### Target Validation Endpoints
It is strongly recommended to use standard, reliable DNS domains natively injected into `monitor.conf` for checking connection status:
*   `PING_TARGETS={"1.1.1.1" "8.8.8.8" "9.9.9.9"}`
*   `DL_TARGETS={"http://speedtest.tele2.net/1MB.zip" "https://proof.ovh.net/files/1Mb.dat"}`
*   `UL_TARGETS={"https://httpbin.org/post" "https://ptsv2.com/t/netmon/post"}`

### Command Line Interjection
Invoking `./run.sh` directly allows one-off parameter overrides:
```bash
./run.sh --interval 5 --latency 50 --heavy-loops 60
```

---

## 🏗 System Architecture & Workflow Flow

1. **Bootstrap Initialization:** Upon running `./run.sh`, parsing mechanisms securely eval logic arrays directly out of `monitor.conf`. Command Line overrides parse next. Local payload footprints map into `/dev/shm` dynamically.
2. **Monitoring Loop:** The primary thread kicks into gear.
    *   *(Step A)* Pings are sent to Cloudflare/Google DNS bounds sequentially. If all fail or aggregate latency rises past `${MAX_LATENCY}`, `run_failover_protocol()` initializes.
    *   *(Step B)* Reaching the `HEAVY_CHECK_MULTIPLIER` loop initiates file downloads spanning up to 2MB to limit unneeded network congestion. Upload validations verify symmetrical integrity. 
3. **Failover Execution:** If data links dissolve, the daemon cross-references system routing tables (detecting default UUID bounds). Alternative Wi-Fi arrays map against `nmcli device wifi list`. Connections actively jump over. Verification occurs immediately via light ping tests upon local hardware success. 
4. **Alarms:** In the event that all network fallbacks disconnect natively, a critical payload notifies your operating system via desktop display headers alongside audible warning beeps warning the user of holistic network unavailability!

---

## 🗑 Uninstallation

If you wish to stop utilizing PingShift or want to tear down the environment safely, execute the built-in uninstall script wrapper:

```bash
./uninstall.sh
```

PingShift will systematically unload its system daemon footprint, destroy underlying daemon memory profiles using `systemctl daemon-reload`, and un-assign tracking identifiers cleanly from your `systemctl --user` workspace.

---

## 📝 License 

Provided freely under open-source regulations. (See `LICENSE.md` repository data for explicit conditions).
