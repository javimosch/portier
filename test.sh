#!/usr/bin/env bash
# End-to-end: app register, provider config, full SSO code flow (demo + a mocked
# real OIDC provider), open-redirect + state-tamper guards, peage metering/past_due. No
# browser — curl follows the redirects.
set -euo pipefail
cd "$(dirname "$0")"

PORT=18797
IDP_PORT=18798
PEAGE_PORT=18799
DB=$(mktemp -d)/test.db
export PORTIER_DB="$DB" PORTIER_PUBLIC_URL="http://127.0.0.1:$PORT" PORTIER_SECRET="test-secret"
export PORTIER_FREE_AUTHS=2 PORTIER_BLOCK=2
export PORTIER_KEK="00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
export PEAGE_MERCHANT_KEY="pm_test" PEAGE_URL="http://127.0.0.1:$PEAGE_PORT"

# stale listeners from a prior failed run can flake sqlite/provider checks
fuser -k ${PORT}/tcp ${IDP_PORT}/tcp ${PEAGE_PORT}/tcp 2>/dev/null || true
sleep 0.2

# mock IdP: /authorize is not hit by tests (demo/oidc-mock short-circuit token+userinfo)
# mock OIDC token + userinfo
python3 - <<'PY' &
import http.server, json, urllib.parse
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def _j(self,o,c=200):
        b=json.dumps(o).encode(); self.send_response(c)
        self.send_header('content-type','application/json'); self.send_header('content-length',str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def do_POST(self):  # token endpoint
        self.rfile.read(int(self.headers.get('content-length',0)))
        if self.path.startswith('/token-fail'):
            self.send_response(401); self.send_header('content-type','application/json')
            b=b'{"error":"invalid_client"}'; self.send_header('content-length',str(len(b)))
            self.end_headers(); self.wfile.write(b); return
        self._j({"access_token":"AT_mock","token_type":"bearer"})
    def do_GET(self):   # userinfo
        if self.path.startswith('/userinfo-fail'):
            self.send_response(401); self.send_header('content-type','application/json')
            b=b'{"error":"invalid_token"}'; self.send_header('content-length',str(len(b)))
            self.end_headers(); self.wfile.write(b); return
        if self.path.startswith('/userinfo-nosub'):
            self._j({"email":"nosub@corp.com","name":"No Sub User"})
            return
        if self.path.startswith('/github-userinfo'):
            self._j({"id":4242,"login":"octocat","email":"octo@github.com","name":None})
            return
        self._j({"sub":"oidc-sub-9","email":"user@corp.com","name":"Real User"})
http.server.HTTPServer(('127.0.0.1',18798),H).serve_forever()
PY
IDP=$!
# mock peage
python3 - <<'PY' &
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get('content-length',0)))
        b=json.dumps({"ok":1,"charge_id":"c_mock","receipt":"c_mock.deadbeef","amount_cents":100}).encode()
        self.send_response(200); self.send_header('content-type','application/json')
        self.send_header('content-length',str(len(b))); self.end_headers(); self.wfile.write(b)
http.server.HTTPServer(('127.0.0.1',18799),H).serve_forever()
PY
PEAGE=$!
./portier serve -port $PORT 2>/dev/null &
SRV=$!
trap 'kill $SRV $IDP $PEAGE 2>/dev/null || true' EXIT
sleep 0.6

J(){ python3 -c "import json,sys;d=json.load(sys.stdin);print(d$1)"; }
fail(){ echo "FAIL: $1"; exit 1; }
P=0; ok(){ P=$((P+1)); echo "ok $P - $1"; }
B="http://127.0.0.1:$PORT"
# sqlite3 while portier holds WAL can briefly lock — retry instead of flaking
sqlite3_retry() {
  local n=0
  while [ $n -lt 12 ]; do
    if sqlite3 "$@" 2>/dev/null; then return 0; fi
    n=$((n+1)); sleep 0.05
  done
  sqlite3 "$@"
}

curl -sf "$B/_health" | grep -q '"ok":1' || fail health; ok health
curl -sf "$B/llms.txt" | grep -q "one redirect" || fail llms; ok llms.txt
curl -sf "$B/guide" | grep -q '"pay_rail":"peage"' || fail guide; ok guide
curl -sf "$B/guide" | grep -q '"past_due_blocks_new_logins":true' || fail guide-billing; ok "guide documents past_due billing"
curl -sf "$B/guide" | grep -q '"charge_success_requires"' || fail guide-charge-req; ok "guide documents peage charge validation"
curl -sf "$B/guide" | grep -q '"state_binds_provider":true' || fail guide-security; ok "guide documents state/provider binding"
curl -sf "$B/guide" | grep -q '"catch_up_stops_on_decline":true' || fail guide-catchup; ok "guide documents partial catch-up on decline"
curl -sf "$B/guide" | grep -q '"catch_up_max_per_callback":20' || fail guide-catchup-cap; ok "guide documents catch-up loop cap"
curl -sf "$B/guide" | grep -q '"idp_exchange_failure_not_metered":true' || fail guide-idpfail; ok "guide documents IdP exchange failure not metered"
curl -sf "$B/guide" | grep -q '"empty_sub_rejected":true' || fail guide-nosub; ok "guide documents empty sub rejection"
curl -sf "$B/" | grep -q portier || fail landing; ok landing

# register app (redirect_uri required)
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$B/v1/apps" -d '{"name":"noredir"}')" = "400" ] || fail need-redir; ok "redirect_uris required"
APP=$(curl -sf -X POST "$B/v1/apps" -d '{"name":"testapp","redirect_uris":"http://127.0.0.1:9999/done,http://127.0.0.1:9999/done2"}')
AID=$(echo "$APP" | J "['app_id']"); SEC=$(echo "$APP" | J "['app_secret']")
[ -n "$SEC" ] || fail app; ok "app registered ($AID)"

# --- /auth guards: unknown app or provider ---
[ "$(curl -s -o /dev/null -w '%{http_code}' "$B/auth/app_nonexistent/demo?redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fdone&state=x")" = "400" ] || fail auth-unknown-app; ok "unknown app_id rejected at /auth"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$B/auth/$AID/nope?redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fdone&state=x")" = "400" ] || fail auth-unknown-prov; ok "unknown provider rejected at /auth"

