## Ghost E2E CLI Test (Alice/Bob)

This is a **controlled local test** that validates the full encrypted workflow:

connection → auth (`auth_ok`) → X3DH session → encrypt → send → relay route → receive → decrypt → reply → ratchet msg2

No plaintext ever reaches the relay. The relay logs **routing/auth events only**.

---

### Files added

- **Dummy clients**
  - `e:/Messaging_App/client/bin/client_bob.dart`
  - `e:/Messaging_App/client/bin/client_alice.dart`
  - shared helpers: `e:/Messaging_App/client/bin/_e2e/common.dart`
- **Runner**
  - `e:/Messaging_App/client/tool/run_e2e_cli.ps1`

---

### Preconditions

- **Go relay running** locally or deployed, with:
  - `SUPABASE_URL` and `SUPABASE_ANON_KEY` set (relay uses them to verify the signed handshake)
  - `REDIS_URL` set (local defaults OK)
- Supabase tables exist (`users`, `signed_prekeys`, `prekeys`) and allow anon upsert/insert per your RLS configuration.

---

### Run the relay locally

```powershell
cd e:\Messaging_App\server
$env:SUPABASE_URL="https://<project>.supabase.co"
$env:SUPABASE_ANON_KEY="<anon key>"
$env:REDIS_URL="redis://localhost:6379"
go run .\cmd\relay
```

---

### Run the E2E CLI test (Windows PowerShell)

```powershell
cd e:\Messaging_App\client
$env:RELAY_WSS_URL="ws://127.0.0.1:8080/ws"   # or wss://<render>/ws
$env:SUPABASE_URL="https://<project>.supabase.co"
$env:SUPABASE_ANON_KEY="<anon key>"

powershell -ExecutionPolicy Bypass -File tool\run_e2e_cli.ps1
```

Outputs are written to:

- `e:/Messaging_App/client/tool/bob.log` + `bob.err.log`
- `e:/Messaging_App/client/tool/alice.log` + `alice.err.log`

---

### What success looks like

Bob log:

- `[CLIENT] authentication success`
- `[RELAY] received ... from=<alice>`
- `[DECRYPT] plaintext="Hello Bob ..."`
- `[RELAY] sending ... to=<alice>`
- `[DECRYPT] msg2 plaintext="Ratchet step 2 ..."`
- `[OK] roundtrip complete`

Alice log:

- `[CLIENT] authentication success`
- `[SESSION] session established`
- `[RELAY] sending ... to=<bob>`
- `[DECRYPT] reply plaintext="Hi Alice ..."`
- `[RELAY] sending msg2 ...`
- `[OK] alice complete`

Relay log:

- `client connected`
- `auth ok`
- `packet accepted, relaying`
- `[Hub] routing recipient_online=true|false`

---

### Failure modes (what to look for)

- **No `auth_ok`**: relay handshake verify failed (check relay env vars + Supabase public key row)
- **Alice fails on `[SESSION]`**: recipient keys missing / RLS blocked / no unused prekeys
- **Bob receives but decrypt fails**: prekey upload mismatch, wrong msg_type mapping, or store missing keys
- **Msg2 fails**: ratchet/session not persisted within the process (should pass with in-memory store)

---

### Testing with a real existing user ID

After virtual-user pass, you can adapt the clients to use a fixed UID (e.g. `73BfoyivvoJ4jxxgyD2saKMbFPJwT9YCPnKXgCZ6Zgmj`) **only if you also have the private key** locally (the relay never fetches private keys). For safety, keep this harness using ephemeral identities by default.

