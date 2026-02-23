#!/usr/bin/env bash
set -euo pipefail

# Test OAuth 2.0 Service Account flow for Gmail IMAP/SMTP
#
# Usage:
#   ./scripts/test-gmail-oauth2.sh [--smtp] \
#     --key-file <service-account-key.json> \
#     --email <user@yourdomain.com>
#
# Options:
#   --smtp    Test SMTP authentication (no email is sent)
#   Default mode tests IMAP access
#
# Or set environment variables:
#   GOOGLE_SA_KEY_FILE, GMAIL_EMAIL
#
# Prerequisites — Google Cloud Service Account & Domain-Wide Delegation
# =====================================================================
#
# 1. Create a GCP project (or use an existing one):
#    - Go to Google Cloud Console > IAM & Admin > Create Project
#    - Note the project ID
#
# 2. Enable the Gmail API:
#    - Go to APIs & Services > Library
#    - Search for "Gmail API" and click Enable
#
# 3. Create a service account:
#    - Go to IAM & Admin > Service Accounts > Create Service Account
#    - Name: e.g. "gmail-imap-client"
#    - Click Create and Continue, then Done
#    - Click on the service account > Keys > Add Key > Create new key > JSON
#    - Save the downloaded JSON key file securely
#    - Note the service account's email (e.g. gmail-imap-client@project.iam.gserviceaccount.com)
#
# 4. Enable domain-wide delegation:
#    - In the service account details, click "Show advanced settings"
#    - Check "Enable Google Workspace Domain-wide Delegation"
#    - Note the Client ID (numeric) shown on the service account details page
#
# 5. Authorize scopes in Google Workspace Admin Console:
#    - Go to admin.google.com > Security > Access and data control > API controls
#    - Under "Domain-wide delegation", click "Manage Domain Wide Delegation"
#    - Click "Add new" and enter:
#        - Client ID: the numeric client ID from step 4
#        - OAuth scopes: https://mail.google.com/
#    - Click Authorize
#    - Note: This requires Google Workspace super admin privileges
#
# 6. Verify:
#    - Run this script with the JSON key file and target mailbox email.
#    - The token claims should show the correct scope and sub (impersonated user).
#
# Dependencies: openssl, jq, curl

KEY_FILE="${GOOGLE_SA_KEY_FILE:-}"
EMAIL="${GMAIL_EMAIL:-}"
MODE="imap"

while [[ $# -gt 0 ]]; do
	case "$1" in
	--key-file)
		KEY_FILE="$2"
		shift 2
		;;
	--email)
		EMAIL="$2"
		shift 2
		;;
	--smtp)
		MODE="smtp"
		shift
		;;
	--help)
		sed -n '3,55p' "$0"
		exit 0
		;;
	*)
		echo "Unknown option: $1" >&2
		exit 1
		;;
	esac
done

for var in KEY_FILE EMAIL; do
	if [[ -z "${!var}" ]]; then
		echo "Error: $var is required. Use --help for usage." >&2
		exit 1
	fi
done

if [[ ! -f "$KEY_FILE" ]]; then
	echo "Error: Key file not found: $KEY_FILE" >&2
	exit 1
fi

# Extract service account fields from the JSON key file
SA_EMAIL=$(jq -r '.client_email' "$KEY_FILE")
PRIVATE_KEY=$(jq -r '.private_key' "$KEY_FILE")

if [[ -z "$SA_EMAIL" || "$SA_EMAIL" == "null" ]]; then
	echo "Error: Could not read client_email from key file." >&2
	exit 1
fi

echo "==> Service account: ${SA_EMAIL}"
echo "==> Impersonating:   ${EMAIL}"

# Build the JWT for the token request
b64url() {
	openssl enc -base64 -A | tr '+/' '-_' | tr -d '='
}

NOW=$(date +%s)
EXP=$((NOW + 3600))

