# Make an HTTP API call and handle errors
# Usage: response=$(api_call <error_message> <curl_args...>)
#        exit_code=$(echo "$response" | jq -r '.exit_code')
#        http_code=$(echo "$response" | jq -r '.http_code')
#        body=$(echo "$response" | jq -r '.body')
#        error=$(echo "$response" | jq -r '.error')
# Returns: JSON object with exit_code, http_code, body, and error fields
#   exit_code: 0 on success, 1 on curl failure
#   http_code: HTTP status code (200, 404, 500, etc.)
#   body: HTTP response body (string)
#   error: Error message (empty string on success)
api_call() {
  local error_message="$1"
  shift

  local response
  response=$(curl -s -w "\n%{http_code}" "$@")
  local curl_exit_code=$?

  local http_code=$(echo "$response" | tail -n1)
  local body=$(echo "$response" | sed '$d')

  if [ $curl_exit_code -ne 0 ]; then
    jq -n \
      --arg error_msg "$error_message" \
      --arg body "$body" \
      --argjson curl_exit "$curl_exit_code" \
      '{exit_code: 1, http_code: 0, body: $body, error: ($error_msg + " (curl exit code: " + ($curl_exit | tostring) + ")")}'
    return
  fi

  if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
    jq -n \
      --arg error_msg "$error_message" \
      --arg body "$body" \
      --argjson http_code "$http_code" \
      '{exit_code: 0, http_code: $http_code, body: $body, error: ($error_msg + " (HTTP " + ($http_code | tostring) + "): " + $body)}'
    return
  fi

  jq -n --arg body "$body" --argjson http_code "$http_code" '{exit_code: 0, http_code: $http_code, body: $body, error: ""}'
}

api_call $@