# --- provider validation ---
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$B/v1/apps/provider" -H "Authorization: Bearer $SEC" -d '{"kind":"saml"}')" = "400" ] || fail bad-kind; ok "invalid provider kind rejected"
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$B/v1/apps/provider" -H "Authorization: Bearer $SEC" -d '{"kind":"oidc","client_id":"x","client_secret":"y"}')" = "400" ] || fail oidc-urls; ok "oidc without endpoint URLs rejected"
curl -sf -X POST "$B/v1/apps/provider" -H "Authorization: Bearer $SEC" -d '{"name":"scoped","kind":"oidc","client_id":"cid","client_secret":"csec","authorize_url":"http://127.0.0.1:'$IDP_PORT'/authorize","token_url":"http://127.0.0.1:'$IDP_PORT'/token","userinfo_url":"http://127.0.0.1:'$IDP_PORT'/userinfo","scope":"custom_scope"}' | grep -q '"provider":"scoped"' || fail oidc-scope; ok "oidc custom scope accepted"
SC=$(sqlite3_retry "$DB" "SELECT scope FROM providers WHERE app_id='$AID' AND name='scoped';")
[ "$SC" = "custom_scope" ] || fail oidc-scope-db; ok "oidc custom scope persisted"

# provider: demo (no creds needed)
curl -sf -X POST "$B/v1/apps/provider" -H "Authorization: Bearer $SEC" -d '{"kind":"demo"}' | grep -q '"kind":"demo"' || fail demo-prov; ok "demo provider configured"
# provider: github preset (URLs filled in server-side)
GH=$(curl -sf -X POST "$B/v1/apps/provider" -H "Authorization: Bearer $SEC" -d '{"kind":"github","client_id":"ghcid","client_secret":"ghsec"}')
echo "$GH" | grep -q '/cb/github' || fail gh-cb; ok "github IdP callback URL in response"
GHAUTH=$(sqlite3_retry "$DB" "SELECT authorize_url FROM providers WHERE app_id='$AID' AND name='github';")
echo "$GHAUTH" | grep -q 'github.com/login/oauth/authorize' || fail gh-preset; ok "github provider preset authorize_url stored"
# provider upsert: re-POST same name updates credentials
curl -sf -X POST "$B/v1/apps/provider" -H "Authorization: Bearer $SEC" -d '{"kind":"github","client_id":"ghcid2","client_secret":"ghsec2"}' | grep -q '"provider":"github"' || fail gh-upsert; ok "provider upsert updates existing provider"
GHcid=$(sqlite3_retry "$DB" "SELECT client_id FROM providers WHERE app_id='$AID' AND name='github';")
[ "$GHcid" = "ghcid2" ] || fail gh-upsert-id; ok "provider upsert persisted new client_id"
# provider: google preset (URLs filled in server-side)
curl -sf -X POST "$B/v1/apps/provider" -H "Authorization: Bearer $SEC" -d '{"kind":"google","client_id":"gocid","client_secret":"gosec"}' | grep -q '/cb/google' || fail google-cb; ok "google IdP callback URL in response"
GOAUTH=$(sqlite3_retry "$DB" "SELECT authorize_url FROM providers WHERE app_id='$AID' AND name='google';")
echo "$GOAUTH" | grep -q 'accounts.google.com/o/oauth2' || fail google-preset; ok "google provider preset authorize_url stored"
# provider: intrane (machin-idp) preset
curl -sf -X POST "$B/v1/apps/provider" -H "Authorization: Bearer $SEC" -d '{"kind":"intrane","client_id":"icid","client_secret":"isec"}' | grep -q '/cb/intrane' || fail intrane-cb; ok "intrane (machin-idp) callback URL in response"
IAUTH=$(sqlite3_retry "$DB" "SELECT authorize_url FROM providers WHERE app_id='$AID' AND name='intrane';")
echo "$IAUTH" | grep -q 'idp.intrane.fr/authorize' || fail intrane-preset; ok "intrane provider preset authorize_url stored"
# provider: a mocked real OIDC (points token/userinfo at the mock IdP)
curl -sf -X POST "$B/v1/apps/provider" -H "Authorization: Bearer $SEC" -d '{"name":"corp","kind":"oidc","client_id":"cid","client_secret":"csec","authorize_url":"http://127.0.0.1:'$IDP_PORT'/authorize","token_url":"http://127.0.0.1:'$IDP_PORT'/token","userinfo_url":"http://127.0.0.1:'$IDP_PORT'/userinfo"}' | grep -q '"provider":"corp"' || fail oidc-prov; ok "generic OIDC provider configured"

# --- full demo flow: /auth -> (demo short-circuits) -> /cb -> redirect with code -> exchange
LOC=$(curl -s -o /dev/null -w '%{redirect_url}' "$B/auth/$AID/demo?redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fdone&state=csrf123")
echo "$LOC" | grep -q "/cb/demo" || fail auth-demo; ok "/auth (demo) redirects to /cb"
# follow /cb -> it redirects to the app redirect_uri with ?code=
CBLOC=$(curl -s -o /dev/null -w '%{redirect_url}' "$LOC")
echo "$CBLOC" | grep -q "127.0.0.1:9999/done?code=pc_" || fail cb-demo; ok "/cb redirects to app with a portier code"
echo "$CBLOC" | grep -q "state=csrf123" || fail state-pass; ok "app CSRF state is preserved"
PCODE=$(echo "$CBLOC" | sed -n 's/.*code=\(pc_[a-f0-9]*\).*/\1/p')
# exchange the code
ID=$(curl -sf -X POST "$B/v1/token" -H "Authorization: Bearer $SEC" -d '{"code":"'$PCODE'"}')
[ "$(echo "$ID" | J "['identity']['email']")" = "demo@portier" ] || fail token; ok "token exchange returns the identity"
# code is one-time
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$B/v1/token" -H "Authorization: Bearer $SEC" -d '{"code":"'$PCODE'"}')" = "404" ] || fail onetime; ok "portier code is one-time"
# token exchange requires app secret
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$B/v1/token" -d '{"code":"'$PCODE'"}')" = "401" ] || fail token-noauth; ok "token exchange requires Bearer app secret"
# expired portier code -> 410 Gone
Lexp=$(curl -s -o /dev/null -w '%{redirect_url}' "$B/auth/$AID/demo?redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fdone&state=ex")
CLexp=$(curl -s -o /dev/null -w '%{redirect_url}' "$Lexp")
PCexp=$(echo "$CLexp" | sed -n 's/.*code=\(pc_[a-f0-9]*\).*/\1/p')
sqlite3_retry "$DB" "UPDATE codes SET expires_at=1 WHERE code='$PCexp';"
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$B/v1/token" -H "Authorization: Bearer $SEC" -d '{"code":"'$PCexp'"}')" = "410" ] || fail codeexp; ok "expired portier code returns 410 Gone"

