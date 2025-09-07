#!/usr/bin/env bash
set -euo pipefail

############################################
# CONFIGURATION
############################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDFILE_DIR="${SCRIPT_DIR}/.pids"
LOG_DIR="${SCRIPT_DIR}/logs"
MAIN_PIDFILE="${PIDFILE_DIR}/pipeline_main.pid"
LOCKFILE="${PIDFILE_DIR}/pipeline.lock"

WATCHERS=(
    "02_watch_data_dir.sh"
    "03_watch_to_edit.sh"
)

LOG_ROTATE_SIZE=5242880 # 5MB
HEALTH_CHECK_INTERVAL=5 # seconds
DATA_COLLECTION_INTERVAL=60 # seconds

############################################
# SETUP DIRECTORIES
############################################
mkdir -p "$PIDFILE_DIR" "$LOG_DIR"
mkdir -p ./data
mkdir -p ./extraction_data

############################################
# LOGGING FUNCTIONS
############################################
log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_DIR/pipeline.log"
}

rotate_log() {
    local logfile="$1"
    if [[ -f "$logfile" ]]; then
        local size
        size=$(stat -c%s "$logfile")
        if (( size > LOG_ROTATE_SIZE )); then
            mv "$logfile" "${logfile}.1"
            touch "$logfile"
            log_msg "Log rotated: $logfile"
        fi
    fi
}

############################################
# PROCESS CHECKS
############################################
is_running() {
    local pid=$1
    [[ -d "/proc/$pid" ]] || return 1
    # Extra safety: ensure it's our script
    local cmd
    cmd=$(ps -p "$pid" -o cmd= 2>/dev/null || true)
    [[ -n "$cmd" ]] || return 1
    return 0
}

############################################
# WATCHER MANAGEMENT
############################################
start_watcher() {
    local script="$1"
    local script_path="${SCRIPT_DIR}/${script}"
    local pidfile="${PIDFILE_DIR}/${script}.pid"
    local logfile="${LOG_DIR}/${script}.log"

    if [[ -f "$pidfile" ]] && is_running "$(cat "$pidfile")"; then
        log_msg "Watcher $script is already running (PID: $(cat "$pidfile"))"
        return 0
    fi

    if [[ ! -f "$script_path" ]]; then
        log_msg "ERROR: Watcher script $script_path does not exist"
        return 1
    fi

    if [[ ! -x "$script_path" ]]; then
        log_msg "Making $script_path executable..."
        chmod +x "$script_path"
    fi

    log_msg "Starting watcher: $script"
    rotate_log "$logfile"

    # Start watcher in its own process group
    nohup setsid "$script_path" >"$logfile" 2>&1 </dev/null &
    local pid=$!
    echo "$pid" >"$pidfile"
    log_msg "Started $script with PID: $pid"
}

stop_watcher() {
    local script="$1"
    local pidfile="${PIDFILE_DIR}/${script}.pid"

    if [[ -f "$pidfile" ]]; then
        local pid
        pid=$(cat "$pidfile")
        if is_running "$pid"; then
            log_msg "Stopping $script (PID: $pid)"
            # Kill entire process group
            kill -- -"$pid" 2>/dev/null || true
            sleep 2
            if is_running "$pid"; then
                log_msg "Force killing $script (PID: $pid)"
                kill -9 -- -"$pid" 2>/dev/null || true
            fi
        fi
        rm -f "$pidfile"
    fi
}

stop_all_watchers() {
    log_msg "Stopping all watchers..."
    for script in "${WATCHERS[@]}"; do
        stop_watcher "$script"
    done
}

start_all_watchers() {
    log_msg "Starting all watchers..."
    for script in "${WATCHERS[@]}"; do
        start_watcher "$script"
    done
}

