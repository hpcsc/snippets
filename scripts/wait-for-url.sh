#!/bin/bash

set -euo pipefail

CURL_CONNECT_TIMEOUT=5 # seconds
CURL_MAX_TIME=60 # seconds
TIMEOUT_PERIOD=180
DELAY=20

function wait_for_url() {
    set +e
    local url=$1
    local t=$TIMEOUT_PERIOD

    curl --connect-timeout ${CURL_CONNECT_TIMEOUT} --max-time ${CURL_MAX_TIME} --fail -s ${url}
    until [ $? = 0 ]  ; do
        t=$((t - DELAY))
        if [[ $t -eq 0 ]]; then
            echo "=== ${url} is not reachable after $TIMEOUT_PERIOD seconds"
            set -e
            exit 1
        fi

        echo "=== ${url} is not reachable yet, remaining time: $t seconds"
        sleep $DELAY
        curl --connect-timeout ${CURL_CONNECT_TIMEOUT} --max-time ${CURL_MAX_TIME} --fail -s ${url}
    done

    echo "=== ${url} is reachable"
    set -e
}

wait_for_url "$@"
