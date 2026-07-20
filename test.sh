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
        self._j({"access_token":"AT_mock","token_type":"bearer"})
    def do_GET(self):   # userinfo
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

curl -sf "$B/_health" | grep -q '"ok":1' || fail health; ok health
curl -sf "$B/llms.txt" | grep -q "one redirect" || fail llms; ok llms.txt
curl -sf "$B/guide" | grep -q '"pay_rail":"peage"' || fail guide; ok guide
curl -sf "$B/guide" | grep -q '"past_due_blocks_new_logins":true' || fail guide-billing; ok "guide documents past_due billing"
curl -sf "$B/guide" | grep -q '"intrane"' || fail guide-intrane; ok "guide lists intrane provider"
curl -sf "$B/" | grep -q portier || fail landing; ok landing

# register app (redirect_uri required)
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$B/v1/apps" -d '{"name":"noredir"}')" = "400" ] || fail need-redir; ok "redirect_uris required"
APP=$(curl -sf -X POST "$B/v1/apps" -d '{"name":"testapp","redirect_uris":"http://127.0.0.1:9999/done,http://127.0.0.1:9999/done2"}')
AID=$(echo "$APP" | J "['app_id']"); SEC=$(echo "$APP" | J "['app_secret']")
[ -n "$SEC" ] || fail app; ok "app registered ($AID)"

# provider: demo (no creds needed)
curl -sf -X POST "$B/v1/apps/provider" -H "Authorization: Bearer $SEC" -d '{"kind":"demo"}' | grep -q '"kind":"demo"' || fail demo-prov; ok "demo provider configured"
# provider: github preset (URLs filled in server-side)
GH=$(curl -sf -X POST "$B/v1/apps/provider" -H "Authorization: Bearer $SEC" -d '{"kind":"github","client_id":"ghcid","client_secret":"ghsec"}')
echo "$GH" | grep -q '/cb/github' || fail gh-cb; ok "github IdP callback URL in response"
GHAUTH=$(sqlite3 "$DB" "SELECT authorize_url FROM providers WHERE app_id='$AID' AND name='github';")
echo "$GHAUTH" | grep -q 'github.com/login/oauth/authorize' || fail gh-preset; ok "github provider preset authorize_url stored"
# provider: google preset (URLs filled in server-side)
curl -sf -X POST "$B/v1/apps/provider" -H "Authorization: Bearer $SEC" -d '{"kind":"google","client_id":"gocid","client_secret":"gosec"}' | grep -q '/cb/google' || fail google-cb; ok "google IdP callback URL in response"
GOAUTH=$(sqlite3 "$DB" "SELECT authorize_url FROM providers WHERE app_id='$AID' AND name='google';")
echo "$GOAUTH" | grep -q 'accounts.google.com/o/oauth2' || fail google-preset; ok "google provider preset authorize_url stored"
# provider: intrane (machin-idp) preset
curl -sf -X POST "$B/v1/apps/provider" -H "Authorization: Bearer $SEC" -d '{"kind":"intrane","client_id":"icid","client_secret":"isec"}' | grep -q '/cb/intrane' || fail intrane-cb; ok "intrane (machin-idp) callback URL in response"
IAUTH=$(sqlite3 "$DB" "SELECT authorize_url FROM providers WHERE app_id='$AID' AND name='intrane';")
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

# --- real OIDC flow through the mock IdP (token + userinfo) ---
LOC2=$(curl -s -o /dev/null -w '%{redirect_url}' "$B/auth/$AID/corp?redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fdone&state=s2")
echo "$LOC2" | grep -q "127.0.0.1:$IDP_PORT/authorize" || fail auth-oidc; ok "/auth (oidc) redirects to the IdP authorize URL"
ST=$(echo "$LOC2" | sed -n 's/.*state=\([^&]*\).*/\1/p')
CB2=$(curl -s -o /dev/null -w '%{redirect_url}' "$B/cb/corp?code=idpcode&state=$ST")
PC2=$(echo "$CB2" | sed -n 's/.*code=\(pc_[a-f0-9]*\).*/\1/p')
ID2=$(curl -sf -X POST "$B/v1/token" -H "Authorization: Bearer $SEC" -d '{"code":"'$PC2'"}')
[ "$(echo "$ID2" | J "['identity']['email']")" = "user@corp.com" ] || fail oidc-flow; ok "generic OIDC flow yields the IdP identity"
[ "$(echo "$ID2" | J "['identity']['sub']")" = "oidc-sub-9" ] || fail oidc-sub; ok "identity sub from userinfo"

