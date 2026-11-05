
#!/data/data/com.termux/files/usr/bin/bash

# ==========================================
# TERMUX WEBDAV MANAGER v2.0
# Powered by rclone
# ==========================================

APP="$HOME/webdav-manager"
CONFIG="$APP/config"
PIDFILE="$APP/server.pid"
LOGFILE="$APP/server.log"

mkdir -p "$APP"
chmod 700 "$APP"

# ---------- COLORS ----------
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

pause() {
    echo
    read -r -p "Press Enter to continue..."
}

load_config() {
    if [ ! -f "$CONFIG" ]; then
        return 1
    fi

    SHARE_DIR=""
    PORT=""
    USERNAME=""
    PASSWORD=""
    MODE=""
    TS_IP=""

    {
        IFS= read -r SHARE_DIR
        IFS= read -r PORT
        IFS= read -r USERNAME
        IFS= read -r PASSWORD
        IFS= read -r MODE
        IFS= read -r TS_IP
    } < "$CONFIG"

    return 0
}

save_config() {
    umask 077
    printf '%s\n' "$SHARE_DIR" "$PORT" "$USERNAME" \
        "$PASSWORD" "$MODE" "$TS_IP" > "$CONFIG"
    chmod 600 "$CONFIG"
}

# ---------- PROCESS CHECK ----------
is_running() {
    if [ -f "$PIDFILE" ]; then
        local pid
        pid=$(cat "$PIDFILE" 2>/dev/null)

        if [[ "$pid" =~ ^[0-9]+$ ]] &&
           kill -0 "$pid" 2>/dev/null; then
            return 0
        fi

        rm -f "$PIDFILE"
    fi

    return 1
}

