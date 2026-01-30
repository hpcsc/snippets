#!/bin/bash

cwlogs() {
  local log_group=$1
  local query_string="fields @timestamp, @message"
  local start_time="1 hours ago"
  local end_time="now"

  while [[ $# -gt 1 ]]; do
    case $2 in
      -q|--query)
        query_string="$query_string | $3"
        shift 2
        ;;
      -s|--start)
        start_time="$3"
        shift 2
        ;;
      -e|--end)
        end_time="$3"
        shift 2
        ;;
      --help)
        echo "Usage: cwlogs LOG_GROUP [-q QUERY_STRING] [-s START_TIME] [-e END_TIME]"
        echo ""
        echo "Options:"
        echo "  -g, --log-group    CloudWatch log group name (required)"
        echo "  -q, --query        CloudWatch Insights query string (required)"
        echo "  -h, --hours        Hours ago to search from (default: 1)"
        echo "  -t, --timeout      Query timeout in seconds (default: 10)"
        return 0
        ;;
      *)
        echo "Unknown option: $2"
        echo "Use --help for usage information"
        return 1
        ;;
    esac
  done

  local query_output
  if ! query_output=$(aws logs start-query \
    --log-group-name "$log_group" \
    --start-time $(date -u -d "$start_time" +%s) \
    --end-time $(date -u -d "$end_time" +%s) \
    --query-string "$query_string | sort @timestamp desc | limit 1000" 2>&1); then
  echo "Error starting query: $query_output" >&2
  return 1
  fi

  QUERY_ID=$(echo "$query_output" | jq -r '.queryId // empty')

  if [ -z "$QUERY_ID" ]; then
    echo "Error: Failed to get query ID from response" >&2
    return 1
  fi

  echo "Query ID: $QUERY_ID"

  local elapsed=0
  local timeout=10

  while [ $elapsed -lt $timeout ]; do
    STATUS=$(aws logs get-query-results --query-id $QUERY_ID --query 'status' --output text)
    if [ "$STATUS" = "Complete" ]; then
      # aws logs get-query-results --query-id $QUERY_ID | jq -r '.results[] | map(select(.field == "@message") | .value) | .[]' | hl
      aws logs get-query-results --query-id $QUERY_ID | \
        jq -c '.results[] |
        map({(.field): .value}) |
        add |
        .["@message"] as $msg |
        .["@timestamp"] as $ts |
        (try ($msg | fromjson) catch {"message": $msg}) |
        .timestamp = $ts' | hl
      return 0
    elif [ "$STATUS" = "Failed" ] || [ "$STATUS" = "Cancelled" ]; then
      echo "Query failed"
      return 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  echo "Query timed out after ${timeout}s. Query ID: $QUERY_ID"
  echo "Run: aws logs get-query-results --query-id $QUERY_ID"
  return 1
}

cwlogs $@
