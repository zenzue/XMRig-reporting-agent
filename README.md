## 🖥 Mining Fleet Monitor

This project sets up a **Monero Node** + **Mining Monitor API with Telegram Bot** to track mining devices across your network.

It allows you to:

* Run a local **Monero node** (`monerod`) for blockchain sync.
* Collect miner **status reports** (CPU usage, online/offline, worker names).
* Record **payments** manually for bookkeeping.
* Control and query everything via a **Telegram Bot**.

---

## ⚙️ Components

* **Server Side**

  * `monerod` – full/pruned Monero node
  * `mining-monitor` – FastAPI app with:

    * REST endpoints (`/report`, `/machines`, `/payments`)
    * SQLite database for state and payments
    * Telegram bot (commands: `/status`, `/machines`, `/machine <id>`, `/payments`, `/pay`)

* **Client Side (Miners)**

  * `.bat` installer for **XMRig** with auto-start at boot
  * `miner_report.ps1` – background script that posts miner stats every 60s

---

## 📦 Installation

### 1. Server Setup

Run the installer on your Ubuntu/Debian server:

```bash
chmod +x setup_server.sh
sudo ./setup_server.sh
```

This will:

* Install `monerod` to sync blockchain (pruned mode).
* Install Python, FastAPI, and dependencies in `/opt/mining-monitor`.
* Create a `systemd` service for the monitor (`mining-monitor.service`).
* Expose the monitor on port `8000` (HTTP).
* Start both services automatically on boot.

Check services:

```bash
systemctl status monerod
systemctl status mining-monitor
```

Logs:

```bash
journalctl -u monerod -f
journalctl -u mining-monitor -f
```

---

### 2. Miner Setup (Windows 10 PCs)

Run the installer batch file as **Administrator**:

```bat
install_xmrig_and_report.bat
```

It will:

* Download and extract XMRig to `C:\xmrig`
* Create `config.json` for mining
* Install `miner_report.ps1` for periodic reporting
* Create scheduled tasks:

  * **XMRig Miner** → starts mining at boot
  * **Miner Reporter** → posts status every 60s

You can check Task Scheduler → "XMRig Miner" and "Miner Reporter".

---

### 3. Monitor with Telegram

1. Create a bot via [BotFather](https://t.me/botfather) and copy the token.
2. Set environment variables on server before running:

   ```bash
   export TELEGRAM_BOT_TOKEN="your_bot_token"
   export ADMIN_CHAT_ID="your_chat_id"
   ```

   (these are injected in the `mining-monitor` systemd service).
3. Commands available:

   * `/status` → Show total miners, online/offline count
   * `/machines` → List all machines with CPU + status
   * `/machine <id>` → Details of a single miner
   * `/payments` → Show recent payments
   * `/pay <machine_id> <amount> [txid] [note]` → Record a payment (admin only)

---

## 🔗 API Endpoints

* `POST /report` → Miners send heartbeat reports

  ```json
  {
    "machine_id": "PC-01",
    "worker": "worker-PC-01",
    "cpu_usage": 48.5,
    "hashrate": 200,
    "unpaid_estimate": 0.01
  }
  ```
* `GET /machines` → List all registered miners
* `GET /payments` → List payments
* `POST /payment` → Record manual payment

---

## 📂 Directory Layout

```
/opt/mining-monitor
 ├── server.py        # FastAPI + Telegram bot
 ├── requirements.txt # Python dependencies
 ├── mining.db        # SQLite DB (created automatically)
 └── venv/            # Python virtual environment
```

On Windows miners:

```
C:\xmrig
 ├── xmrig.exe
 ├── config.json
 ├── run_xmrig.cmd
 └── miner_report.ps1
```

---

## 🚀 Usage Notes

* Monero blockchain sync can take a long time. Consider `--prune-blockchain` to save disk space.
* Adjust miner CPU usage in `config.json` (`max-threads-hint`) if needed.
* The Telegram bot will only allow `/pay` commands from the `ADMIN_CHAT_ID`.
* By default, the monitor is exposed on **http://SERVER_IP:8000**. Update miner scripts accordingly.