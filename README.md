# portier — SSO for your app in one redirect

**Add "Login with Google / GitHub / any OIDC provider" without implementing OAuth.**
portier brokers the authorization-code flow and hands your app back a verified identity.
No per-seat SSO tax — **100 free auths, then 1 EUR per 100 successful auths** funded by a
[peage](https://peage.intrane.fr) wallet. One static [machin (MFL)](https://github.com/javimosch/machin) binary.

Live: **https://sso.intrane.fr** · docs for agents: **[/llms.txt](https://sso.intrane.fr/llms.txt)** · JSON: **[/guide](https://sso.intrane.fr/guide)**

## Your app makes two curls

```sh
# 1. register (save the secret — shown once)
curl -s -X POST https://sso.intrane.fr/v1/apps \
  -d '{"name":"my app","redirect_uris":"https://myapp.com/auth/done"}'
# -> {"app_id":"app_…","app_secret":"psk_…"}

# 2. add a provider — try the built-in demo first (no real IdP needed)
curl -s -X POST https://sso.intrane.fr/v1/apps/provider \
  -H 'Authorization: Bearer psk_…' -d '{"kind":"demo"}'
# real GitHub: {"kind":"github","client_id":"…","client_secret":"…"} (callback = https://sso.intrane.fr/cb/github)
# machin-idp: {"kind":"intrane","client_id":"…","client_secret":"…"} (callback = https://sso.intrane.fr/cb/intrane)
```

Then the login flow: send the user's browser to
`https://sso.intrane.fr/auth/<app_id>/<provider>?redirect_uri=<registered>&state=<csrf>`.
portier runs the OAuth dance and redirects back to your `redirect_uri` with `?code=…`.
Your server exchanges it (one curl, one-time code):

```sh
curl -s -X POST https://sso.intrane.fr/v1/token \
  -H 'Authorization: Bearer psk_…' -d '{"code":"pc_…"}'
# -> {"identity":{"sub":"…","email":"…","name":"…","provider":"github"}}
```

## Providers

**github**, **google**, generic **oidc** (Keycloak/Auth0/Okta/GitLab — supply
`authorize_url`/`token_url`/`userinfo_url`), **intrane** (machin-idp preset — same as
`kind:intrane`), and a **demo** provider for curl-testing the
whole flow. And **[machin-idp](https://github.com/javimosch/machin-idp)** (`idp.intrane.fr`) — the intrane OIDC provider — gives your apps "Login with intrane" through the same broker. **SAML** is on the roadmap — it needs RSA + XML-DSig the pure-MFL runtime
lacks ([machin#484](https://github.com/javimosch/machin/issues/484)).

## Billing (peage)

100 free auths, then 1 EUR per 100 **successful** auths, charged in blocks to the app's
peage wallet (`POST /v1/apps/wallet`). Metering never interrupts an in-flight login; a
depleted wallet only blocks *new* login initiations (the app owner's cue to fund). A charge
succeeds only when peage returns HTTP 200 with a non-empty JSON body and `ok:1` (number),
`ok:"1"` (string), or `ok:true` — `ok:0`, `ok:false`, or a missing `ok` field flags `past_due`. Multi-block catch-up stops on the first declined
charge (blocks already billed stay charged); at most 20 blocks are billed per callback.
Set `PORTIER_FREE_AUTHS` / `PORTIER_BLOCK` to tune.

App registration (`POST /v1/apps`) is rate-limited to 10 per hour per client IP.
Wallet tokens must be at least 16 characters (`POST /v1/apps/wallet`).

## Security

Authorization-code flow only; login state is HMAC-signed and expiring (CSRF-safe);
`redirect_uri` must exactly match a registered one (open-redirect guard); the signed
state binds the provider name — the IdP callback path `/cb/<provider>` must match;
IdP error redirects (`?error=…`) are handled without attempting token exchange; token or
userinfo exchange failures return 400 without metering the auth; the
portier code is one-time, short-lived, and only redeemable with the app secret —
identities without a usable `sub` are rejected at `/cb` without metering. v1 trusts the IdP token endpoint over TLS
(confidential-client code flow, no RSA needed).

## Build & run

```sh
./build.sh     # -> ./portier
./test.sh      # e2e (mocked IdP + peage), incl. full SSO flow + metering/past_due
```

Env: `PORTIER_DB` · `PORTIER_PUBLIC_URL` · `PORTIER_SECRET` (state signing) ·
`PORTIER_KEK` (64-hex AES key — encrypts peage wallet tokens at rest) ·
`PORTIER_FREE_AUTHS` (100) · `PORTIER_BLOCK` (100) · `PEAGE_MERCHANT_KEY` · `PEAGE_URL`.

## Feedback

```sh
portier feedback "wallet top-up wasn't reflected for ~30s" -kind bug -context "after POST /v1/apps/wallet"
```

Dual-writes: to portier's own `POST /v1/feedback` (stored locally) **and**, best-effort, to a
central relay so one inbox spans every intrane CLI. Open intake — no token, 16 KB cap,
idempotent on a client-supplied id. `FEEDBACK_RELAY` retargets the relay (`off` disables);
`PORTIER_URL`/`PORTIER_PUBLIC_URL` retarget the app endpoint. Follows the [cli-feedback-spec](https://github.com/javimosch/cli-feedback-spec) convention
(reference relay: [machin-feedback](https://github.com/javimosch/machin-feedback)).

The intrane agent-web triad: **[péage](https://peage.intrane.fr)** (pay) ·
**[relais](https://github.com/javimosch/relais)** (receive) · **portier** (authenticate).