check_watcher_status() {
    log_msg "Checking watcher status..."
    for script in "${WATCHERS[@]}"; do
        local pidfile="${PIDFILE_DIR}/${script}.pid"
        if [[ -f "$pidfile" ]] && is_running "$(cat "$pidfile")"; then
            log_msg "✅ $script is running (PID: $(cat "$pidfile"))"
        else
            log_msg "❌ $script is not running"
        fi
    done
}

############################################
# DATA COLLECTION
############################################
run_data_collection() {
    local collect_script="${SCRIPT_DIR}/01_collect_data.sh"
    local logfile="${LOG_DIR}/01_collect_data.log"

    if [[ ! -f "$collect_script" ]]; then
        log_msg "ERROR: Data collection script $collect_script does not exist"
        return 1
    fi

    if [[ ! -x "$collect_script" ]]; then
        log_msg "Making $collect_script executable..."
        chmod +x "$collect_script"
    fi

    rotate_log "$logfile"

    log_msg "Running data collection..."
    if "$collect_script" >>"$logfile" 2>&1; then
        log_msg "✅ Data collection completed successfully"
    else
        log_msg "❌ Data collection failed (check $logfile)"
    fi
}

############################################
# PIPELINE MAIN LOOP
############################################
run_pipeline() {
    log_msg "Starting weather data processing pipeline..."

    # PID lock to avoid multiple instances
    if [[ -f "$LOCKFILE" ]] && is_running "$(cat "$LOCKFILE")"; then
        log_msg "❌ Pipeline already running (PID: $(cat "$LOCKFILE"))"
        exit 1
    fi
    echo $$ >"$LOCKFILE"
    echo $$ >"$MAIN_PIDFILE"

    # Start all watchers
    start_all_watchers

    # Initial data collection
    run_data_collection
    local elapsed=0

    # Main loop
    while true; do
        sleep "$HEALTH_CHECK_INTERVAL"
        elapsed=$((elapsed + HEALTH_CHECK_INTERVAL))

        # Health check for watchers every minute
        for script in "${WATCHERS[@]}"; do
            local pidfile="${PIDFILE_DIR}/${script}.pid"
            if [[ ! -f "$pidfile" ]] || ! is_running "$(cat "$pidfile")"; then
                log_msg "⚠️ Watcher $script stopped, restarting..."
                start_watcher "$script"
            fi
        done

        # Every 30 minutes run data collection
        if ((elapsed >= DATA_COLLECTION_INTERVAL)); then
            run_data_collection
            elapsed=0
        fi
    done
}

############################################
# CLEANUP HANDLER
############################################
cleanup() {
    log_msg "Received shutdown signal, cleaning up..."
    stop_all_watchers
    rm -f "$LOCKFILE" "$MAIN_PIDFILE"
    exit 0
}
trap cleanup SIGINT SIGTERM

############################################
# FULL STOP FOR PIPELINE
############################################
stop_pipeline() {
    log_msg "Stopping full pipeline..."
    stop_all_watchers

    if [[ -f "$MAIN_PIDFILE" ]]; then
        local pid
        pid=$(cat "$MAIN_PIDFILE")
        if is_running "$pid"; then
            log_msg "Stopping main pipeline (PID: $pid)"
            kill -- -"$pid" 2>/dev/null || true
        fi
        rm -f "$MAIN_PIDFILE"
    fi
    rm -f "$LOCKFILE"
    log_msg "Pipeline fully stopped."
}

############################################
# COMMAND LINE INTERFACE
############################################
case "${1:-start}" in
    start)
        run_pipeline
        ;;
    stop)
        stop_pipeline
        ;;
    restart)
        stop_pipeline
        sleep 2
        run_pipeline
        ;;
    status)
        check_watcher_status
        ;;
    collect)
        run_data_collection
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|collect}"
        echo "  start   - Start the pipeline (default)"
        echo "  stop    - Stop all watchers + main loop"
        echo "  restart - Fully restart the pipeline"
        echo "  status  - Check watcher status"
        echo "  collect - Run data collection once"
        exit 1
        ;;
esac