# --- security guards ---
# open redirect: unregistered redirect_uri -> 400
[ "$(curl -s -o /dev/null -w '%{http_code}' "$B/auth/$AID/demo?redirect_uri=http%3A%2F%2Fevil.com%2Fx&state=x")" = "400" ] || fail openredir; ok "unregistered redirect_uri blocked (open-redirect guard)"
# tampered state at /cb -> 400
[ "$(curl -s -o /dev/null -w '%{http_code}' "$B/cb/demo?code=x&state=tampered.deadbeef")" = "400" ] || fail statetamper; ok "tampered state rejected"
# code from app A not redeemable by app B
APP2=$(curl -sf -X POST "$B/v1/apps" -d '{"redirect_uris":"http://127.0.0.1:9999/done"}'); SEC2=$(echo "$APP2" | J "['app_secret']")
L=$(curl -s -o /dev/null -w '%{redirect_url}' "$B/auth/$AID/demo?redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fdone&state=z"); CL=$(curl -s -o /dev/null -w '%{redirect_url}' "$L"); PCX=$(echo "$CL" | sed -n 's/.*code=\(pc_[a-f0-9]*\).*/\1/p')
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$B/v1/token" -H "Authorization: Bearer $SEC2" -d '{"code":"'$PCX'"}')" = "403" ] || fail crossapp; ok "code not redeemable by another app"

# --- metering: free tier = 2, wallet set, 3rd+ auths bill in blocks (mock charges 100c) ---
curl -sf -X POST "$B/v1/apps/wallet" -H "Authorization: Bearer $SEC" -d '{"wallet_token":"pw_fundedwallet123"}' | grep -q '"billing_wallet":"set"' || fail wallet; ok "billing wallet set"
# the wallet token is encrypted at rest (not plaintext in the DB)
RAW=$(sqlite3 "$DB" "SELECT wallet_token FROM apps WHERE id='$AID';")
echo "$RAW" | grep -q '^enc:' || fail enc-prefix; ok "wallet_token stored AES-GCM encrypted (enc: prefix)"
echo "$RAW" | grep -q 'pw_fundedwallet123' && fail enc-plaintext; ok "plaintext wallet token not in the DB"
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
sqlite3 "$DB" "UPDATE apps SET billing='past_due', auth_count=0 WHERE id='$AID';"
LOCfree=$(curl -s -o /dev/null -w '%{redirect_url}' "$B/auth/$AID/demo?redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fdone&state=ft")
echo "$LOCfree" | grep -q "/cb/demo" || fail pastdue-free; ok "past_due does not block login while free tier remains"
sqlite3 "$DB" "UPDATE apps SET billing='ok' WHERE id='$AID';"

# --- billing: multi-block catch-up in one callback ---
sqlite3 "$DB" "UPDATE apps SET billing='ok', auth_count=8, blocks_charged=0 WHERE id='$AID';"
oneauth
MEcatch=$(curl -sf "$B/v1/apps/me" -H "Authorization: Bearer $SEC")
[ "$(echo "$MEcatch" | J "['blocks_charged']")" -ge 3 ] || fail multi-catchup; ok "meter_auth catches up multiple owed blocks in one callback"

# --- billing hardening: past_due blocks new logins; wallet top-up clears it ---
sqlite3 "$DB" "UPDATE apps SET billing='past_due', auth_count=5 WHERE id='$AID';"
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
sqlite3 "$DB" "UPDATE apps SET billing='ok', auth_count=3, blocks_charged=0 WHERE id='$AID';"
oneauth
[ "$(curl -sf "$B/v1/apps/me" -H "Authorization: Bearer $SEC" | J "['billing']")" = "past_due" ] || fail decline-pastdue; ok "peage charge decline sets past_due"
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

# --- provider delete ---
curl -sf -X DELETE "$B/v1/apps/provider" -H "Authorization: Bearer $SEC" -d '{"name":"corp"}' | grep -q '"removed":"corp"' || fail prov-del; ok "DELETE /v1/apps/provider removes provider"
[ "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$B/v1/apps/provider" -H "Authorization: Bearer $SEC" -d '{"name":"nope"}')" = "404" ] || fail prov-del-404; ok "DELETE unknown provider -> 404"

# operator CLI
./portier app-new -name ops -redirect https://x/y | grep -q '"ok":true' || fail cli-new; ok "cli app-new"
./portier stats | grep -q '"auths"' || fail cli-stats; ok "cli stats"

echo "ALL $P TESTS PASSED"