# ---------- NETWORK ----------
get_lan_ip() {
    ip route get 1.1.1.1 2>/dev/null |
        awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

get_tailscale_ip() {
    if command -v tailscale >/dev/null 2>&1; then
        tailscale ip -4 2>/dev/null | head -n 1
    fi
}

# ---------- CONFIGURATION ----------
configure() {
    if is_running; then
        echo -e "${RED}Stop the server before configuring.${RESET}"
        return
    fi

    load_config

    echo
    echo "========== CONFIGURATION =========="

    read -r -p "Shared folder [${SHARE_DIR:-/storage/emulated/0}]: " input
    SHARE_DIR="${input:-${SHARE_DIR:-/storage/emulated/0}}"

    if [ ! -d "$SHARE_DIR" ]; then
        echo -e "${RED}Folder does not exist!${RESET}"
        return
    fi

    read -r -p "Port [${PORT:-8080}]: " input
    PORT="${input:-${PORT:-8080}}"

    if ! [[ "$PORT" =~ ^[0-9]+$ ]] ||
       (( PORT < 1024 || PORT > 65535 )); then
        echo -e "${RED}Enter a valid port between 1024 and 65535.${RESET}"
        return
    fi

    read -r -p "Username [${USERNAME:-admin}]: " input
    USERNAME="${input:-${USERNAME:-admin}}"

    read -r -s -p "Password (blank keeps existing): " input
    echo

    if [ -n "$input" ]; then
        PASSWORD="$input"
    fi

    if [ -z "$PASSWORD" ]; then
        echo -e "${RED}Password is required.${RESET}"
        return
    fi

    echo
    echo "Access mode:"
    echo "1. Read and write"
    echo "2. Read only"

    read -r -p "Choose [${MODE:-1}]: " input
    MODE="${input:-${MODE:-1}}"

    if [[ "$MODE" != "1" && "$MODE" != "2" ]]; then
        echo "Invalid mode."
        return
    fi

    read -r -p "Tailscale IP (blank = auto-detect): " TS_IP

    save_config

    echo -e "${GREEN}Configuration saved successfully.${RESET}"
}

# ---------- START SERVER ----------
start_server() {
    if ! load_config; then
        echo -e "${YELLOW}Configure the server first.${RESET}"
        return
    fi

    if is_running; then
        echo -e "${YELLOW}Server is already running.${RESET}"
        return
    fi

    if ! command -v rclone >/dev/null 2>&1; then
        echo -e "${RED}rclone not installed.${RESET}"
        echo "Install with: pkg install rclone"
        return
    fi

    if [ ! -d "$SHARE_DIR" ]; then
        echo -e "${RED}Shared folder not found.${RESET}"
        return
    fi

    local extra=()

    if [ "$MODE" = "2" ]; then
        extra+=(--read-only)
    fi

    echo "Starting WebDAV..."

    nohup rclone serve webdav "$SHARE_DIR" \
        --addr "0.0.0.0:$PORT" \
        --user "$USERNAME" \
        --pass "$PASSWORD" \
        "${extra[@]}" \
        > "$LOGFILE" 2>&1 < /dev/null &

    local pid=$!
    echo "$pid" > "$PIDFILE"

    sleep 2

    if kill -0 "$pid" 2>/dev/null; then
        echo -e "${GREEN}WebDAV started successfully!${RESET}"
        show_addresses
    else
        rm -f "$PIDFILE"
        echo -e "${RED}Failed to start WebDAV.${RESET}"
        show_logs
    fi
}

# ---------- STOP SERVER ----------
stop_server() {
    if ! is_running; then
        echo -e "${YELLOW}Server is not running.${RESET}"
        return
    fi

    local pid
    pid=$(cat "$PIDFILE")

    kill "$pid" 2>/dev/null

    for i in {1..10}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done

    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
    fi

    rm -f "$PIDFILE"
    echo -e "${GREEN}Server stopped.${RESET}"
}

# ---------- ADDRESSES ----------
show_addresses() {
    load_config || return

    local LAN_IP
    local TAIL_IP

    LAN_IP=$(get_lan_ip)
    TAIL_IP="$TS_IP"

    if [ -z "$TAIL_IP" ]; then
        TAIL_IP=$(get_tailscale_ip)
    fi

    echo
    echo "========== ACCESS DETAILS =========="

    if [ -n "$LAN_IP" ]; then
        echo -e "${CYAN}Wi-Fi:${RESET} http://$LAN_IP:$PORT"
    fi

    if [ -n "$TAIL_IP" ]; then
        echo -e "${CYAN}Tailscale:${RESET} http://$TAIL_IP:$PORT"
    fi

    echo "Port: $PORT"
    echo "Username: $USERNAME"
    echo "Password: (hidden)"
    echo "Folder: $SHARE_DIR"

    if [ "$MODE" = "2" ]; then
        echo "Permission: Read only"
    else
        echo "Permission: Read and write"
    fi

    echo "===================================="
}

# ---------- STATUS ----------
show_status() {
    echo

    if is_running; then
        echo -e "${GREEN}SERVER STATUS: RUNNING${RESET}"
        show_addresses
    else
        echo -e "${RED}SERVER STATUS: STOPPED${RESET}"
    fi
}

# ---------- LOGS ----------
show_logs() {
    echo
    echo "========== SERVER LOGS =========="

    if [ -f "$LOGFILE" ]; then
        tail -n 40 "$LOGFILE"
    else
        echo "No logs available."
    fi
}

# ---------- RESTART ----------
restart_server() {
    stop_server
    sleep 1
    start_server
}

# ---------- MAIN MENU ----------
while true; do
    clear

    echo -e "${CYAN}"
    echo "===================================="
    echo "       TERMUX WEBDAV MANAGER"
    echo "              v2.0"
    echo "===================================="
    echo -e "${RESET}"

    if is_running; then
        echo -e "Server: ${GREEN}RUNNING${RESET}"
    else
        echo -e "Server: ${RED}STOPPED${RESET}"
    fi

    echo
    echo "1. Start WebDAV"
    echo "2. Stop WebDAV"
    echo "3. Configure WebDAV"
    echo "4. View status and addresses"
    echo "5. View server logs"
    echo "6. Restart WebDAV"
    echo "7. Exit"
    echo

    read -r -p "Select option: " choice

    case "$choice" in
        1) start_server; pause ;;
        2) stop_server; pause ;;
        3) configure; pause ;;
        4) show_status; pause ;;
        5) show_logs; pause ;;
        6) restart_server; pause ;;
        7) echo "Goodbye!"; exit 0 ;;
        *) echo "Invalid option."; pause ;;
    esac
done
