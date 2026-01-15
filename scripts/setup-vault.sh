#!/bin/bash

set -euo pipefail

VAULT_SA_NAME=vault-auth
VAULT_SA_NAMESPACE=my-namespace
V1_AUTH_PREFIX=kubernetes
V1_STS_PREFIX=aws
V2_AUTH_PREFIX=kubernetes-v2
V2_STS_PREFIX=kubernetes-aws
export VAULT_TOKEN=root
export VAULT_ADDR=http://vault:8200

query_k8s_api_server() {
  local endpoint=$1

  K8S_API_SERVER=https://kubernetes.default.svc
  SA_PATH=/var/run/secrets/kubernetes.io/serviceaccount
  SA_TOKEN=$(cat ${SA_PATH}/token)
  SA_CA_CERT=${SA_PATH}/ca.crt

  curl --cacert ${SA_CA_CERT} --header "Authorization: Bearer ${SA_TOKEN}" -X GET ${K8S_API_SERVER}/${endpoint}
}

enable_kubernetes_auth() {
  local auth_prefix=${1}

  if [ -z "$(vault auth list | grep ${auth_prefix})" ]; then
    local vault_sa_secret=$(query_k8s_api_server "api/v1/namespaces/${VAULT_SA_NAMESPACE}/secrets/${VAULT_SA_NAME}")

    local sa_jwt_token=$(echo "${vault_sa_secret}" | jq -r '.data.token' | base64 --decode)
    local sa_ca_crt=$(echo "${vault_sa_secret}" | jq -r '.data["ca.crt"]' | base64 --decode)
    local sa_issuer=$(query_k8s_api_server ".well-known/openid-configuration" | jq -r '.issuer')

    vault auth enable -path=${auth_prefix}/local kubernetes
    vault write auth/${auth_prefix}/local/config \
        token_reviewer_jwt="${sa_jwt_token}" \
        kubernetes_host=https://kubernetes.default \
        kubernetes_ca_cert="${sa_ca_crt}" \
        issuer="${sa_issuer}"
  fi
}

enable_aws_secret_engine() {
  local sts_prefix=${1}

  #  aws secret engine that points to moto as mock aws
  if [ -z "$(vault secrets list | grep ${sts_prefix})" ]; then
    vault secrets enable -path=${sts_prefix} aws
  fi

  vault write ${sts_prefix}/config/root \
    access_key=x \
    secret_key=x \
    region=us-east-1 \
    iam_endpoint=http://mock-aws.interface.svc:5000 \
    sts_endpoint=http://mock-aws.interface.svc:5000
}

associate_policy_to_role() {
    local auth_prefix="$1"
    local policy="$2"
    local role="$3"
    local existing_policies=$(vault read auth/${auth_prefix}/local/role/${role} -format=json | jq -r '.data.policies[]')

    if [ -z $(echo "${existing_policies}" | grep "${policy}") ]; then
      local existing_policies_as_csv="$(echo ${existing_policies} | tr ' ' ',')"
      local new_policies="${existing_policies_as_csv},${policy}"
      vault write "auth/${auth_prefix}/local/role/${role}" \
          bound_service_account_names=* \
          bound_service_account_namespaces=* \
          policies="${new_policies}" \
          ttl=1h
    else
      echo "policy ${policy} is already associated with role ${role} (auth ${auth_prefix}), skipping"
    fi
}

create_sts_role() {
  local auth_prefix=${1}
  local sts_prefix=${2}
  local vault_role=${3}
  local iam_role=${4}

  local policy_name=${vault_role}-${sts_prefix}
  vault policy write "${policy_name}" - <<EOF
path "${sts_prefix}/sts/local-${vault_role}" {
    capabilities = ["read", "update"]
}
EOF

  associate_policy_to_role "${auth_prefix}" "${policy_name}" "${vault_role}"

  vault write "${sts_prefix}/roles/local-${vault_role}" \
      role_arns=arn:aws:iam::000000000000:role/${iam_role} \
      credential_type=assumed_role
}

create_v1_sts_role() {
  create_sts_role "${V1_AUTH_PREFIX}" "${V1_STS_PREFIX}" "${1}" "${2}"
}

create_v2_sts_role() {
  create_sts_role "${V2_AUTH_PREFIX}" "${V2_STS_PREFIX}" "${1}" "${2}"
}

add_kv_read_permissions() {
  # create an additional policy that grants read permissions (read/list) to the provided keys
  # associate the new policy with the given role
  local auth_prefix=${1}
  local vault_role=${2}
  shift 2;
  local policy=""
  for key in "${@}"; do
    policy="${policy}
path \"${key}\" {
  capabilities = [\"read\", \"list\"]
}
"
  done

  local policy_name="${vault_role}-kv"
  vault policy write "${policy_name}" <(echo "${policy}")
  associate_policy_to_role "${auth_prefix}" "${policy_name}" "${vault_role}"
}

setup_vault() {
  local vault_role=$1
  local iam_role=$2

  shift 2;

  # vault v1
  enable_kubernetes_auth "${V1_AUTH_PREFIX}"
  enable_aws_secret_engine "${V1_STS_PREFIX}"
  create_v1_sts_role "${vault_role}" "${iam_role}"

  # vault v2
  enable_kubernetes_auth "${V2_AUTH_PREFIX}"
  enable_aws_secret_engine "${V2_STS_PREFIX}"
  create_v2_sts_role "${vault_role}" "${iam_role}"

  if [ "$#" -ne 0 ]; then
    add_kv_read_permissions "${V1_AUTH_PREFIX}" "${vault_role}" $@
    add_kv_read_permissions "${V2_AUTH_PREFIX}" "${vault_role}" $@
  fi
}

# usage: setup_vault.sh {vault_role} {iam_role} {optional_kv_key_1} {optional_kv_key_2} ...
setup_vault $@
