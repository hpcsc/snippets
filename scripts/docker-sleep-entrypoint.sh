#!/bin/sh
# Reference: https://linuxconfig.org/how-to-propagate-a-signal-to-child-processes-from-a-bash-script

function cleanup() {
    echo "Exiting"
}

function setup_trap() {
    RECEIVED_SIGNAL=$1
    echo "Received ${RECEIVED_SIGNAL}"

    # make sure background process is killed
    kill "${SLEEP_PID}"
    wait "${SLEEP_PID}"

    # now cleanup
    cleanup
}

# respond to SIGTERM/SIGINT signals. Without this, container only responds to SIGINT
trap "setup_trap SIGTERM" SIGTERM
trap "setup_trap SIGINT" SIGINT

echo 'sleeping infiniy'
# `tail -f /dev/null &` works too
sleep infinity &

SLEEP_PID="$!"
wait "${SLEEP_PID}"
