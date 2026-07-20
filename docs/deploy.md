# Deploy — dk1

Live at **https://sso.intrane.fr** -> 127.0.0.1:8797 (hotify/Traefik TLS).
- `/opt/portier/portier` (dir owned dk1), `/opt/portier/data.db` (WAL)
- `/etc/portier/portier.env` (640): PORTIER_DB, PORTIER_PUBLIC_URL, PORTIER_SECRET,
  PORTIER_KEK (64-hex AES key for wallet-token encryption at rest),
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