# --- real OIDC flow through the mock IdP (token + userinfo) ---
LOC2=$(curl -s -o /dev/null -w '%{redirect_url}' "$B/auth/$AID/corp?redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fdone&state=s2")
echo "$LOC2" | grep -q "127.0.0.1:$IDP_PORT/authorize" || fail auth-oidc; ok "/auth (oidc) redirects to the IdP authorize URL"
ST=$(echo "$LOC2" | sed -n 's/.*state=\([^&]*\).*/\1/p')
CB2=$(curl -s -o /dev/null -w '%{redirect_url}' "$B/cb/corp?code=idpcode&state=$ST")
PC2=$(echo "$CB2" | sed -n 's/.*code=\(pc_[a-f0-9]*\).*/\1/p')
ID2=$(curl -sf -X POST "$B/v1/token" -H "Authorization: Bearer $SEC" -d '{"code":"'$PC2'"}')
[ "$(echo "$ID2" | J "['identity']['email']")" = "user@corp.com" ] || fail oidc-flow; ok "generic OIDC flow yields the IdP identity"
[ "$(echo "$ID2" | J "['identity']['sub']")" = "oidc-sub-9" ] || fail oidc-sub; ok "identity sub from userinfo"

# --- IdP token exchange failure: 400 at /cb, auth_count unchanged ---
AUTH_BEFORE=$(curl -sf "$B/v1/apps/me" -H "Authorization: Bearer $SEC" | J "['auth_count']")
curl -sf -X POST "$B/v1/apps/provider" -H "Authorization: Bearer $SEC" -d '{"name":"badtok","kind":"oidc","client_id":"x","client_secret":"y","authorize_url":"http://127.0.0.1:'$IDP_PORT'/authorize","token_url":"http://127.0.0.1:'$IDP_PORT'/token-fail","userinfo_url":"http://127.0.0.1:'$IDP_PORT'/userinfo"}' >/dev/null
LOCbt=$(curl -s -o /dev/null -w '%{redirect_url}' "$B/auth/$AID/badtok?redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fdone&state=bt")
STbt=$(echo "$LOCbt" | sed -n 's/.*state=\([^&]*\).*/\1/p')
[ "$(curl -s -o /dev/null -w '%{http_code}' "$B/cb/badtok?code=bad&state=$STbt")" = "400" ] || fail idp-tokfail; ok "IdP token exchange failure returns 400"
curl -s "$B/cb/badtok?code=bad&state=$STbt" | grep -q "IdP exchange" || fail idp-tokfail-msg; ok "IdP exchange error surfaced to browser"
[ "$(curl -sf "$B/v1/apps/me" -H "Authorization: Bearer $SEC" | J "['auth_count']")" = "$AUTH_BEFORE" ] || fail idp-tokfail-meter; ok "failed IdP exchange does not meter auth"

# --- IdP userinfo failure: 400 at /cb, auth_count unchanged ---
curl -sf -X POST "$B/v1/apps/provider" -H "Authorization: Bearer $SEC" -d '{"name":"badui","kind":"oidc","client_id":"x","client_secret":"y","authorize_url":"http://127.0.0.1:'$IDP_PORT'/authorize","token_url":"http://127.0.0.1:'$IDP_PORT'/token","userinfo_url":"http://127.0.0.1:'$IDP_PORT'/userinfo-fail"}' >/dev/null
LOCui=$(curl -s -o /dev/null -w '%{redirect_url}' "$B/auth/$AID/badui?redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fdone&state=ui")
STui=$(echo "$LOCui" | sed -n 's/.*state=\([^&]*\).*/\1/p')
[ "$(curl -s -o /dev/null -w '%{http_code}' "$B/cb/badui?code=bad&state=$STui")" = "400" ] || fail idp-uifail; ok "IdP userinfo failure returns 400"
curl -s "$B/cb/badui?code=bad&state=$STui" | grep -q "userinfo" || fail idp-uifail-msg; ok "IdP userinfo error surfaced to browser"
[ "$(curl -sf "$B/v1/apps/me" -H "Authorization: Bearer $SEC" | J "['auth_count']")" = "$AUTH_BEFORE" ] || fail idp-uifail-meter; ok "failed IdP userinfo does not meter auth"

# --- IdP userinfo without sub: 400 at /cb, auth_count unchanged ---
curl -sf -X POST "$B/v1/apps/provider" -H "Authorization: Bearer $SEC" -d '{"name":"nosub","kind":"oidc","client_id":"x","client_secret":"y","authorize_url":"http://127.0.0.1:'$IDP_PORT'/authorize","token_url":"http://127.0.0.1:'$IDP_PORT'/token","userinfo_url":"http://127.0.0.1:'$IDP_PORT'/userinfo-nosub"}' >/dev/null
LOCns=$(curl -s -o /dev/null -w '%{redirect_url}' "$B/auth/$AID/nosub?redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fdone&state=ns")
STns=$(echo "$LOCns" | sed -n 's/.*state=\([^&]*\).*/\1/p')
[ "$(curl -s -o /dev/null -w '%{http_code}' "$B/cb/nosub?code=bad&state=$STns")" = "400" ] || fail idp-nosub; ok "IdP userinfo without sub returns 400"
curl -s "$B/cb/nosub?code=bad&state=$STns" | grep -q "user identifier" || fail idp-nosub-msg; ok "empty sub error surfaced to browser"
[ "$(curl -sf "$B/v1/apps/me" -H "Authorization: Bearer $SEC" | J "['auth_count']")" = "$AUTH_BEFORE" ] || fail idp-nosub-meter; ok "empty sub does not meter auth"

