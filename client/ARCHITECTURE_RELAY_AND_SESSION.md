# Relay, persistence, and Signal session flow

This document describes how encrypted 1:1 traffic moves through the Ghost client and where session state lives. File paths are anchored to the `client/` package.

## End-to-end path (receive)

1. **WebSocket** — [`lib/relay/websocket_client.dart`](lib/relay/websocket_client.dart) maintains the relay connection and parses JSON packets.
2. **Coordinator** — [`lib/relay/relay_coordinator.dart`](lib/relay/relay_coordinator.dart) is the single app-wide handler (`_relay.onPacket = _onPacket`). For each sender it ensures a contact row exists, then:
   - **Normal ciphertext** — Inserts a row into SQLCipher via [`SecureDb.insertMessage`](lib/core/storage/secure_db.dart) with `decrypt_pending = 1` so decrypt state is durable across restarts. It buffers the raw packet and notifies [`incomingNotify`](lib/relay/relay_coordinator.dart) for list refresh.
   - **`session_reset`** — No DB row; the packet is only buffered and delivered to the active chat callback so the UI can rebuild the ratchet without treating it as a user message.
3. **Chat UI** — [`lib/features/chat/chat_screen.dart`](lib/features/chat/chat_screen.dart) loads messages from [`SecureDb.getMessages`](lib/core/storage/secure_db.dart), drains pending decrypts with [`_drainPendingDecrypts`](lib/features/chat/chat_screen.dart), and registers [`setCurrentChat`](lib/relay/relay_coordinator.dart) for live packets.

Plaintext exists only in RAM inside [`EphemeralCache`](lib/core/storage/ephemeral_cache.dart) after a successful decrypt; it is cleared on app pause (see lifecycle below).

## Crypto plane

- **Ratchet + encrypt/decrypt** — [`lib/core/crypto/signal_session.dart`](lib/core/crypto/signal_session.dart) (`SignalSessionService`): persists ratchet state under keys like `peerUserId.deviceId` in SQLCipher, keeps a **store-bound** in-memory [`SessionCipher`](https://pub.dev/packages/libsignal_protocol_dart) cache keyed by `identityHashCode(store)` so a new `InMemorySignalProtocolStore` never reuses a cipher from an old store instance.
- **Classification** — [`lib/core/crypto/decrypt_failure.dart`](lib/core/crypto/decrypt_failure.dart) maps exceptions to retry vs permanent failure (`DecryptException`).
- **X3DH rebuild** — [`lib/core/crypto/signal_session_builder.dart`](lib/core/crypto/signal_session_builder.dart) fetches recipient keys from Supabase; used after peer `session_reset` or send-side self-heal.
- **Send-side self-heal** — If encrypt fails, `encryptMessage` clears the local session, rebuilds, and retries. Immediately before rebuild it invokes `onBeforeSessionRebuild`, which the chat wires to [`RelayCoordinator.sendSessionResetIfAllowed`](lib/relay/relay_coordinator.dart) (30s per-peer cooldown) so the other device can align its ratchet.

## Lifecycle

- **Chat dispose** — [`ChatScreen.dispose`](lib/features/chat/chat_screen.dart) calls [`SignalSessionService.evictSession`](lib/core/crypto/signal_session.dart) for that peer so the singleton cache does not reference a disposed screen’s store.
- **App pause / detach** — [`GhostApp.didChangeAppLifecycleState`](lib/main.dart) clears [`EphemeralCache`](lib/core/storage/ephemeral_cache.dart). It evicts **all** cached ciphers with [`evictAllSessions`](lib/core/crypto/signal_session.dart) only when [`SecureDb.hasAnyPendingDecrypt`](lib/core/storage/secure_db.dart) is false, so a backlog of ciphertext rows still marked pending keeps the cache warm until those messages are resolved.

## CLI parity

[`bin/client_sender.dart`](bin/client_sender.dart) mirrors the same ideas for headless testing: rate-limited `session_reset` notifications before local rebuild on send-side heal, handling of inbound `session_reset`, and file-backed session state under `tool/session_<recipient>.json`.

## Bottlenecks and design tradeoffs

- **Ordering** — Pending decrypts are processed in `created_at` order; one successful decrypt may advance the ratchet so [`_drainPendingDecrypts`](lib/features/chat/chat_screen.dart) loops until no progress (Signal’s chain order).
- **Duplicate relay delivery** — Inserts use `ConflictAlgorithm.replace`; successful decrypt clears `decrypt_pending` so replacements remain consistent.
- **Skipping cache eviction when pending** — Slightly higher RAM use while backgrounded if undecrypted messages exist; mitigated by store-identity checks when creating ciphers and by per-chat `evictSession` on navigation.
