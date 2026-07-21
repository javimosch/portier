# Deploy — dk1

Live at **https://sso.intrane.fr** -> 127.0.0.1:8797 (hotify/Traefik TLS).
- `/opt/portier/portier` (dir owned dk1), `/opt/portier/data.db` (WAL)
- `/etc/portier/portier.env` (640): PORTIER_DB, PORTIER_PUBLIC_URL, PORTIER_SECRET,
  PORTIER_KEK (64-hex AES key for wallet-token encryption at rest),
  PORTIER_FREE_AUTHS (default 100), PORTIER_BLOCK (auths per billed block, default 100),
  PEAGE_URL, PEAGE_MERCHANT_KEY (peage merchant m_720571762d72)
- systemd `portier.service` :8797

## Update
```sh
./build.sh && ./test.sh
scp portier dk1:/tmp/portier
ssh dk1 'sudo install -m0755 /tmp/portier /opt/portier/portier && sudo systemctl restart portier && sleep 1 && curl -sf 127.0.0.1:8797/_health'
```

Wallet tokens are AES-256-GCM encrypted at rest when `PORTIER_KEK` is set (64 hex chars =
32-byte key). Startup migrates any legacy plaintext rows in place. Backed up: machin-vault
target dk1-portier (db + env) on rbm21, restore drill passed.

## Billing (peage)

Metering runs in the IdP callback after a successful auth — it never interrupts the user
mid-login. `charge_block` POSTs to peage `/v1/charge` with an idempotency key
`app_id:block:N`; only HTTP 200 **and** a non-empty JSON body with `ok:1`, `ok:"1"`, or `ok:true` counts as billed.

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| New logins return 400 "billing wallet is empty" | `billing=past_due` and free tier exhausted | `POST /v1/apps/wallet` with a funded `pw_` token (clears past_due) |
| `blocks_charged` lags `auth_count` after outage | Catch-up bills up to 20 owed blocks per callback | Fund wallet; next successful auth triggers catch-up |
| Charge always past_due | Missing `PEAGE_MERCHANT_KEY` or empty wallet | Set env + app wallet |
| Charge past_due after peage outage | Network error or peage 5xx — only HTTP 200 + `ok:1` bills | Restore peage; fund wallet; wallet POST clears past_due |
| Charge past_due with HTTP 200 | Empty body, malformed JSON, missing `ok`, or `ok:0`/`ok:false` in response | Fix peage integration; inspect stderr `portier charge invalid/empty response` |
| In-flight login still completes when charge fails | By design — past_due blocks only **new** `/auth` | Owner funds wallet before users retry |
| `blocks_charged` stuck mid catch-up | Multi-block catch-up stops on first declined charge; earlier blocks stay billed | Fund wallet; wallet POST clears past_due; next auth retries remaining blocks |
| Catch-up stops before all owed blocks | At most 20 blocks billed per callback (protects IdP redirect latency) | Normal — next successful auth continues catch-up |
| `/cb` returns 400 "IdP exchange" | Token or userinfo call to the IdP failed | Check IdP credentials/endpoints; auth is **not** metered on exchange failure |
| `/cb` returns 400 "user identifier (sub)" | IdP userinfo lacked a usable `sub` | Fix IdP claims/scopes; auth is **not** metered |
| Charge past_due with encrypted wallet | `PORTIER_KEK` missing or wrong — encrypted `wallet_token` cannot be decrypted | Set correct 64-hex `PORTIER_KEK`; fund wallet via POST /v1/apps/wallet |

Tune free tier / block size with `PORTIER_FREE_AUTHS` (default 100) and `PORTIER_BLOCK`
(default 100 auths per 1 EUR block).

## API limits

- `POST /v1/apps` — 10 registrations per hour per client IP (429 when exceeded).
- `POST /v1/apps/wallet` — `wallet_token` must be at least 16 characters.