# --- security guards ---
# open redirect: unregistered redirect_uri -> 400
[ "$(curl -s -o /dev/null -w '%{http_code}' "$B/auth/$AID/demo?redirect_uri=http%3A%2F%2Fevil.com%2Fx&state=x")" = "400" ] || fail openredir; ok "unregistered redirect_uri blocked (open-redirect guard)"
# tampered state at /cb -> 400
[ "$(curl -s -o /dev/null -w '%{http_code}' "$B/cb/demo?code=x&state=tampered.deadbeef")" = "400" ] || fail statetamper; ok "tampered state rejected"
# provider in signed state must match /cb/<provider> path
LOCpm=$(curl -s -o /dev/null -w '%{redirect_url}' "$B/auth/$AID/demo?redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fdone&state=pm")
STpm=$(echo "$LOCpm" | sed -n 's/.*state=\([^&]*\).*/\1/p')
[ "$(curl -s -o /dev/null -w '%{http_code}' "$B/cb/github?code=x&state=$STpm")" = "400" ] || fail prov-mismatch; ok "provider mismatch between state and /cb path rejected"
# IdP error redirect (?error=…) -> 400, no token exchange attempted
[ "$(curl -s -o /dev/null -w '%{http_code}' "$B/cb/demo?error=access_denied&error_description=user%20cancelled&state=$STpm")" = "400" ] || fail idp-error; ok "IdP error redirect handled without code exchange"
# missing code at /cb (non-error) -> 400
[ "$(curl -s -o /dev/null -w '%{http_code}' "$B/cb/demo?state=$STpm")" = "400" ] || fail missing-code; ok "missing authorization code rejected at /cb"
# expired signed state at /cb -> 400
EXST=$(python3 -c "import base64,hmac,hashlib; s=b'test-secret'; p='$AID|demo|http://127.0.0.1:9999/done|x|1'; b=base64.b64encode(p.encode()).decode(); print(b+'.'+hmac.new(s,b.encode(),hashlib.sha256).hexdigest())")
[ "$(curl -s -o /dev/null -w '%{http_code}' "$B/cb/demo?code=x&state=$EXST")" = "400" ] || fail stateexp; ok "expired login state rejected"
# code from app A not redeemable by app B
APP2=$(curl -sf -X POST "$B/v1/apps" -d '{"redirect_uris":"http://127.0.0.1:9999/done"}'); SEC2=$(echo "$APP2" | J "['app_secret']")
L=$(curl -s -o /dev/null -w '%{redirect_url}' "$B/auth/$AID/demo?redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fdone&state=z"); CL=$(curl -s -o /dev/null -w '%{redirect_url}' "$L"); PCX=$(echo "$CL" | sed -n 's/.*code=\(pc_[a-f0-9]*\).*/\1/p')
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$B/v1/token" -H "Authorization: Bearer $SEC2" -d '{"code":"'$PCX'"}')" = "403" ] || fail crossapp; ok "code not redeemable by another app"

# --- metering: free tier = 2, wallet set, 3rd+ auths bill in blocks (mock charges 100c) ---
curl -sf -X POST "$B/v1/apps/wallet" -H "Authorization: Bearer $SEC" -d '{"wallet_token":"pw_fundedwallet123"}' | grep -q '"billing_wallet":"set"' || fail wallet; ok "billing wallet set"
# registered alternate redirect_uri works (after wallet — extra auths past free tier need billing)
LOCalt=$(curl -s -o /dev/null -w '%{redirect_url}' "$B/auth/$AID/demo?redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fdone2&state=alt")
CBalt=$(curl -s -o /dev/null -w '%{redirect_url}' "$LOCalt")
echo "$CBalt" | grep -q "127.0.0.1:9999/done2?code=pc_" || fail alt-redir; ok "second registered redirect_uri accepted"

# --- github normalize_identity: userinfo id/login (not sub) -> identity.sub ---
sqlite3_retry "$DB" "UPDATE providers SET authorize_url='http://127.0.0.1:$IDP_PORT/authorize', token_url='http://127.0.0.1:$IDP_PORT/token', userinfo_url='http://127.0.0.1:$IDP_PORT/github-userinfo' WHERE app_id='$AID' AND name='github';"
LOCgh=$(curl -s -o /dev/null -w '%{redirect_url}' "$B/auth/$AID/github?redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fdone&state=gh1")
STgh=$(echo "$LOCgh" | sed -n 's/.*state=\([^&]*\).*/\1/p')
CBgh=$(curl -s -o /dev/null -w '%{redirect_url}' "$B/cb/github?code=ghcode&state=$STgh")
PCgh=$(echo "$CBgh" | sed -n 's/.*code=\(pc_[a-f0-9]*\).*/\1/p')
IDgh=$(curl -sf -X POST "$B/v1/token" -H "Authorization: Bearer $SEC" -d '{"code":"'$PCgh'"}')
[ "$(echo "$IDgh" | J "['identity']['sub']")" = "4242" ] || fail gh-sub; ok "github userinfo id maps to identity.sub"
[ "$(echo "$IDgh" | J "['identity']['name']")" = "octocat" ] || fail gh-name; ok "github userinfo login used when name absent"

# --- google OIDC flow through mock IdP (preset uses generic sub/email/name) ---
sqlite3_retry "$DB" "UPDATE providers SET authorize_url='http://127.0.0.1:$IDP_PORT/authorize', token_url='http://127.0.0.1:$IDP_PORT/token', userinfo_url='http://127.0.0.1:$IDP_PORT/userinfo' WHERE app_id='$AID' AND name='google';"
LOCgo=$(curl -s -o /dev/null -w '%{redirect_url}' "$B/auth/$AID/google?redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fdone&state=go1")
STgo=$(echo "$LOCgo" | sed -n 's/.*state=\([^&]*\).*/\1/p')
CBgo=$(curl -s -o /dev/null -w '%{redirect_url}' "$B/cb/google?code=gocode&state=$STgo")
PCgo=$(echo "$CBgo" | sed -n 's/.*code=\(pc_[a-f0-9]*\).*/\1/p')
IDgo=$(curl -sf -X POST "$B/v1/token" -H "Authorization: Bearer $SEC" -d '{"code":"'$PCgo'"}')
[ "$(echo "$IDgo" | J "['identity']['sub']")" = "oidc-sub-9" ] || fail google-sub; ok "google OIDC flow yields userinfo sub"
[ "$(echo "$IDgo" | J "['identity']['email']")" = "user@corp.com" ] || fail google-email; ok "google OIDC flow yields userinfo email"

