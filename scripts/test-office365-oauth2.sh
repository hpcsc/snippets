#!/usr/bin/env bash
set -euo pipefail

# Test OAuth 2.0 Client Credentials flow for Office 365 IMAP/SMTP
#
# Usage:
#   ./scripts/test-office365-oauth2.sh [--smtp] \
#     --tenant-id <tenant_id> \
#     --client-id <client_id> \
#     --client-secret <client_secret> \
#     --email <user@yourdomain.com>
#
# Options:
#   --smtp    Test SMTP authentication (no email is sent)
#   Default mode tests IMAP access
#
# Or set environment variables:
#   AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, IMAP_EMAIL
#
# Prerequisites — Azure AD App Registration & Permissions
# ========================================================
#
# 1. Register an application in Azure AD (Entra ID):
#    - Go to Azure Portal > Microsoft Entra ID > App registrations > New registration
#    - Name: e.g. "IMAP SMTP OAuth Client"
#    - Supported account types: "Accounts in this organizational directory only"
#    - Click Register
#    - Note the Application (client) ID and Directory (tenant) ID
#
# 2. Create a client secret:
#    - In the app registration, go to Certificates & secrets > Client secrets > New client secret
#    - Set a description and expiry, then click Add
#    - Copy the secret Value immediately (it won't be shown again)
#
# 3. Add API permissions:
#    - Go to API permissions > Add a permission > APIs my organization uses
#    - Search for "Office 365 Exchange Online" (resource ID: 00000002-0000-0ff1-ce00-000000000000)
#    - Select Application permissions and add:
#        - IMAP.AccessAsApp   (for IMAP access)
#        - SMTP.SendAsApp     (for SMTP send, only needed with --smtp)
#    - Click "Grant admin consent for <tenant>" (requires Global Admin or Privileged Role Admin)
#
# 4. Create a service principal for Exchange Online access:
#    - The app registration alone is not enough. You must also register a service principal
#      in Exchange Online and scope it to specific mailboxes.
#    - Connect to Exchange Online PowerShell:
#        Install-Module ExchangeOnlineManagement
#        Connect-ExchangeOnline -UserPrincipalName admin@yourdomain.com
#    - Register the service principal (use the app's Enterprise Application object ID,
#      found under Entra ID > Enterprise applications > search for your app name):
#        New-ServicePrincipal -AppId <client_id> -ServiceId <enterprise_app_object_id>
#    - Grant the service principal access to a specific mailbox:
#        Add-MailboxPermission -Identity "user@yourdomain.com" \
#          -User <enterprise_app_object_id> \
#          -AccessRights FullAccess
#    - Note: Without this step, IMAP/SMTP auth will return "AUTHENTICATE failed" even
#      if the token is valid and API permissions are granted.
#
# 5. Verify:
#    - Run this script with the credentials from steps 1-2 and the target mailbox email.
#    - The token claims should show the correct audience (https://outlook.office365.com)
#      and roles (IMAP.AccessAsApp and/or SMTP.SendAsApp).

TENANT_ID="${AZURE_TENANT_ID:-}"
CLIENT_ID="${AZURE_CLIENT_ID:-}"
CLIENT_SECRET="${AZURE_CLIENT_SECRET:-}"
EMAIL="${IMAP_EMAIL:-}"
MODE="imap"

while [[ $# -gt 0 ]]; do
	case "$1" in
	--tenant-id)
		TENANT_ID="$2"
		shift 2
		;;
	--client-id)
		CLIENT_ID="$2"
		shift 2
		;;
	--client-secret)
		CLIENT_SECRET="$2"
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
		sed -n '3,56p' "$0"
		exit 0
		;;
	*)
		echo "Unknown option: $1" >&2
		exit 1
		;;
	esac
done

for var in TENANT_ID CLIENT_ID CLIENT_SECRET EMAIL; do
	if [[ -z "${!var}" ]]; then
		echo "Error: $var is required. Use --help for usage." >&2
		exit 1
	fi
done

echo "==> Requesting access token..."
TOKEN_RESPONSE=$(curl -s -X POST \
	"https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
	-H "Content-Type: application/x-www-form-urlencoded" \
	-d "client_id=${CLIENT_ID}" \
	-d "client_secret=${CLIENT_SECRET}" \
	-d "scope=https://outlook.office365.com/.default" \
	-d "grant_type=client_credentials")

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
echo "$ACCESS_TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq '{aud, roles, tid, app_displayname}' 2>/dev/null || echo "    (could not decode token)"

test_imap() {
	echo ""
	echo "==> Testing IMAP: LIST mailboxes..."
	curl -v --url "imaps://outlook.office365.com:993" \
		--user "${EMAIL}" \
		--oauth2-bearer "${ACCESS_TOKEN}" \
		-X 'LIST "" "*"' 2>&1 | grep -E "^[*<>]|LIST|OK|NO|BAD|AUTHENTICATE" || true

	echo ""
	echo "==> Testing IMAP: EXAMINE INBOX..."
	curl -v --url "imaps://outlook.office365.com:993/INBOX" \
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
	} | timeout 15 openssl s_client -connect smtp.office365.com:587 -starttls smtp -crlf -quiet 2>/dev/null) || true

	# Show relevant SMTP response lines
	echo "$SMTP_RESULT" | grep -E "^[0-9]{3}" || true

	if echo "$SMTP_RESULT" | grep -q "^235"; then
		echo ""
		echo "==> SMTP authentication successful."
	elif echo "$SMTP_RESULT" | grep -q "^535"; then
		echo ""
		echo "==> SMTP authentication failed. Check token permissions (SMTP.SendAsApp)."
	fi
}

case "$MODE" in
imap) test_imap ;;
smtp) test_smtp ;;
esac

echo ""
echo "==> Done."
