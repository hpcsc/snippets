#!/bin/bash

set -euo pipefail

# usage: verify-cert.sh http-url-to-site-to-check

CURL_MAX_TIME=5 # seconds

parse_date_component() {
  local input=$1
  local component_format=$2
  local component
  set +e

  # try BSD/MacOS date first
  component=$(date -jf '%b %d %H:%M:%S %Y %Z' "${component_format}" "${input}" 2>&1)
  if [ $? -ne 0 ]; then
    # fallback to GNU date if above fails
    component=$(date "${component_format}" -d "${input}" 2>&1)
    if [ $? -ne 0 ]; then
      # fail if fallback also fails
      exit 1
    fi
  fi

  set -e

  echo "${component}"
}

verify_cert() {
    local url=${1}
    local expiry_date=$(curl --max-time ${CURL_MAX_TIME} -v "${url}" 2>&1 | grep 'expire date: ' | sed 's/.*expire date: //')
    echo "Cert for ${url} has expiry date ${expiry_date}"

    local expiry_month=$(parse_date_component "${expiry_date}" "+%m")
    local expiry_year=$(parse_date_component "${expiry_date}" "+%y")

    local current_year=$(date '+%y')
    if [ ${expiry_year} -ne ${current_year} ]; then
        # different year, no need to compare further
        echo "Cert is not expiring in current year ${current_year}"
        exit 0
    fi

    local current_month=$(date '+%m')
    if [ "${current_month}" -lt "${expiry_month}" ]; then
        echo "Cert is not expiring in this month ${current_month}/${current_year}"
        exit
    fi

    echo "Cert is expiring/expired this month ${current_month}/${current_year}, contact compute ASAP to refresh the cert"
    exit 1
}

verify_cert "${1}"
