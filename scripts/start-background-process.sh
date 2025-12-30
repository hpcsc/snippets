#!/bin/bash

# Reusable utility for starting background processes with nohup and PID handling
# Usage: start_background_process <command> <pid_file> [log_file] [description]
#
# Parameters:
#   command:     The command to run in background
#   pid_file:    Path to PID file for process tracking
#   log_file:    Optional path to log file (default: /dev/null)
#   description: Optional description for messages (default: "Process")

set -e

# Check arguments
if [ $# -lt 2 ]; then
    echo "Usage: start_background_process <command> <pid_file> [log_file] [description]" >&2
    exit 1
fi

COMMAND="$1"
PID_FILE="$2"
LOG_FILE="${3:-/dev/null}"
DESCRIPTION="${4:-${COMMAND}}"

# Function to check if existing process is still running and matches our command
check_existing_process() {
    local pid="$1"
    local cmd="$2"

    if kill -0 "$pid" 2>/dev/null; then
        if ps -p "$pid" -o command= 2>/dev/null | grep -q "$(echo "$cmd" | awk '{print $1}')"; then
            return 0  # Process is running and matches
        fi
    fi
    return 1  # Process is dead or doesn't match
}

# Check for existing PID file
if [ -f "$PID_FILE" ]; then
    EXISTING_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")

    if [ -n "$EXISTING_PID" ] && [[ "$EXISTING_PID" =~ ^[0-9]+$ ]]; then
        if check_existing_process "$EXISTING_PID" "$COMMAND"; then
            echo "'$DESCRIPTION' is already running (PID: $EXISTING_PID)"
            exit 0
        else
            echo "PID $EXISTING_PID from $PID_FILE exists but it's not the expected process or is dead"
            rm -f "$PID_FILE"
        fi
    else
        echo "Invalid or empty PID file $PID_FILE, removing"
        rm -f "$PID_FILE"
    fi
fi

# Start the command in background using nohup
# - nohup: prevents SIGHUP signal when terminal closes, keeping process alive
# - &: runs command in background so script can exit
# - $!: captures PID of background process for tracking/management
# - PID file: allows other scripts to find and manage the process

echo "Starting '$DESCRIPTION'..."
nohup $COMMAND > "$LOG_FILE" 2>&1 &
BACKGROUND_PID=$!

# Save PID to file
echo "$BACKGROUND_PID" > "$PID_FILE"

echo "Started '$DESCRIPTION' (PID: $BACKGROUND_PID)"

# Verify the process actually started
sleep 1
if ! kill -0 "$BACKGROUND_PID" 2>/dev/null; then
    echo "Error: Failed to start '$DESCRIPTION'" >&2
    rm -f "$PID_FILE"
    exit 1
fi
