#!/bin/sh
set -e
HYDRA_ADMIN="http://hydra-admin.infra.svc.cluster.local:4445"
HYDRA_PUBLIC="http://hydra-public.infra.svc.cluster.local:4444"
CLIENT_ID="grafana"
CLIENT_SECRET="wBmx6MQKdyPFHkcq97AUE8NXtCWSplOe"
SUBJECT="12a9aecc-68ae-461c-850e-90920b377a19"
REDIRECT_URI="https://grafana.ecoma.io/login/generic_oauth"

echo "=== Step 1: Initiate auth request ==="
AUTH_URL="${HYDRA_PUBLIC}/oauth2/auth?client_id=${CLIENT_ID}&response_type=code&scope=openid+email+profile+offline_access&redirect_uri=${REDIRECT_URI}&state=test123"
AUTH_RESP=$(wget -q --max-redirect=0 -S -O /dev/null "${AUTH_URL}" 2>&1 || true)
LOGIN_CHALLENGE=$(echo "$AUTH_RESP" | grep -o 'login_challenge=[^&"]*' | head -1 | cut -d= -f2)
echo "Login challenge: $LOGIN_CHALLENGE"

echo "=== Step 2: Accept login ==="
ACCEPT_LOGIN=$(wget -qO- --post-data="{\"subject\":\"${SUBJECT}\",\"remember\":false}" \
  --header="Content-Type: application/json" \
  "${HYDRA_ADMIN}/admin/oauth2/auth/requests/login/accept?login_challenge=${LOGIN_CHALLENGE}")
echo "$ACCEPT_LOGIN"
REDIRECT1=$(echo "$ACCEPT_LOGIN" | sed 's/.*"redirect_to":"\([^"]*\)".*/\1/')
echo "Redirect1: $REDIRECT1"

echo "=== Step 3: Follow redirect ==="
CONSENT_RESP=$(wget -q --max-redirect=0 -S -O /dev/null "${REDIRECT1}" 2>&1 || true)
CONSENT_CHALLENGE=$(echo "$CONSENT_RESP" | grep -o 'consent_challenge=[^&"]*' | head -1 | cut -d= -f2)
CODE=$(echo "$CONSENT_RESP" | grep -o 'code=[^&" ]*' | head -1 | cut -d= -f2)
echo "Consent challenge: $CONSENT_CHALLENGE"
echo "Code (if skip_consent): $CODE"

if [ -n "$CONSENT_CHALLENGE" ] && [ -z "$CODE" ]; then
  echo "=== Step 4: Accept consent ==="
  PAYLOAD='{"grant_scope":["openid","email","profile","offline_access"],"grant_access_token_audience":[],"session":{"id_token":{},"access_token":{}}}'
  ACCEPT_CONSENT=$(wget -qO- --post-data="$PAYLOAD" \
    --header="Content-Type: application/json" \
    "${HYDRA_ADMIN}/admin/oauth2/auth/requests/consent/accept?consent_challenge=${CONSENT_CHALLENGE}")
  echo "$ACCEPT_CONSENT"
  REDIRECT2=$(echo "$ACCEPT_CONSENT" | sed 's/.*"redirect_to":"\([^"]*\)".*/\1/')
  CODE_RESP=$(wget -q --max-redirect=0 -S -O /dev/null "${REDIRECT2}" 2>&1 || true)
  CODE=$(echo "$CODE_RESP" | grep -o 'code=[^&" ]*' | head -1 | cut -d= -f2)
fi

echo "Authorization code: $CODE"

echo "=== Step 5: Exchange code for tokens ==="
TOKEN_RESP=$(wget -qO- --post-data="grant_type=authorization_code&code=${CODE}&redirect_uri=${REDIRECT_URI}&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}" \
  "${HYDRA_PUBLIC}/oauth2/token" 2>&1)
echo "Token response:"
echo "$TOKEN_RESP"

ACCESS_TOKEN=$(echo "$TOKEN_RESP" | sed 's/.*"access_token":"\([^"]*\)".*/\1/')

echo "=== Step 6: Call /userinfo ==="
USERINFO=$(wget -qO- --header="Authorization: Bearer ${ACCESS_TOKEN}" "${HYDRA_PUBLIC}/userinfo" 2>&1)
echo "Userinfo response:"
echo "$USERINFO"

echo "=== Step 7: Decode JWT payload ==="
echo "$ACCESS_TOKEN" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null || echo "decode failed"
echo ""

echo "=== Done ==="
