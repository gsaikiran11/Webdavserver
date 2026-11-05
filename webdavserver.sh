#!/data/data/com.termux/files/usr/bin/bash
APP="$HOME/webdav-manager"
CONFIG_OLD="$APP/config"
CONFIG_NEW="$HOME/.webdav-manager/config.json"
PIDFILE="$APP/server.pid"

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; RESET='\033[0m'

mkdir -p ~/.webdav-manager

get_lan_ip(){
 ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

get_tailscale_ip(){
 # Your working method - exactly same as your old script
 if command -v tailscale >/dev/null 2>&1; then
   tailscale ip -4 2>/dev/null | head -n1
 else
   # Fallback for Android App
   ip addr show tailscale0 2>/dev/null | grep -oP '100\.\d+\.\d+\.\d+' | head -n1
   if [ -z "$TS" ]; then
     ifconfig 2>/dev/null | grep -o '100\.[0-9]*\.[0-9]*\.[0-9]*' | head -n1
   fi
 fi
}

# Force 0.0.0.0 like your old working script
export WEBDAV_ADDR="0.0.0.0"
export WEBDAV_PORT="8080"
export WEBDAV_CONFIG="$CONFIG_NEW"
export WEBDAV_RCLONE_CONF="$HOME/.webdav-manager/rclone.conf"
export WEBDAV_WORKDIR="$APP"

# If old config exists, migrate port
if [ -f "$CONFIG_OLD" ]; then
  OLD_PORT=$(sed -n '2p' "$CONFIG_OLD")
  if [[ "$OLD_PORT" =~ ^[0-9]+$ ]]; then
    export WEBDAV_PORT="$OLD_PORT"
  fi
fi

# Also read new config port if exists
if [ -f "$CONFIG_NEW" ]; then
  NEW_PORT=$(grep -o '"listen_port": "[^"]*"' "$CONFIG_NEW" 2>/dev/null | cut -d'"' -f4)
  if [ -z "$NEW_PORT" ]; then
    NEW_PORT=$(python3 -c "import json; print(json.load(open('$CONFIG_NEW')).get('port','8080'))" 2>/dev/null)
  fi
  # Keep 8080 fixed for simplicity
fi

LAN_IP=$(get_lan_ip)
TS_IP=$(get_tailscale_ip)

echo -e "${CYAN}====================================${RESET}"
echo -e "${CYAN}  WEBDAV MANAGER PRO + TAILSCALE${RESET}"
echo -e "${CYAN}====================================${RESET}"
echo "[*] Local IP: $LAN_IP"
if [ ! -z "$TS_IP" ]; then
  echo -e "${GREEN}[✓] Tailscale IP: $TS_IP${RESET}"
  echo -e "${GREEN}[✓] Works on SAME mobile + Remote${RESET}"
  echo ""
  echo -e "${GREEN}ACCESS (Same Phone):${RESET} http://$TS_IP:$WEBDAV_PORT"
  echo -e "${GREEN}ACCESS (Remote Anywhere):${RESET} http://$TS_IP:$WEBDAV_PORT"
  echo -e "${CYAN}Local:${RESET} http://127.0.0.1:$WEBDAV_PORT"
  echo -e "${CYAN}Wi-Fi:${RESET} http://$LAN_IP:$WEBDAV_PORT"
else
  echo -e "${RED}[!] Tailscale not connected - Turn ON Tailscale Android App${RESET}"
  echo "Local: http://127.0.0.1:$WEBDAV_PORT"
  echo "Wi-Fi: http://$LAN_IP:$WEBDAV_PORT"
fi
echo "===================================="

# Force config to 0.0.0.0 for Tailscale to work on same mobile
if [ -f "$CONFIG_NEW" ]; then
  python3 -c "
import json, os
f=os.path.expanduser('~/.webdav-manager/config.json')
try:
 c=json.load(open(f))
 c['listen_addr']='0.0.0.0'
 json.dump(c, open(f,'w'), indent=2)
 print('[*] Forced listen_addr to 0.0.0.0 for Tailscale same-mobile support')
except: pass
"
fi

# Start server - binding 0.0.0.0 like your old rclone command
python3 $APP/server.py