# --- intrane (machin-idp) OIDC flow through mock IdP ---
sqlite3_retry "$DB" "UPDATE providers SET authorize_url='http://127.0.0.1:$IDP_PORT/authorize', token_url='http://127.0.0.1:$IDP_PORT/token', userinfo_url='http://127.0.0.1:$IDP_PORT/userinfo' WHERE app_id='$AID' AND name='intrane';"
LOCin=$(curl -s -o /dev/null -w '%{redirect_url}' "$B/auth/$AID/intrane?redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fdone&state=in1")
STin=$(echo "$LOCin" | sed -n 's/.*state=\([^&]*\).*/\1/p')
CBin=$(curl -s -o /dev/null -w '%{redirect_url}' "$B/cb/intrane?code=incode&state=$STin")
PCin=$(echo "$CBin" | sed -n 's/.*code=\(pc_[a-f0-9]*\).*/\1/p')
IDin=$(curl -sf -X POST "$B/v1/token" -H "Authorization: Bearer $SEC" -d '{"code":"'$PCin'"}')
[ "$(echo "$IDin" | J "['identity']['provider']")" = "intrane" ] || fail intrane-prov; ok "intrane OIDC flow returns provider name"
[ "$(echo "$IDin" | J "['identity']['sub']")" = "oidc-sub-9" ] || fail intrane-sub; ok "intrane OIDC flow yields userinfo sub"

# the wallet token is encrypted at rest (not plaintext in the DB)
RAW=$(sqlite3_retry "$DB" "SELECT wallet_token FROM apps WHERE id='$AID';")
echo "$RAW" | grep -q '^enc:' || fail enc-prefix; ok "wallet_token stored AES-GCM encrypted (enc: prefix)"
echo "$RAW" | grep -q 'pw_fundedwallet123' && fail enc-plaintext; ok "plaintext wallet token not in the DB"
# --- wallet KEK: startup migrates legacy plaintext rows to enc: ---
sqlite3_retry "$DB" "UPDATE apps SET wallet_token='pw_fundedwallet123' WHERE id='$AID';"
kill $SRV 2>/dev/null || true
./portier serve -port $PORT 2>/dev/null &
SRV=$!
sleep 0.4
MIG=$(sqlite3_retry "$DB" "SELECT wallet_token FROM apps WHERE id='$AID';")
echo "$MIG" | grep -q '^enc:' || fail kek-migrate; ok "startup migrates plaintext wallet_token to enc:"
echo "$MIG" | grep -q 'pw_fundedwallet123' && fail kek-migrate-plain; ok "migrated wallet no longer plaintext in DB"
# metering: free=2, block=2. Drive demo auths until auth_count crosses free+block,
# then a peage charge (mock -> 200) must bump blocks_charged.
oneauth() {
  L=$(curl -s -o /dev/null -w '%{redirect_url}' "$B/auth/$AID/demo?redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fdone&state=m")
  curl -s -o /dev/null "$L"
}
# already did a few auths above; push through boundary (auth_count>=4 => 1 block chargeable)
i=0; while [ $i -lt 6 ]; do oneauth; i=$((i+1)); done
ME=$(curl -sf "$B/v1/apps/me" -H "Authorization: Bearer $SEC")
[ "$(echo "$ME" | J "['auth_count']")" -ge 4 ] || fail meter-count; ok "auth_count advanced past free+block"
[ "$(echo "$ME" | J "['blocks_charged']")" -ge 1 ] || fail meter-charge; ok "peage charge fired (blocks_charged>=1)"
[ "$(echo "$ME" | J "['billing']")" = "ok" ] || fail meter-billing; ok "billing status ok after charge"

# --- billing: past_due within free tier still allows login ---
sqlite3_retry "$DB" "UPDATE apps SET billing='past_due', auth_count=0 WHERE id='$AID';"
LOCfree=$(curl -s -o /dev/null -w '%{redirect_url}' "$B/auth/$AID/demo?redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fdone&state=ft")
echo "$LOCfree" | grep -q "/cb/demo" || fail pastdue-free; ok "past_due does not block login while free tier remains"
sqlite3_retry "$DB" "UPDATE apps SET billing='ok' WHERE id='$AID';"

# --- billing: multi-block catch-up in one callback ---
sqlite3_retry "$DB" "UPDATE apps SET billing='ok', auth_count=8, blocks_charged=0 WHERE id='$AID';"
oneauth
MEcatch=$(curl -sf "$B/v1/apps/me" -H "Authorization: Bearer $SEC")
[ "$(echo "$MEcatch" | J "['blocks_charged']")" -ge 3 ] || fail multi-catchup; ok "meter_auth catches up multiple owed blocks in one callback"

# --- billing: catch-up capped at 20 blocks per callback (pathological backlog) ---
sqlite3_retry "$DB" "UPDATE apps SET billing='ok', auth_count=48, blocks_charged=0 WHERE id='$AID';"
oneauth
MEcap=$(curl -sf "$B/v1/apps/me" -H "Authorization: Bearer $SEC")
[ "$(echo "$MEcap" | J "['blocks_charged']")" = "20" ] || fail catchup-cap; ok "meter_auth caps catch-up at 20 blocks per callback"

# --- billing: partial catch-up stops on first declined block ---
kill $PEAGE 2>/dev/null || true
python3 - <<'PY' &
import http.server, json
calls = 0
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_POST(self):
        global calls
        calls += 1
        self.rfile.read(int(self.headers.get('content-length',0)))
        if calls == 1:
            b=json.dumps({"ok":1,"charge_id":"c_partial1","receipt":"c_partial1.deadbeef","amount_cents":100}).encode()
            self.send_response(200); self.send_header('content-type','application/json')
            self.send_header('content-length',str(len(b))); self.end_headers(); self.wfile.write(b)
        else:
            b=json.dumps({"ok":0,"error":"insufficient funds"}).encode()
            self.send_response(200); self.send_header('content-type','application/json')
            self.send_header('content-length',str(len(b))); self.end_headers(); self.wfile.write(b)
http.server.HTTPServer(('127.0.0.1',18799),H).serve_forever()
PY
PEAGE=$!
sleep 0.2
sqlite3_retry "$DB" "UPDATE apps SET billing='ok', auth_count=5, blocks_charged=0 WHERE id='$AID';"
oneauth
MEpart=$(curl -sf "$B/v1/apps/me" -H "Authorization: Bearer $SEC")
[ "$(echo "$MEpart" | J "['blocks_charged']")" = "1" ] || fail partial-charge; ok "partial catch-up bills first block then stops on decline"
[ "$(echo "$MEpart" | J "['billing']")" = "past_due" ] || fail partial-pastdue; ok "partial catch-up decline sets past_due"

