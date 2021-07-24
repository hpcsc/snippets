#!/bin/bash

set -euo pipefail

CONTEXT=${1:-minikube}

function replace() {
  # read kube config from stdin
  local config=$(</dev/stdin)
  local yamlPath=$1
  local value=$(echo "${config}" | yq eval "${yamlPath}" -)

  if [ "${value}" != "null" ]; then
    local encoded=$(cat ${value} | base64 -w 0)
    echo "${config}" | \
      yq eval "${yamlPath}-data = \"${encoded}\" | del(\"${yamlPath}\")" -
  else
    echo "${config}"
  fi;
}

kubectl config view --context ${CONTEXT} --minify |
  replace '.clusters[0].cluster.certificate-authority' |
  replace '.users[0].user.client-certificate' |
  replace '.users[0].user.client-key'
