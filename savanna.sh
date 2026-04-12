#!/bin/bash
# savanna.sh — start/stop/status for the Savanna Engine
# Usage: ./savanna.sh [start|stop|status|restart]

SIM_DIR="$(cd "$(dirname "$0")" && pwd)"
SIM_BIN="$SIM_DIR/.build/debug/savanna-cli"
SERVER="/tmp/savanna_server.py"

start() {
    stop 2>/dev/null
    sleep 0.5
    echo "Starting server..."
    python3 "$SERVER" &
    sleep 2
    echo "Server PID: $(pgrep -f savanna_server.py)"
    echo "Sim PID: $(pgrep -f savanna-cli)"
    echo ""
    echo "Open: http://localhost:8765/savanna_live.html"
}

stop() {
    echo "Stopping..."
    pkill -f savanna-cli 2>/dev/null
    pkill -f savanna_server.py 2>/dev/null
    sleep 0.5
    # Verify
    if pgrep -f "savanna-cli|savanna_server" > /dev/null 2>&1; then
        echo "Force killing..."
        pkill -9 -f savanna-cli 2>/dev/null
        pkill -9 -f savanna_server.py 2>/dev/null
        sleep 0.3
    fi
    echo "Stopped."
}

status() {
    echo "=== Savanna Engine Status ==="
    SIM=$(pgrep -f savanna-cli)
    SRV=$(pgrep -f savanna_server.py)
    if [ -n "$SIM" ]; then
        echo "  Simulation: RUNNING (PID $SIM)"
    else
        echo "  Simulation: STOPPED"
    fi
    if [ -n "$SRV" ]; then
        echo "  Server:     RUNNING (PID $SRV)"
    else
        echo "  Server:     STOPPED"
    fi
    if [ -f /tmp/savanna_telemetry.json ]; then
        echo "  Telemetry:  $(cat /tmp/savanna_telemetry.json 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin);print(f"tick={d[\"tick\"]} zebra={d[\"zebra\"]} lion={d[\"lion\"]} tps={d[\"tps\"]}")' 2>/dev/null || echo "stale")"
    fi
}

case "${1:-status}" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; start ;;
    status)  status ;;
    *)       echo "Usage: $0 [start|stop|status|restart]" ;;
esac