JWT_HEADER=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
JWT_CLAIM=$(printf '{
  "iss": "%s",
  "sub": "%s",
  "scope": "https://mail.google.com/",
  "aud": "https://oauth2.googleapis.com/token",
  "iat": %d,
  "exp": %d
}' "$SA_EMAIL" "$EMAIL" "$NOW" "$EXP" | b64url)

JWT_UNSIGNED="${JWT_HEADER}.${JWT_CLAIM}"

# Sign the JWT with the service account's private key
JWT_SIGNATURE=$(printf '%s' "$JWT_UNSIGNED" \
	| openssl dgst -sha256 -sign <(printf '%s' "$PRIVATE_KEY") \
	| b64url)

SIGNED_JWT="${JWT_UNSIGNED}.${JWT_SIGNATURE}"

echo ""
echo "==> Requesting access token..."
TOKEN_RESPONSE=$(curl -s -X POST "https://oauth2.googleapis.com/token" \
	-H "Content-Type: application/x-www-form-urlencoded" \
	-d "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
	-d "assertion=${SIGNED_JWT}")

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')

if [[ "$ACCESS_TOKEN" == "null" || -z "$ACCESS_TOKEN" ]]; then
	echo "Error: Failed to obtain access token." >&2
	echo "$TOKEN_RESPONSE" | jq . 2>/dev/null || echo "$TOKEN_RESPONSE"
	exit 1
fi

echo "==> Token obtained successfully."
echo "    Expires in: $(echo "$TOKEN_RESPONSE" | jq -r '.expires_in')s"

# Decode and display token claims for debugging
echo ""
echo "==> Token claims:"
echo "$ACCESS_TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq '{iss, sub, scope, aud}' 2>/dev/null || echo "    (could not decode token)"

test_imap() {
	echo ""
	echo "==> Testing IMAP: LIST mailboxes..."
	curl -v --url "imaps://imap.gmail.com:993" \
		--user "${EMAIL}" \
		--oauth2-bearer "${ACCESS_TOKEN}" \
		-X 'LIST "" "*"' 2>&1 | grep -E "^[*<>]|LIST|OK|NO|BAD|AUTHENTICATE" || true

	echo ""
	echo "==> Testing IMAP: EXAMINE INBOX..."
	curl -v --url "imaps://imap.gmail.com:993/INBOX" \
		--user "${EMAIL}" \
		--oauth2-bearer "${ACCESS_TOKEN}" \
		-X "EXAMINE INBOX" 2>&1 | grep -E "^[*<>]|EXISTS|RECENT|UNSEEN|FLAGS|OK|NO|BAD|AUTHENTICATE" || true
}

test_smtp() {
	echo ""
	echo "==> Testing SMTP: AUTH only (no email will be sent)..."

	AUTH_STRING=$(printf "user=%s\001auth=Bearer %s\001\001" "${EMAIL}" "${ACCESS_TOKEN}" | base64 | tr -d '\n')

	# Pace commands with sleep so the server has time to respond between each
	SMTP_RESULT=$({
		sleep 1
		echo "EHLO test"
		sleep 1
		echo "AUTH XOAUTH2 ${AUTH_STRING}"
		sleep 2
		echo "QUIT"
		sleep 1
	} | timeout 15 openssl s_client -connect smtp.gmail.com:587 -starttls smtp -crlf -quiet 2>/dev/null) || true

	# Show relevant SMTP response lines
	echo "$SMTP_RESULT" | grep -E "^[0-9]{3}" || true

	if echo "$SMTP_RESULT" | grep -q "^235"; then
		echo ""
		echo "==> SMTP authentication successful."
	elif echo "$SMTP_RESULT" | grep -q "^535"; then
		echo ""
		echo "==> SMTP authentication failed. Check domain-wide delegation and scopes."
	fi
}

case "$MODE" in
imap) test_imap ;;
smtp) test_smtp ;;
esac

echo ""
echo "==> Done."