# restore working peage mock
kill $PEAGE 2>/dev/null || true
python3 - <<'PY' &
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get('content-length',0)))
        b=json.dumps({"ok":1,"charge_id":"c_mock","receipt":"c_mock.deadbeef","amount_cents":100}).encode()
        self.send_response(200); self.send_header('content-type','application/json')
        self.send_header('content-length',str(len(b))); self.end_headers(); self.wfile.write(b)
http.server.HTTPServer(('127.0.0.1',18799),H).serve_forever()
PY
PEAGE=$!
sleep 0.2

# --- billing hardening: past_due blocks new logins; wallet top-up clears it ---
sqlite3_retry "$DB" "UPDATE apps SET billing='past_due', auth_count=5 WHERE id='$AID';"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$B/auth/$AID/demo?redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fdone&state=pd")" = "400" ] || fail pastdue-block; ok "past_due blocks new login initiation"
curl -sf -X POST "$B/v1/apps/wallet" -H "Authorization: Bearer $SEC" -d '{"wallet_token":"pw_fundedwallet123"}' | grep -q '"billing_wallet":"set"' || fail pastdue-wallet; ok "wallet top-up clears past_due"
[ "$(curl -sf "$B/v1/apps/me" -H "Authorization: Bearer $SEC" | J "['billing']")" = "ok" ] || fail pastdue-cleared; ok "billing ok after wallet top-up"
LOCpd=$(curl -s -o /dev/null -w '%{redirect_url}' "$B/auth/$AID/demo?redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fdone&state=pd2")
echo "$LOCpd" | grep -q "/cb/demo" || fail pastdue-unblock; ok "login works again after wallet top-up"

# --- peage charge decline -> past_due (swap mock to 402) ---
kill $PEAGE 2>/dev/null || true
python3 - <<'PY' &
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get('content-length',0)))
        b=json.dumps({"ok":0,"error":"insufficient funds"}).encode()
        self.send_response(402); self.send_header('content-type','application/json')
        self.send_header('content-length',str(len(b))); self.end_headers(); self.wfile.write(b)
http.server.HTTPServer(('127.0.0.1',18799),H).serve_forever()
PY
PEAGE=$!
sleep 0.2
sqlite3_retry "$DB" "UPDATE apps SET billing='ok', auth_count=3, blocks_charged=0 WHERE id='$AID';"
oneauth
[ "$(curl -sf "$B/v1/apps/me" -H "Authorization: Bearer $SEC" | J "['billing']")" = "past_due" ] || fail decline-pastdue; ok "peage charge decline sets past_due"

# --- billing: peage HTTP 200 but ok:0 in body -> past_due (not counted as billed) ---
kill $PEAGE 2>/dev/null || true
python3 - <<'PY' &
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get('content-length',0)))
        b=json.dumps({"ok":0,"error":"declined silently"}).encode()
        self.send_response(200); self.send_header('content-type','application/json')
        self.send_header('content-length',str(len(b))); self.end_headers(); self.wfile.write(b)
http.server.HTTPServer(('127.0.0.1',18799),H).serve_forever()
PY
PEAGE=$!
sleep 0.2
sqlite3_retry "$DB" "UPDATE apps SET billing='ok', auth_count=3, blocks_charged=0 WHERE id='$AID';"
oneauth
[ "$(curl -sf "$B/v1/apps/me" -H "Authorization: Bearer $SEC" | J "['billing']")" = "past_due" ] || fail ok0-pastdue; ok "peage 200 with ok:0 sets past_due"
[ "$(curl -sf "$B/v1/apps/me" -H "Authorization: Bearer $SEC" | J "['blocks_charged']")" = "0" ] || fail ok0-nocharge; ok "peage 200 with ok:0 does not increment blocks_charged"

# --- billing: peage HTTP 200 with ok as JSON string "1" -> billed ---
kill $PEAGE 2>/dev/null || true
python3 - <<'PY' &
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get('content-length',0)))
        b=json.dumps({"ok":"1","charge_id":"c_str","receipt":"c_str.deadbeef","amount_cents":100}).encode()
        self.send_response(200); self.send_header('content-type','application/json')
        self.send_header('content-length',str(len(b))); self.end_headers(); self.wfile.write(b)
http.server.HTTPServer(('127.0.0.1',18799),H).serve_forever()
PY
PEAGE=$!
sleep 0.2
sqlite3_retry "$DB" "UPDATE apps SET billing='ok', auth_count=3, blocks_charged=0 WHERE id='$AID';"
oneauth
[ "$(curl -sf "$B/v1/apps/me" -H "Authorization: Bearer $SEC" | J "['blocks_charged']")" = "1" ] || fail okstr-charge; ok "peage 200 with ok string \"1\" increments blocks_charged"
[ "$(curl -sf "$B/v1/apps/me" -H "Authorization: Bearer $SEC" | J "['billing']")" = "ok" ] || fail okstr-billing; ok "peage 200 with ok string \"1\" keeps billing ok"

# --- billing: peage HTTP 200 with ok:true (boolean) -> billed ---
kill $PEAGE 2>/dev/null || true
python3 - <<'PY' &
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get('content-length',0)))
        b=json.dumps({"ok":True,"charge_id":"c_bool","receipt":"c_bool.deadbeef","amount_cents":100}).encode()
        self.send_response(200); self.send_header('content-type','application/json')
        self.send_header('content-length',str(len(b))); self.end_headers(); self.wfile.write(b)
http.server.HTTPServer(('127.0.0.1',18799),H).serve_forever()
PY
PEAGE=$!
sleep 0.2
sqlite3_retry "$DB" "UPDATE apps SET billing='ok', auth_count=3, blocks_charged=0 WHERE id='$AID';"
oneauth
[ "$(curl -sf "$B/v1/apps/me" -H "Authorization: Bearer $SEC" | J "['blocks_charged']")" = "1" ] || fail okbool-charge; ok "peage 200 with ok:true increments blocks_charged"
[ "$(curl -sf "$B/v1/apps/me" -H "Authorization: Bearer $SEC" | J "['billing']")" = "ok" ] || fail okbool-billing; ok "peage 200 with ok:true keeps billing ok"

# --- billing: peage HTTP 200 with missing ok field -> past_due ---
kill $PEAGE 2>/dev/null || true
python3 - <<'PY' &
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get('content-length',0)))
        b=json.dumps({"charge_id":"c_nook","receipt":"c_nook.deadbeef","amount_cents":100}).encode()
        self.send_response(200); self.send_header('content-type','application/json')
        self.send_header('content-length',str(len(b))); self.end_headers(); self.wfile.write(b)
