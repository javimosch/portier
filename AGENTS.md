# portier — agent notes

OIDC/OAuth SSO broker in machin, metered by peage. The authenticate-third of the
intrane agent-web triad (peage=pay, relais=receive, portier=authenticate).

- Build: `./build.sh`. Test: `./test.sh` (e2e incl. full SSO flow + peage metering/past_due). Keep green.
- Never `parse()` a client body; use `json_get`+defaults. One type per var name per scope.
- Stored JSON columns (codes.identity) must be emitted RAW via a struct parse, never json_get (double-encodes) — same gotcha as relais.
- v1 = OIDC/OAuth only (auth-code flow, trusts IdP token endpoint over TLS — no RSA). SAML needs RSA/XML-DSig: machin#484.
- Security: HMAC-signed expiring state (CSRF), redirect_uri exact-match (open-redirect guard), one-time short-TTL portier codes redeemable only with app secret, identities never in browser URL.
- Billing: 100 free auths then 1 EUR/100 successful auths (blocks; PORTIER_BLOCK/FREE_AUTHS tunable). Best-effort charge, never blocks in-flight login; past_due blocks only NEW initiations. peage merchant m_720571762d72.
- Wallet tokens encrypted at rest (AES-256-GCM via PORTIER_KEK); plaintext tolerated on read for legacy rows, rewritten on next save.
- Deploy: dk1 /opt/portier, env /etc/portier/portier.env (640), systemd :8797, hotify sso.intrane.fr.
