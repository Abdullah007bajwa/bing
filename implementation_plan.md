# Military-Grade E2E Encrypted Messaging App — Implementation Plan

A zero-knowledge, privacy-first mobile messaging platform engineered to NSA Suite B / FIPS 140-3 principles. No phone, no email, no plaintext — anywhere. Built for the threat model of nation-state adversaries, law enforcement coercion, and device seizure scenarios.

---

## User Review Required

> [!IMPORTANT]
> **This plan builds two separate codebases** under `e:\Messaging_App`:
> - `client/` — Flutter cross-platform mobile app
> - `server/` — Go relay server (deployable to Render)
>
> All crypto is done client-side. The server is a **blind relay** — it never sees plaintext.

> [!WARNING]
> **libsignal-client FFI**: The official Signal Protocol Dart bindings (`libsignal-client`) require compiled native `.so`/`.dylib` binaries. The plan includes pre-build steps using the Signal `build.sh` targets. This requires Rust toolchain on the build machine.

> [!CAUTION]
> **Panic-Wipe is destructive by design.** Once triggered, all local keys, messages, contacts, and the encrypted DB are permanently deleted. There is no recovery. We will include a confirmation UX gate.

---

## Proposed Changes

### Component 1: Project Structure

```
e:\Messaging_App\
├── client\               # Flutter app
│   ├── android\
│   ├── ios\
│   ├── lib\
│   │   ├── core\         # Crypto, identity, storage engines
│   │   ├── features\     # Onboarding, contacts, chat, groups, settings
│   │   ├── relay\        # WebSocket client
│   │   ├── models\       # Message, Contact, Group data models
│   │   └── main.dart
│   ├── pubspec.yaml
│   └── test\
├── server\               # Go relay server
│   ├── cmd\relay\main.go
│   ├── internal\
│   │   ├── ws\           # WebSocket hub
│   │   ├── redis\        # TTL store
│   │   ├── model\        # Packet model (no plaintext fields)
│   │   └── api\          # REST for key lookup (reads Supabase)
│   ├── go.mod
│   └── Dockerfile
├── supabase\             # Supabase SQL migrations
│   └── migrations\
└── README.md
```

---

### Component 2: Flutter Client — Core [`client/`]

#### [NEW] [client/pubspec.yaml](file:///e:/Messaging_App/client/pubspec.yaml)
Key dependencies:
| Package | Purpose |
|---|---|
| `libsignal_protocol_dart` | Signal Double Ratchet, X3DH key agreement |
| `flutter_secure_storage` | Android Keystore / iOS Secure Enclave |
| `sqflite_cipher` (SQLCipher) | Encrypted local DB |
| `qr_flutter` / `mobile_scanner` | QR code gen + scan |
| `web_socket_channel` | WebSocket relay connection |
| `supabase_flutter` | Public key lookup |
| `crypto` / `pointycastle` | SHA-256 user_id derivation, HKDF |
| `local_auth` | Biometric app-lock |
| `flutter_windowmanager` | FLAG_SECURE (screenshot block, Android) |
| `image_picker` | View-once media selection |

---