http.server.HTTPServer(('127.0.0.1',18799),H).serve_forever()
PY
PEAGE=$!
sleep 0.2
sqlite3_retry "$DB" "UPDATE apps SET billing='ok', auth_count=3, blocks_charged=0 WHERE id='$AID';"
oneauth
[ "$(curl -sf "$B/v1/apps/me" -H "Authorization: Bearer $SEC" | J "['billing']")" = "past_due" ] || fail nook-pastdue; ok "peage 200 with missing ok sets past_due"
[ "$(curl -sf "$B/v1/apps/me" -H "Authorization: Bearer $SEC" | J "['blocks_charged']")" = "0" ] || fail nook-nocharge; ok "peage 200 with missing ok does not increment blocks_charged"

# --- billing: peage HTTP 200 whitespace-only body -> past_due ---
kill $PEAGE 2>/dev/null || true
python3 - <<'PY' &
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get('content-length',0)))
        b=b'   \n  '
        self.send_response(200); self.send_header('content-type','application/json')
        self.send_header('content-length',str(len(b))); self.end_headers(); self.wfile.write(b)
http.server.HTTPServer(('127.0.0.1',18799),H).serve_forever()
PY
PEAGE=$!
sleep 0.2
sqlite3_retry "$DB" "UPDATE apps SET billing='ok', auth_count=3, blocks_charged=0 WHERE id='$AID';"
oneauth
[ "$(curl -sf "$B/v1/apps/me" -H "Authorization: Bearer $SEC" | J "['billing']")" = "past_due" ] || fail peage-ws; ok "peage HTTP 200 whitespace body sets past_due"

# --- billing: peage HTTP 500 -> past_due ---
kill $PEAGE 2>/dev/null || true
python3 - <<'PY' &
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get('content-length',0)))
        self.send_response(500); self.send_header('content-length','0'); self.end_headers()
http.server.HTTPServer(('127.0.0.1',18799),H).serve_forever()
PY
PEAGE=$!
sleep 0.2
sqlite3_retry "$DB" "UPDATE apps SET billing='ok', auth_count=3, blocks_charged=0 WHERE id='$AID';"
oneauth
[ "$(curl -sf "$B/v1/apps/me" -H "Authorization: Bearer $SEC" | J "['billing']")" = "past_due" ] || fail peage-500; ok "peage HTTP 500 sets past_due"

# --- billing: peage HTTP 200 empty body -> past_due ---
kill $PEAGE 2>/dev/null || true
python3 - <<'PY' &
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get('content-length',0)))
        self.send_response(200); self.send_header('content-type','application/json')
        self.send_header('content-length','0'); self.end_headers()
http.server.HTTPServer(('127.0.0.1',18799),H).serve_forever()
PY
PEAGE=$!
sleep 0.2
sqlite3_retry "$DB" "UPDATE apps SET billing='ok', auth_count=3, blocks_charged=0 WHERE id='$AID';"
oneauth
[ "$(curl -sf "$B/v1/apps/me" -H "Authorization: Bearer $SEC" | J "['billing']")" = "past_due" ] || fail peage-empty; ok "peage HTTP 200 empty body sets past_due"

# --- billing: peage HTTP 200 malformed JSON -> past_due ---
kill $PEAGE 2>/dev/null || true
python3 - <<'PY' &
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get('content-length',0)))
        b=b'not-json'
        self.send_response(200); self.send_header('content-type','application/json')
        self.send_header('content-length',str(len(b))); self.end_headers(); self.wfile.write(b)
http.server.HTTPServer(('127.0.0.1',18799),H).serve_forever()
PY
PEAGE=$!
sleep 0.2
sqlite3_retry "$DB" "UPDATE apps SET billing='ok', auth_count=3, blocks_charged=0 WHERE id='$AID';"
oneauth
[ "$(curl -sf "$B/v1/apps/me" -H "Authorization: Bearer $SEC" | J "['billing']")" = "past_due" ] || fail peage-badjson; ok "peage HTTP 200 malformed JSON sets past_due"

# --- billing: peage unreachable (no listener) -> past_due ---
kill $PEAGE 2>/dev/null || true
sleep 0.2
sqlite3_retry "$DB" "UPDATE apps SET billing='ok', auth_count=3, blocks_charged=0 WHERE id='$AID';"
oneauth
[ "$(curl -sf "$B/v1/apps/me" -H "Authorization: Bearer $SEC" | J "['billing']")" = "past_due" ] || fail peage-down; ok "peage unreachable sets past_due"

# --- billing: charge POST includes idempotency_key app_id:block:N ---
LAST_CHARGE=$(mktemp)
kill $PEAGE 2>/dev/null || true
python3 - "$LAST_CHARGE" <<'PY' &
import http.server, json, sys
last = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_POST(self):
        n = int(self.headers.get('content-length',0))
        open(last, 'w').write(self.rfile.read(n).decode())
        b = json.dumps({"ok":1,"charge_id":"c_idem","receipt":"c_idem.deadbeef","amount_cents":100}).encode()
        self.send_response(200); self.send_header('content-type','application/json')
        self.send_header('content-length',str(len(b))); self.end_headers(); self.wfile.write(b)
http.server.HTTPServer(('127.0.0.1',18799),H).serve_forever()
PY
PEAGE=$!
sleep 0.2
sqlite3_retry "$DB" "UPDATE apps SET billing='ok', auth_count=3, blocks_charged=0 WHERE id='$AID';"
oneauth
grep -q "${AID}:block:1" "$LAST_CHARGE" || fail idem-key; ok "peage charge uses idempotency_key app_id:block:N"
rm -f "$LAST_CHARGE"

# restore declining peage mock for in-flight failure test
kill $PEAGE 2>/dev/null || true
python3 - <<'PY' &
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get('content-length',0)))
        b=json.dumps({"ok":0,"error":"declined silently"}).encode()
        self.send_response(200); self.send_header('content-type','application/json')
        self.send_header('content-length',str(len(b))); self.end_headers(); self.wfile.write(b)
http.server.HTTPServer(('127.0.0.1',18799),H).serve_forever()
PY
PEAGE=$!
sleep 0.2

