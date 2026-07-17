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
`authorize_url`/`token_url`/`userinfo_url`), and a **demo** provider for curl-testing the
whole flow. And **[machin-idp](https://github.com/javimosch/machin-idp)** (`idp.intrane.fr`) — the intrane OIDC provider — gives your apps "Login with intrane" through the same broker. **SAML** is on the roadmap — it needs RSA + XML-DSig the pure-MFL runtime
lacks ([machin#484](https://github.com/javimosch/machin/issues/484)).

## Billing (peage)

100 free auths, then 1 EUR per 100 **successful** auths, charged in blocks to the app's
peage wallet (`POST /v1/apps/wallet`). Metering never interrupts an in-flight login; a
depleted wallet only blocks *new* login initiations (the app owner's cue to fund). Set
`PORTIER_FREE_AUTHS` / `PORTIER_BLOCK` to tune.

## Security

Authorization-code flow only; login state is HMAC-signed and expiring (CSRF-safe);
`redirect_uri` must exactly match a registered one (open-redirect guard); the portier
code is one-time, short-lived, and only redeemable with the app secret — identities never
touch the browser URL. v1 trusts the IdP token endpoint over TLS (confidential-client
code flow, no RSA needed).

## Build & run

```sh
./build.sh     # -> ./portier
./test.sh      # 25-assertion e2e (mocked IdP + peage), incl. the full SSO flow + metering
```

Env: `PORTIER_DB` · `PORTIER_PUBLIC_URL` · `PORTIER_SECRET` (state signing) ·
`PORTIER_FREE_AUTHS` (100) · `PORTIER_BLOCK` (100) · `PEAGE_MERCHANT_KEY` · `PEAGE_URL`.

The intrane agent-web triad: **[péage](https://peage.intrane.fr)** (pay) ·
**[relais](https://github.com/javimosch/relais)** (receive) · **portier** (authenticate).
