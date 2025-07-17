#!/usr/bin/env bash
set -euo pipefail

# Master pipeline script that orchestrates the entire weather data processing workflow
# - Runs 01_collect_data.sh every 30 minutes to fetch new data
# - Starts all watcher scripts to process data as it arrives
# - Manages background processes and cleanup

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDFILE_DIR="${SCRIPT_DIR}/.pids"
LOG_DIR="${SCRIPT_DIR}/logs"

# Create directories
mkdir -p "$PIDFILE_DIR" "$LOG_DIR"

# Array of watcher scripts to start
WATCHERS=(
    "02_watch_data_dir.sh"
    "03_watch_extract_dir.sh" 
    "04_watch_merge_grib.sh"
    "05_merge_timestamps.sh"
)

# Function to log messages with timestamp
log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_DIR/pipeline.log"
}

# Function to check if a process is running
is_running() {
    local pid=$1
    kill -0 "$pid" 2>/dev/null
}

# Function to start a watcher script in background
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
    nohup "$script_path" > "$logfile" 2>&1 &
    local pid=$!
    echo "$pid" > "$pidfile"
    log_msg "Started $script with PID: $pid"
}

# Function to stop a watcher script
stop_watcher() {
    local script="$1"
    local pidfile="${PIDFILE_DIR}/${script}.pid"
    
    if [[ -f "$pidfile" ]]; then
        local pid=$(cat "$pidfile")
        if is_running "$pid"; then
            log_msg "Stopping $script (PID: $pid)"
            kill "$pid"
            # Wait for process to stop
            local count=0
            while is_running "$pid" && [[ $count -lt 10 ]]; do
                sleep 1
                ((count++))
            done
            if is_running "$pid"; then
                log_msg "Force killing $script (PID: $pid)"
                kill -9 "$pid"
            fi
        fi
        rm -f "$pidfile"
    fi
}

# Function to stop all watchers
stop_all_watchers() {
    log_msg "Stopping all watchers..."
    for script in "${WATCHERS[@]}"; do
        stop_watcher "$script"
    done
}

# Function to start all watchers
start_all_watchers() {
    log_msg "Starting all watchers..."
    for script in "${WATCHERS[@]}"; do
        start_watcher "$script"
    done
}

# Function to check status of all watchers
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

# Function to run data collection
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
    
    log_msg "Running data collection..."
    if "$collect_script" >> "$logfile" 2>&1; then
        log_msg "✅ Data collection completed successfully"
    else
        log_msg "❌ Data collection failed (check $logfile)"
    fi
}

# Function to run the main pipeline loop
run_pipeline() {
    log_msg "Starting weather data processing pipeline..."
    
    # Start all watchers
    start_all_watchers
    
    # Run initial data collection
    run_data_collection
    
    # Main loop - run data collection every 30 minutes
    while true; do
        sleep 1800  # 30 minutes = 1800 seconds
        
        # Check if watchers are still running and restart if needed
        for script in "${WATCHERS[@]}"; do
            local pidfile="${PIDFILE_DIR}/${script}.pid"
            if [[ ! -f "$pidfile" ]] || ! is_running "$(cat "$pidfile")"; then
                log_msg "⚠️  Watcher $script stopped, restarting..."
                start_watcher "$script"
            fi
        done
        
        # Run data collection
        run_data_collection
    done
}

# Signal handlers for graceful shutdown
cleanup() {
    log_msg "Received shutdown signal, cleaning up..."
    stop_all_watchers
    exit 0
}

# Set up signal handlers
trap cleanup SIGINT SIGTERM

# Command line interface
case "${1:-start}" in
    start)
        run_pipeline
        ;;
    stop)
        stop_all_watchers
        ;;
    restart)
        stop_all_watchers
        sleep 2
        start_all_watchers
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
        echo "  stop    - Stop all watchers"
        echo "  restart - Restart all watchers"
        echo "  status  - Check watcher status"
        echo "  collect - Run data collection once"
        exit 1
        ;;
esac