# --- billing: in-flight login completes even when charge fails in callback ---
sqlite3_retry "$DB" "UPDATE apps SET billing='ok', auth_count=3, blocks_charged=0 WHERE id='$AID';"
Lif=$(curl -s -o /dev/null -w '%{redirect_url}' "$B/auth/$AID/demo?redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fdone&state=if")
CBif=$(curl -s -o /dev/null -w '%{redirect_url}' "$Lif")
echo "$CBif" | grep -q "127.0.0.1:9999/done?code=pc_" || fail inflight-code; ok "in-flight login completes when peage charge fails"
[ "$(curl -sf "$B/v1/apps/me" -H "Authorization: Bearer $SEC" | J "['billing']")" = "past_due" ] || fail inflight-pastdue; ok "charge failure during callback sets past_due after login completes"

# restore working peage mock for any follow-on
kill $PEAGE 2>/dev/null || true
python3 - <<'PY' &
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get('content-length',0)))
        b=json.dumps({"ok":1,"charge_id":"c_mock","receipt":"c_mock.deadbeef","amount_cents":100}).encode()
        self.send_response(200); self.send_header('content-type','application/json')
        self.send_header('content-length',str(len(b))); self.end_headers(); self.wfile.write(b)
http.server.HTTPServer(('127.0.0.1',18799),H).serve_forever()
PY
PEAGE=$!
sleep 0.2

# --- billing: no wallet past free tier -> charge fails -> past_due blocks /auth ---
NOWALLET=$(curl -sf -X POST "$B/v1/apps" -d '{"name":"nowallet","redirect_uris":"http://127.0.0.1:9999/done"}')
NWID=$(echo "$NOWALLET" | J "['app_id']"); NWSEC=$(echo "$NOWALLET" | J "['app_secret']")
curl -sf -X POST "$B/v1/apps/provider" -H "Authorization: Bearer $NWSEC" -d '{"kind":"demo"}' >/dev/null
sqlite3_retry "$DB" "UPDATE apps SET auth_count=3, blocks_charged=0, billing='ok', wallet_token='' WHERE id='$NWID';"
Lnw=$(curl -s -o /dev/null -w '%{redirect_url}' "$B/auth/$NWID/demo?redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fdone&state=nw")
curl -s -o /dev/null "$Lnw"
[ "$(curl -sf "$B/v1/apps/me" -H "Authorization: Bearer $NWSEC" | J "['billing']")" = "past_due" ] || fail nowallet-pastdue; ok "missing wallet past free tier sets past_due"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$B/auth/$NWID/demo?redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fdone&state=nw2")" = "400" ] || fail nowallet-block; ok "past_due without wallet blocks new login initiation"

# --- billing: missing PEAGE_MERCHANT_KEY -> past_due on charge ---
kill $SRV 2>/dev/null || true
unset PEAGE_MERCHANT_KEY
./portier serve -port $PORT 2>/dev/null &
SRV=$!
sleep 0.4
sqlite3_retry "$DB" "UPDATE apps SET billing='ok', auth_count=3, blocks_charged=0 WHERE id='$AID';"
oneauth
[ "$(curl -sf "$B/v1/apps/me" -H "Authorization: Bearer $SEC" | J "['billing']")" = "past_due" ] || fail no-merchant; ok "missing PEAGE_MERCHANT_KEY sets past_due on charge"
kill $SRV 2>/dev/null || true
export PEAGE_MERCHANT_KEY="pm_test"
./portier serve -port $PORT 2>/dev/null &
SRV=$!
sleep 0.4
sqlite3_retry "$DB" "UPDATE apps SET billing='ok' WHERE id='$AID';"

# --- wallet KEK: encrypted token unreadable without PORTIER_KEK -> past_due on charge ---
kill $SRV 2>/dev/null || true
unset PORTIER_KEK
./portier serve -port $PORT 2>/dev/null &
SRV=$!
sleep 0.4
sqlite3_retry "$DB" "UPDATE apps SET billing='ok', auth_count=3, blocks_charged=0 WHERE id='$AID';"
oneauth
[ "$(curl -sf "$B/v1/apps/me" -H "Authorization: Bearer $SEC" | J "['billing']")" = "past_due" ] || fail no-kek; ok "encrypted wallet without PORTIER_KEK sets past_due on charge"
kill $SRV 2>/dev/null || true
export PORTIER_KEK="00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
./portier serve -port $PORT 2>/dev/null &
SRV=$!
sleep 0.4
sqlite3_retry "$DB" "UPDATE apps SET billing='ok' WHERE id='$AID';"

# --- feedback intake ---
FB=$(curl -sf -X POST "$B/v1/feedback" -d '{"message":"e2e test feedback","kind":"test"}')
echo "$FB" | grep -q '"stored":true' || fail feedback; ok "POST /v1/feedback stores feedback"
FBID="fb-e2e-dup-$(date +%s)"
curl -sf -X POST "$B/v1/feedback" -d '{"id":"'$FBID'","message":"first","kind":"test"}' | grep -q '"stored":true' || fail fb-idem; ok "feedback accepts client-supplied id"
curl -sf -X POST "$B/v1/feedback" -d '{"id":"'$FBID'","message":"duplicate","kind":"test"}' | grep -q '"stored":true' || fail fb-idem2; ok "feedback duplicate id is idempotent"
[ "$(sqlite3_retry "$DB" "SELECT count(*) FROM feedback WHERE id='$FBID';")" = "1" ] || fail fb-idem-db; ok "feedback duplicate id does not insert twice"
FB413=$(python3 -c "print('x'*17000)")
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$B/v1/feedback" -d '{"message":"'$FB413'"}')" = "413" ] || fail fb-413; ok "feedback payload over 16 KiB returns 413"

# --- provider delete ---
curl -sf -X DELETE "$B/v1/apps/provider" -H "Authorization: Bearer $SEC" -d '{"name":"corp"}' | grep -q '"removed":"corp"' || fail prov-del; ok "DELETE /v1/apps/provider removes provider"
[ "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$B/v1/apps/provider" -H "Authorization: Bearer $SEC" -d '{"name":"nope"}')" = "404" ] || fail prov-del-404; ok "DELETE unknown provider -> 404"

# operator CLI
./portier app-new -name ops -redirect https://x/y | grep -q '"ok":true' || fail cli-new; ok "cli app-new"
./portier stats | grep -q '"auths"' || fail cli-stats; ok "cli stats"

echo "ALL $P TESTS PASSED"
