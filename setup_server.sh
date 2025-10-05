#!/usr/bin/env bash
# setup_server.sh
# All-in-one: Monero Node + Mining Monitor (FastAPI + Telegram Bot)

set -euo pipefail
IFS=$'\n\t'

MONEROD_DATA_DIR="/var/lib/monero"
MONEROD_PORT_P2P=18080
MONEROD_PORT_RPC=18081

APP_DIR="/opt/mining-monitor"
PY_ENV="$APP_DIR/venv"
DB_PATH="$APP_DIR/mining.db"

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-YOUR_TELEGRAM_BOT_TOKEN}"
ADMIN_CHAT_ID="${ADMIN_CHAT_ID:-123456789}"

PYTHON_BIN="python3.10"
echo "[*] Updating system..."
apt-get update -y
apt-get upgrade -y
apt-get install -y curl jq unzip ufw build-essential git cmake pkg-config libssl-dev $PYTHON_BIN python3-venv

echo "[*] Installing Monero node..."
mkdir -p "$MONEROD_DATA_DIR"

LATEST=$(curl -s https://api.github.com/repos/monero-project/monero/releases/latest | jq -r '.assets[] | select(.name|test("linux-x64")) | .browser_download_url' | head -n1)
TMPDIR=$(mktemp -d)
cd "$TMPDIR"
curl -L -o monero.tar.xz "$LATEST"
tar -xJf monero.tar.xz
cd monero-*
cp bin/monerod /usr/local/bin/
chmod +x /usr/local/bin/monerod
cd /
rm -rf "$TMPDIR"

cat >/etc/systemd/system/monerod.service <<EOF
[Unit]
Description=Monero Node
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/monerod --data-dir $MONEROD_DATA_DIR --p2p-bind-ip 0.0.0.0 --p2p-bind-port $MONEROD_PORT_P2P --rpc-bind-ip 127.0.0.1 --rpc-bind-port $MONEROD_PORT_RPC --confirm-external-bind --prune-blockchain
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now monerod

echo "[*] Installing Mining Monitor app..."
mkdir -p "$APP_DIR"
cd "$APP_DIR"

$PYTHON_BIN -m venv "$PY_ENV"
source "$PY_ENV/bin/activate"

cat >requirements.txt <<REQ
fastapi==0.95.2
uvicorn[standard]==0.22.0
sqlmodel==0.0.8
python-telegram-bot==20.7
python-multipart==0.0.6
httpx==0.24.1
REQ
pip install -r requirements.txt

cat >server.py <<'PYCODE'
# Mining Monitor FastAPI + Telegram Bot
import asyncio, os
from datetime import datetime
from typing import Optional
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from sqlmodel import Field, SQLModel, create_engine, Session, select
from pydantic import BaseModel
from telegram import Update
from telegram.ext import ApplicationBuilder, ContextTypes, CommandHandler

TELEGRAM_BOT_TOKEN=os.getenv("TELEGRAM_BOT_TOKEN","")
ADMIN_CHAT_ID=int(os.getenv("ADMIN_CHAT_ID","0"))
DB_PATH=os.getenv("DB_PATH","sqlite:///./mining.db")
ONLINE_TIMEOUT=180

app=FastAPI(title="Mining Fleet Monitor")
app.add_middleware(CORSMiddleware,allow_origins=["*"],allow_methods=["*"],allow_headers=["*"])
engine=create_engine(DB_PATH,connect_args={"check_same_thread":False} if "sqlite" in DB_PATH else {})

class Miner(SQLModel,table=True):
    id:Optional[int]=Field(default=None,primary_key=True)
    machine_id:str=Field(index=True)
    worker:Optional[str]=None
    last_seen:datetime=datetime.utcnow()
    cpu_usage:Optional[float]=None
    hashrate:Optional[float]=None
    unpaid_estimate:Optional[float]=None

class Payment(SQLModel,table=True):
    id:Optional[int]=Field(default=None,primary_key=True)
    machine_id:Optional[str]=Field(index=True)
    worker:Optional[str]=None
    amount:float=0.0
    timestamp:datetime=datetime.utcnow()
    txid:Optional[str]=None

class ReportIn(BaseModel):
    machine_id:str
    worker:Optional[str]=None
    cpu_usage:Optional[float]=None
    hashrate:Optional[float]=None
    unpaid_estimate:Optional[float]=None

class PaymentIn(BaseModel):
    machine_id:Optional[str]
    worker:Optional[str]
    amount:float
    txid:Optional[str]=None

SQLModel.metadata.create_all(engine)

def upsert_miner(r:ReportIn):
    with Session(engine) as s:
        m=s.exec(select(Miner).where(Miner.machine_id==r.machine_id)).first()
        now=datetime.utcnow()
        if m:
            m.last_seen=now
            m.worker=r.worker or m.worker
            m.cpu_usage=r.cpu_usage or m.cpu_usage
            m.hashrate=r.hashrate or m.hashrate
            m.unpaid_estimate=r.unpaid_estimate or m.unpaid_estimate
            s.add(m)
        else:
            s.add(Miner(machine_id=r.machine_id,worker=r.worker,last_seen=now,cpu_usage=r.cpu_usage,hashrate=r.hashrate,unpaid_estimate=r.unpaid_estimate))
        s.commit()

def record_payment(p:PaymentIn):
    with Session(engine) as s:
        pay=Payment(machine_id=p.machine_id,worker=p.worker,amount=p.amount,txid=p.txid,timestamp=datetime.utcnow())
        s.add(pay); s.commit(); s.refresh(pay); return pay

@app.post("/report")
async def report(r:ReportIn):
    upsert_miner(r); return {"status":"ok"}

@app.post("/payment")
async def payment(p:PaymentIn):
    if p.amount<=0: raise HTTPException(400,"amount must be >0")
    pay=record_payment(p); return {"status":"ok","id":pay.id}

@app.get("/machines")
async def machines():
    with Session(engine) as s: return s.exec(select(Miner)).all()

@app.get("/payments")
async def payments():
    with Session(engine) as s: return s.exec(select(Payment).order_by(Payment.timestamp.desc()).limit(20)).all()

# Telegram bot
BOT=None
async def tg_start(u:Update,c:ContextTypes.DEFAULT_TYPE): await u.message.reply_text("Commands: /status /machines")
async def tg_status(u:Update,c:ContextTypes.DEFAULT_TYPE):
    with Session(engine) as s: ms=s.exec(select(Miner)).all()
    now=datetime.utcnow(); on=sum((now-m.last_seen).total_seconds()<=ONLINE_TIMEOUT for m in ms)
    await u.message.reply_text(f"Machines: {len(ms)} Online: {on} Offline: {len(ms)-on}")

async def tg_machines(u:Update,c:ContextTypes.DEFAULT_TYPE):
    with Session(engine) as s: ms=s.exec(select(Miner)).all()
    now=datetime.utcnow(); lines=[]
    for m in ms:
        st="online" if (now-m.last_seen).total_seconds()<=ONLINE_TIMEOUT else "offline"
        lines.append(f"{m.machine_id}|{m.worker or ''}|{st}|CPU={m.cpu_usage or 0}%")
    await u.message.reply_text("\n".join(lines) if lines else "No miners.")

async def run_bot():
    global BOT
    if not TELEGRAM_BOT_TOKEN: return
    BOT=ApplicationBuilder().token(TELEGRAM_BOT_TOKEN).build()
    BOT.add_handler(CommandHandler("start",tg_start))
    BOT.add_handler(CommandHandler("status",tg_status))
    BOT.add_handler(CommandHandler("machines",tg_machines))
    await BOT.initialize(); await BOT.start(); await BOT.updater.start_polling()

@app.on_event("startup")
async def on_startup(): asyncio.create_task(run_bot())
PYCODE

cat >/etc/systemd/system/mining-monitor.service <<EOF
[Unit]
Description=Mining Monitor API + Telegram Bot
After=network.target

[Service]
WorkingDirectory=$APP_DIR
Environment=TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
Environment=ADMIN_CHAT_ID=$ADMIN_CHAT_ID
Environment=DB_PATH=sqlite:///$DB_PATH
ExecStart=$PY_ENV/bin/uvicorn server:app --host 0.0.0.0 --port 8000
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now mining-monitor

ufw allow ssh
ufw allow $MONEROD_PORT_P2P/tcp
ufw allow 8000/tcp
ufw --force enable

echo "======================================"
echo "Setup finished!"
echo "- Monero node running (systemctl status monerod)"
echo "- Mining Monitor running on :8000"
echo "- Telegram bot active (use /status, /machines)"
echo "DB: $DB_PATH"
echo "======================================"