#### [NEW] [client/lib/core/identity/identity_service.dart](file:///e:/Messaging_App/client/lib/core/identity/identity_service.dart)
- [generateIdentityKeyPair()](file:///e:/Messaging_App/client/lib/core/identity/identity_service.dart#38-46) — creates [IdentityKeyPair](file:///e:/Messaging_App/client/lib/core/identity/identity_service.dart#48-62) via libsignal
- [deriveUserId(IdentityKey pubKey) → String](file:///e:/Messaging_App/client/lib/core/identity/identity_service.dart#64-69) — [base58(SHA-256(pubKey.serialize()))](file:///e:/Messaging_App/client/lib/core/identity/identity_service.dart#136-158)
- `storePrivateKey(ECPrivateKey key)` — writes to `flutter_secure_storage`; key never leaves device storage
- [loadIdentityKeyPair()](file:///e:/Messaging_App/client/lib/core/identity/identity_service.dart#48-62) — reads from secure storage; returns null if not initialized
- [uploadPublicKey(String userId, String pubKeyB64)](file:///e:/Messaging_App/client/lib/core/identity/identity_service.dart#99-118) — POST to Supabase `users` table

#### [NEW] [client/lib/core/crypto/signal_session.dart](file:///e:/Messaging_App/client/lib/core/crypto/signal_session.dart)
- `initializeSession(ContactPublicKey)` — X3DH key agreement; stores session state in SQLCipher
- [encryptMessage(String plaintext, SessionState) → CiphertextMessage](file:///e:/Messaging_App/client/lib/core/crypto/signal_session.dart#48-60)
- [decryptMessage(CiphertextMessage, SessionState) → String](file:///e:/Messaging_App/client/lib/core/crypto/signal_session.dart#62-82)
- `rotateSession()` — manual ratchet advance for panic scenarios

#### [NEW] [client/lib/core/storage/secure_db.dart](file:///e:/Messaging_App/client/lib/core/storage/secure_db.dart)
- Opens SQLCipher DB with 256-bit random key stored in `flutter_secure_storage`
- Tables: `messages`, `contacts`, `group_keys`, `session_states`
- [wipeDatabase()](file:///e:/Messaging_App/client/lib/core/storage/secure_db.dart#238-268) — secure overwrite + delete of DB file (panic-wipe)

#### [NEW] [client/lib/core/storage/ephemeral_cache.dart](file:///e:/Messaging_App/client/lib/core/storage/ephemeral_cache.dart)
- In-memory LRU cache for decrypted message content
- Auto-cleared on app foreground → background transition
- RAM-only media buffer for view-once images/videos

---

#### [NEW] `client/lib/features/onboarding/`
- `onboarding_screen.dart` — animated splash; triggers `IdentityService.generateIdentityKeyPair()` on first launch
- `identity_card_screen.dart` — displays public ID (text) + QR code + copy/share buttons
- `nickname_screen.dart` — optional local nickname (stored in SQLCipher, never synced)
- `panic_setup_screen.dart` — set 4–8 digit panic code; stored as PBKDF2 hash locally

#### [NEW] `client/lib/features/contacts/`
- `contact_service.dart` — add/remove/verify contacts; all stored in SQLCipher
- `qr_scanner_screen.dart` — scan another user's QR → extract public key → initiate X3DH session
- `add_by_id_screen.dart` — paste public ID string → lookup Supabase → fetch public key → verify fingerprint
- `fingerprint_screen.dart` — display / compare safety numbers (SHA-256 of both public keys, formatted as blocks)
- `invite_link.dart` — generates `ghost://add/<user_id>` deep links

#### [NEW] `client/lib/features/chat/`
- `chat_screen.dart` — message list + compose bar; messages rendered from SQLCipher with ephemeral status
- `chat_bloc.dart` — BLoC for state management; handles encrypt → send → receive → decrypt → delete lifecycle
- `message_bubble.dart` — renders encrypted message text; shows "Tap to view" for view-once
- `ephemeral_timer.dart` — countdown widget; deletes message from DB when TTL reaches zero
- `media_viewer.dart` — loads view-once media into RAM; clears buffer after close; no disk write
- `websocket_client.dart` — persistent WebSocket to Render relay; reconnect with exponential backoff; sends `{to, ciphertext, ttl}` JSON

#### [NEW] `client/lib/features/groups/`
- `group_service.dart` — client-side group key generation (AES-256-GCM, Megolm-inspired)
- `group_key_manager.dart` — rotates group session key on member add/remove
- `group_invite.dart` — encrypts group key for each member individually (per recipient X3DH session)
- `group_chat_screen.dart` — same as 1:1 chat but decrypts with group session key

#### [NEW] `client/lib/features/settings/`
- `security_settings_screen.dart` — screenshot block toggle, ephemeral timer config, biometric lock
- `panic_wipe_screen.dart` — enter panic code → `secure_db.wipeDatabase()` + `identity_service.deleteAllKeys()` + `ephemeral_cache.clear()` + navigate to blank state

---

### Component 3: Go Relay Server [`server/`]

#### [NEW] `server/cmd/relay/main.go`
Entry point. Starts:
- WebSocket hub goroutine
- Redis TTL cleanup ticker (every 30s)
- HTTP REST API for health check + key lookup proxy

#### [NEW] `server/internal/ws/hub.go`
```go
type Client struct {
    ID   string          // user_id (hash of pubkey) — NO plaintext identity
    Conn *websocket.Conn
    Send chan []byte
}
type Hub struct {
    Clients    map[string]*Client
    Register   chan *Client
    Unregister chan *Client
    Relay      chan *Packet
}
```
- Never logs message content
- Packet structure: `{ to: string, ciphertext: base64, ttl_seconds: int }`
- If recipient offline: store encrypted packet in Redis with TTL
- If recipient online: relay directly via WebSocket

#### [NEW] `server/internal/redis/store.go`
- `StorePacket(to, ciphertext string, ttl time.Duration)` — `SETEX ghost:msg:<uuid> <ttl> <ciphertext>`
- `FetchPending(userID string) []Packet` — SCAN + GET all `ghost:msg:<userID>:*`
- `DeletePacket(key string)` — immediate delete after delivery
- No persistent logs; Redis configured with `appendonly no`, `maxmemory-policy allkeys-lru`

#### [NEW] `server/internal/model/packet.go`
```go
type Packet struct {
    To         string `json:"to"`           // recipient user_id
    Ciphertext string `json:"ciphertext"`   // base64 Signal ciphertext
    TTL        int    `json:"ttl_seconds"`  // max 86400 (24h), default 3600 (1h)
    MsgType    string `json:"msg_type"`     // "1to1" | "group" | "key_exchange"
}
// NO: sender IP, sender ID, timestamp, message size — nothing metadata
```

#### [NEW] `server/Dockerfile`
- Multi-stage Go build → minimal `distroless/static` image
- No shell, no package manager in production image

#### [NEW] `server/render.yaml`
Render deployment config:
```yaml
services:
  - type: web
    name: ghost-relay
    env: go
    buildCommand: go build -o relay ./cmd/relay
    startCommand: ./relay
    envVars:
      - key: REDIS_URL
        fromService: type=redis
      - key: SUPABASE_URL
        sync: false
      - key: SUPABASE_ANON_KEY
        sync: false
```

---

### Component 4: Supabase Schema [`supabase/migrations/`]

#### [NEW] `supabase/migrations/001_users.sql`
```sql
-- Public key registry — NO PII stored here
CREATE TABLE users (
    user_id     TEXT PRIMARY KEY,       -- SHA-256(public_key), base58
    public_key  TEXT NOT NULL,          -- base64 encoded identity public key
    created_at  TIMESTAMPTZ DEFAULT now(),
    last_seen   TIMESTAMPTZ             -- updated on WebSocket connect; ephemeral
);

-- Row-Level Security: any client can read public keys, only insert their own
ALTER TABLE users ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Public key read" ON users FOR SELECT USING (true);
CREATE POLICY "Self insert only" ON users FOR INSERT
    WITH CHECK (user_id = current_setting('request.jwt.claims', true)::json->>'sub');

-- Auto-delete stale accounts (90 days inactive)
CREATE OR REPLACE FUNCTION delete_stale_users() RETURNS void AS $$
    DELETE FROM users WHERE last_seen < now() - INTERVAL '90 days';
$$ LANGUAGE sql;
```

---

### Component 5: Security Architecture Deep-Dive

| Layer | Mechanism | Standard |
|---|---|---|
| Message encryption | Signal Double Ratchet + X3DH | NIST SP 800-56A |
| Symmetric cipher | AES-256-GCM (via Signal) | FIPS 140-3 |
| Key derivation | HKDF-SHA-512 | RFC 5869 |
| Key storage | Android Keystore (TEE) / iOS Secure Enclave | FIPS 140-2 L3 hw |
| Local DB encryption | SQLCipher (AES-256-CBC) | FIPS 197 |
| Transport | WSS (TLS 1.3) | RFC 8446 |
| Identity | X25519 / Ed25519 keypair | NIST SP 800-186 |
| Group encryption | AES-256-GCM with per-group key | Custom Megolm-inspired |
| Panic wipe | DoD 5220.22-M overwrite + key deletion | DoD STD |

**Forward Secrecy**: The Double Ratchet advances the sending/receiving chain keys after every message. Even if long-term keys are compromised, past messages remain secure.

**Break-in Recovery**: After a session is compromised, new DH ratchet steps generate fresh key material that a passive attacker cannot derive.

---

### Component 6: Network Privacy Layer (Anti-Metadata)

To defend against nation-state traffic analysis and social graph reconstruction, the following layers will be implemented (Phases 4–6):

#### Relay Hardening & Push Privacy
- **Rate Limiting**: Restrict connections to 100 packets/min per user identifier.
- **Packet Size Caps**: Hard limit of 64KB per payload to prevent exhaustion.
- **Replay Protection**: Packets will assert a random 128-bit nonce tracked via Redis `SETNX` for the TTL duration to drop duplicated packets.
- **Encrypted Push Notifications**: Wake-up signals sent via APNS/FCM parsing only an opaque `{ "type": "wakeup", "bucket": "<id>" }` payload to trigger the Flutter app to connect and fetch background data.

#### Onion Routing (Multi-Hop)
- **Nested Encryption Layer**: The message payload will be wrapped in multiple layers of symmetric encryption (`E3(E2(E1(msg)))`).
- **Blind Relays**: Each relay node in the chain will only possess the decryption key for its specific layer to unwrap routing instructions for the next hop. No single relay will know both the initial sender's IP and the final recipient's ID.

#### Sealed Sender
- **Sender Identity Hiding**: The client obscures the sender ID before reaching the relay. The relay authenticates the packet via a delivery token or ephemeral proxy ticket but cannot ascertain who authored the packet. Only the receiving client can cryptographically open the "seal" to reveal the sender's identity.

#### Contact Discovery & Obfuscation
- **Hash-based Lookups**: Supabase queries for contacts will transition from `GET /users/{id}` to `GET /lookup/{hash(id)}`. Directory enumeration becomes computationally intractable.
- **Traffic Padding**: The client will asynchronously emit dummy packets of fixed sizes to randomized relays, preventing ISPs from distinguishing meaningful messaging traffic from heartbeat noise.

---

## Verification Plan

### Automated Tests

#### 1. Flutter Unit Tests — Crypto Layer
```powershell
cd e:\Messaging_App\client
flutter test test/core/crypto/
```
Tests:
- `encrypt_decrypt_roundtrip_test.dart` — encrypt msg → decrypt → assert plaintext match
- `ephemeral_delete_test.dart` — verify message deleted from SQLCipher after TTL
- `identity_derivation_test.dart` — verify `user_id = base58(SHA-256(pubKey))`
- `session_state_persistence_test.dart` — re-open DB, assert session state survives

#### 2. Go Relay Server Unit Tests
```powershell
cd e:\Messaging_App\server
go test ./...
```
Tests:
- `hub_test.go` — register client, relay packet, assert delivery
- `redis_store_test.go` — store packet, fetch, assert TTL expiry with mocked Redis
- `packet_model_test.go` — assert no plaintext / metadata fields in packet struct

#### 3. Integration Test — End-to-End Relay
```powershell
cd e:\Messaging_App\server
go run ./cmd/relay &
go test ./integration/... -v
```
- Two mock WebSocket clients (Alice, Bob) connect to relay
- Alice sends encrypted packet to Bob
- Assert Bob receives exact ciphertext (server did not modify it)
- Assert nothing was written to Redis after delivery (online delivery path)

#### 4. Flutter Integration Tests
```powershell
cd e:\Messaging_App\client
flutter test integration_test/
```
- `onboarding_flow_test.dart` — simulate first launch, assert keypair generated and stored
- `contact_add_test.dart` — add contact by QR data, assert fingerprint screen renders

### Manual Verification
1. **Install on physical Android device** via `flutter run --release`
2. **Open two devices** (or emulator + device), complete onboarding on both
3. **Add contact** via QR scan — verify fingerprint matches on both sides
4. **Send a message** — verify it appears on recipient, is encrypted in transit (Wireshark on relay port)
5. **Wait for TTL** — verify message disappears from both devices after TTL expires
6. **Screenshot test** — attempt screenshot; verify Android blocks it (black screen)
7. **Panic-wipe** — enter panic code; verify app is blank / all data gone on restart
8. **View-once media** — send image as view-once; verify not saveable, disappears after close
