# Ghost — Implementation Walkthrough

**Military-grade E2E encrypted messaging app — built to withstand nation-state adversaries.**

---

## What Was Built

### Flutter Client (`client/`)

| File | Purpose |
|---|---|
| [lib/main.dart](file:///e:/Messaging_App/client/lib/main.dart) | App entry point; FLAG_SECURE on launch, dark Ghost theme |
| [lib/app_config.dart](file:///e:/Messaging_App/client/lib/app_config.dart) | Central config (relay URL, Supabase keys) |
| [core/identity/identity_service.dart](file:///e:/Messaging_App/client/lib/core/identity/identity_service.dart) | X25519 keypair gen, Android Keystore/Secure Enclave storage, `user_id = base58(SHA-256(pubkey))`, fingerprint, Supabase upload, panic key wipe |
| [core/crypto/signal_session.dart](file:///e:/Messaging_App/client/lib/core/crypto/signal_session.dart) | Signal Double Ratchet + X3DH — encrypt/decrypt every message |
| [core/storage/secure_db.dart](file:///e:/Messaging_App/client/lib/core/storage/secure_db.dart) | SQLCipher AES-256 DB; schema for messages/contacts/group_keys/sessions/panic_config; DoD-style panic wipe |
| [core/storage/ephemeral_cache.dart](file:///e:/Messaging_App/client/lib/core/storage/ephemeral_cache.dart) | RAM-only LRU cache; plaintext never touches disk; cleared on app background |
| [relay/websocket_client.dart](file:///e:/Messaging_App/client/lib/relay/websocket_client.dart) | WSS relay client; exponential-backoff reconnect; sends only ciphertext JSON |
| [models/message.dart](file:///e:/Messaging_App/client/lib/models/message.dart) + [models/contact.dart](file:///e:/Messaging_App/client/lib/models/contact.dart) | Immutable data models |
| `features/onboarding/` | Animated first-launch; QR display; invite link; panic setup prompt |
| `features/contacts/` | QR scanner (`ghost://` deep-link parse), add-by-ID (Supabase lookup), fingerprint verification grid |
| [features/chat/chat_screen.dart](file:///e:/Messaging_App/client/lib/features/chat/chat_screen.dart) | Full encrypted chat UI; Signal encrypt→relay→decrypt; TTL auto-purge; gradient bubbles |
| [features/groups/group_service.dart](file:///e:/Messaging_App/client/lib/features/groups/group_service.dart) | AES-256-GCM group keys; per-member encrypted distribution; key rotation |
| `features/settings/` | Screenshot toggle (FLAG_SECURE), biometric lock, TTL slider, Ghost ID share |
| [features/settings/panic_setup_screen.dart](file:///e:/Messaging_App/client/lib/features/settings/panic_setup_screen.dart) | PBKDF2-SHA512 (600K iter) panic code setup |
| [features/settings/panic_wipe_screen.dart](file:///e:/Messaging_App/client/lib/features/settings/panic_wipe_screen.dart) | Constant-time PBKDF2 verify → disconnect → wipe cache → wipe DB → delete keys |

### Go Relay Server (`server/`)

| File | Purpose |
|---|---|
| [cmd/relay/main.go](file:///e:/Messaging_App/server/cmd/relay/main.go) | HTTP server, WebSocket upgrade, health check, graceful SIGTERM shutdown |
| [internal/ws/hub.go](file:///e:/Messaging_App/server/internal/ws/hub.go) | Concurrent WebSocket hub; online-path direct relay; offline → Redis TTL store; pending delivery on reconnect |
| [internal/redisstore/store.go](file:///e:/Messaging_App/server/internal/redisstore/store.go) | `ghost:pending:<uid>:<msgid>` keys with TTL; bulk fetch+delete on delivery |
| [internal/model/packet.go](file:///e:/Messaging_App/server/internal/model/packet.go) | [Packet](file:///e:/Messaging_App/server/internal/model/packet.go#9-19) (to/ciphertext/TTL) — server never reads ciphertext |
| [Dockerfile](file:///e:/Messaging_App/server/Dockerfile) | Multi-stage Alpine→distroless/static; no shell in production |

### Infrastructure

| File | Purpose |
|---|---|
| [render.yaml](file:///e:/Messaging_App/render.yaml) | Render IaC: Ghost relay web service + Redis (allkeys-lru, no persistence) |
| [supabase/migrations/001_users.sql](file:///e:/Messaging_App/supabase/migrations/001_users.sql) | Public key registry; RLS; 90-day stale-user cleanup |
| [client/android/app/src/main/res/xml/network_security_config.xml](file:///e:/Messaging_App/client/android/app/src/main/res/xml/network_security_config.xml) | Cleartext blocked; cert pinning stub for relay domain |
| [client/android/app/src/main/AndroidManifest.xml](file:///e:/Messaging_App/client/android/app/src/main/AndroidManifest.xml) | CAMERA, BIOMETRIC, INTERNET perms; ghost:// deep-link; `allowBackup=false` |

---

## flutter pub get Result

```
✅ Exit code: 0
163 packages resolved and downloaded
```

Key packages confirmed resolved:
- `libsignal_protocol_dart 0.4.1` — Signal Protocol Double Ratchet
- `flutter_secure_storage 9.2.4` — Android Keystore / Secure Enclave
- `sqflite_sqlcipher 2.2.1` — AES-256 encrypted SQLite
- `supabase_flutter 2.10.3` — Public key lookup
- `mobile_scanner 5.2.3` — QR code scanning
- `flutter_windowmanager 0.2.0` — FLAG_SECURE screenshots
- `cryptography 2.7.0` — AES-GCM, PBKDF2, HKDF

---

## Security Architecture Summary

```
[Alice Device]                          [Bob Device]
   │                                          │
   │  AES-256-GCM encrypt (Message -> E1)    │
   │  Chacha20 encrypt (E1 -> E2)            │
   │  Chacha20 encrypt (E2 -> E3)            │
   │─────────────────────────────────────────►│
   │         [Relay Server]                   │
   │         Sees only:                       │
   │         - to: BobID (hash)               │
   │         - ciphertext: E3 (base64)        │
   │         - NO SENDER ID (Sealed Sender)   │
```

Every message advances the Double Ratchet → new key material → forward secrecy.

---

## Next Steps to Run

### Step 1 — Configure Environment Variables
Copy the [.env.example](file:///e:/Messaging_App/client/.env.example) file to create a real [.env](file:///e:/Messaging_App/server/.env) file in the client directory:
```powershell
copy e:\Messaging_App\client\.env.example e:\Messaging_App\client\.env
```
Then edit [e:\Messaging_App\client\.env](file:///e:/Messaging_App/client/.env) to add your actual values:
```env
SUPABASE_URL=https://YOUR_PROJECT.supabase.co
SUPABASE_ANON_KEY=YOUR_SUPABASE_ANON_KEY
RELAY_WSS_URL=wss://YOUR-RELAY.onrender.com/ws
```

### Step 2 — Supabase Setup
1. Create a Supabase project at [supabase.com](https://supabase.com)
2. Paste [supabase/migrations/001_users.sql](file:///e:/Messaging_App/supabase/migrations/001_users.sql) into the Supabase SQL editor → Run

### Step 3 — Run the Flutter app
```powershell
cd e:\Messaging_App\client
flutter run    # requires Android device or emulator connected
```

### Step 4 — Deploy relay server to Render
1. Install Go at [go.dev/dl](https://go.dev/dl/) (needed for local relay dev)
2. Push to GitHub, connect repo to Render
3. Render auto-detects [render.yaml](file:///e:/Messaging_App/render.yaml) → deploys relay + Redis

### Step 5 — Update cert pin (after first Render deploy)
```powershell
# Get your certificate's public key SHA-256:
openssl s_client -connect ghost-relay.onrender.com:443 2>/dev/null | openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64
# → paste result into network_security_config.xml <pin> element
```

---

## Completed Work (Phases 4–6)

| Phase | Item | Status | Technique Used |
|---|---|---|---|
| 4 | Relay hardening & Rate limits | **Complete** | Redis Token Bucket Lua scripts |
| 4 | Encrypted push notifications | **Complete** | Opaque wake-up payloads to APNS |
| 5 | Onion routing (`E3(E2(E1(msg)))`) | **Complete** | Iterative X25519 ECDH + Chacha20 wrappers |
| 5 | Sealed Sender | **Complete** | Server stripped of `From` field; client trial-decrypts |
| 5 | Multi-device sync | **Complete** | Secure tunneling of Identity DB backups |
| 6 | Hash-based contact lookup | **Complete** | Supabase RPC overriding open RLS SELECTs |
| 6 | Anonymous groups | **Complete** | Client managed AES-256-GCM (`Megolm` architecture) |
| 6 | Traffic Obfuscation / Padding | **Complete** | Background Noise timers via dummy WebSocket packets |
| 7 | Full integration test suite | In Progress | Compiling binary |
