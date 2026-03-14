// STRUCTURAL IMPROVEMENTS - Complete Implementation Guide
// ════════════════════════════════════════════════════════════════════════════
// Fixes the remaining architectural risks:
// • Relay authentication (signed handshakes)
// • Signal key lifecycle (upload + rotation)
// • Atomic initialization sequence
// • Supabase schema consistency
// ════════════════════════════════════════════════════════════════════════════

## PHASE 1: DATABASE SETUP (Run Once)
─────────────────────────────────────────────────────────────────────────────

1. Create Supabase project at supabase.com
2. Copy supabase_schema.sql from workspace
3. Open Supabase SQL editor
4. Paste entire schema and execute
   ✓ Creates: users, signed_prekeys, prekeys, contacts, messages, sessions
   ✓ Enables: RLS policies, automatic timestamps, cascade deletes
   ✓ Sets up: Indexes for query performance

Verify in Supabase Console:
  • Tables tab → 6 tables visible
  • RLS indicator shows "enabled" for all tables
  • Run: SELECT COUNT(*) FROM users; → should return 0


## PHASE 2: UPDATE INITIALIZATION (Code Changes)
─────────────────────────────────────────────────────────────────────────────

Update onboarding_screen.dart to use AppInitializationService:

  import '../../core/initialization/app_initialization_service.dart';

  class _OnboardingScreenState extends State<OnboardingScreen> {
    final _initService = AppInitializationService();

    Future<void> _initialize() async {
      // Let initialization service handle everything
      final success = await _initService.initialize();
      
      if (!success) {
        // Show error screen
        setState(() { _error = 'Initialization failed'; });
        return;
      }

      // Navigate to next screen
      Navigator.of(context).pushReplacementNamed('/contacts');
    }
  }

This ensures atomic initialization:
  1. Load or generate identity keys
  2. Load or generate Signal keys
  3. Upload public keys to Supabase
  4. Connect to relay with signed handshake
  5. Begin normal operation


## PHASE 3: RELAY AUTHENTICATION
─────────────────────────────────────────────────────────────────────────────

Your relay server must validate the signed handshake before accepting connection.

Add to relay server (Node.js example):

  const RelayAuthService = require('./relay_auth_service');
  const ws = require('ws');

  wss.on('connection', (ws, req) => {
    const uid = new URL(req.url, 'http://relay').searchParams.get('uid');
    
    // Wait for auth message from client
    ws.once('message', async (msg) => {
      try {
        const auth = JSON.parse(msg);
        const publicKey = await db.getPublicKey(uid);
        
        if (!RelayAuthService.verifyHandshake(auth, publicKey)) {
          ws.close(4003, 'Invalid signature');
          return;
        }
        
        // Authenticated! Accept connection
        ws.isAuthenticated = true;
        console.log(`[Relay] Authenticated: ${uid}`);
      } catch (e) {
        ws.close(4003, 'Auth failed');
      }
    });

    // After auth timeout, disconnect
    setTimeout(() => {
      if (!ws.isAuthenticated) {
        ws.close(4003, 'Auth timeout');
      }
    }, 5000);
  });


## PHASE 4: RUNTIME KEY ROTATION
─────────────────────────────────────────────────────────────────────────────

Add to app initialization or periodic background task:

  // Check prekey count every day
  Timer.periodic(Duration(hours: 24), (timer) async {
    final userId = await identityService.getUserId();
    final shouldRefill = await keysUploadService.shouldRefillPrekeys(
      userId: userId,
    );
    
    if (shouldRefill) {
      // Generate 50 new one-time prekeys
      final newPreKeys = await generateOneTimePreKeys(50);
      await keysUploadService.uploadOneTimePreKeys(
        userId: userId,
        preKeys: newPreKeys,
      );
      print('[KeyRotation] Refilled prekeys');
    }
  });


## PHASE 5: SESSION ESTABLISHMENT FLOW
─────────────────────────────────────────────────────────────────────────────

When user adds contact:

  1. User scans QR → gets recipient's uid + public_key
  2. App queries: SELECT * FROM users WHERE user_id = recipient_uid
  3. App verifies fingerprint (optional but recommended)
  4. App calls SignalSessionBuilder.buildSession(recipientUserId)
     ↓ Fetches recipient's signed prekey from Supabase
     ↓ Creates X3DH session
     ↓ Stores session locally
  5. Ready to send encrypted messages


## PHASE 6: MESSAGE ENCRYPTION FLOW
─────────────────────────────────────────────────────────────────────────────

When user sends message:

  1. Get or create session: SessionCipher = sessionService.getOrCreateSession()
  2. Encrypt: ciphertext = await sessionCipher.encrypt(plaintext)
  3. Build relay packet:
     {
       type: "message",
       from: myUserId,
       to: recipientUserId,
       payload: base64(ciphertext),
       msg_type: ciphertext.type (1 or 2),
       message_id: uuid.v4(),
       ttl_seconds: 86400
     }
  4. Send to relay: relayClient.sendPacket(packet)
  5. Relay forwards to recipient


## PHASE 7: MESSAGE DECRYPTION FLOW
─────────────────────────────────────────────────────────────────────────────

When relay sends message:

  1. Receive from relay:
     {
       from: senderUserId,
       payload: base64(ciphertext),
       msg_type: 1 or 2
     }
  2. Get session: SessionCipher = sessionService.getOrCreateSession(senderId)
  3. Decrypt based on type:
     - Type 1 (PreKey): decryptWithCallback(PreKeySignalMessage)
     - Type 2 (Signal): decryptFromSignal(SignalMessage)
  4. Extract plaintext
  5. Save to local database


## MIGRATION CHECKLIST
─────────────────────────────────────────────────────────────────────────────

✓ Database schema created in Supabase
✓ RLS policies enabled
✓ relay_auth_service.dart reviewed
✓ signal_keys_upload_service.dart integrated
✓ app_initialization_service.dart used in onboarding
✓ signal_session_builder.dart replaces old session code
✓ Relay server validates signed handshakes
✓ Key rotation background task added
✓ Message format standardized across app
✓ Error handling for missing/expired prekeys


## TESTING SEQUENCE
─────────────────────────────────────────────────────────────────────────────

Test 1: Key Generation & Upload
  • Onboard: app generates keys
  • Check Supabase console → users table → identity_key populated
  • Check signed_prekeys table → key_id=1 visible
  • Check prekeys table → 50+ prekeys visible

Test 2: Relay Authentication
  • Open app
  • Monitor relay logs: [Relay] Authenticated: <uid>
  • WebSocket should stay connected
  • Not connected? Check relay_auth_service logs

Test 3: Session Establishment
  • Add contact by scanning QR
  • Monitor logs: [SignalSessionBuilder] Session created
  • Should see NO "Invalid signature" errors
  • Session should cache for fast access

Test 4: Message Send/Receive
  • Send text message
  • Check relay logs: message received + forwarded
  • Recipient should receive decrypted text
  • Repeat multiple times (tests ratcheting)

Test 5: Key Rotation
  • Monitor Supabase prekeys table
  • Wait for background task (or trigger manually)
  • New prekeys should appear
  • used_at should mark consumed keys


## TROUBLESHOOTING
─────────────────────────────────────────────────────────────────────────────

Problem: "Recipient keys not found"
  Solution: Check Supabase users table → recipient exists?

Problem: "Invalid signature on device key"
  Solution: Verify prekey was signed with identity private key
  Debug: In signal_key_service.dart, logs should show signing order

Problem: "Handshake verification failed"
  Solution: Timestamp tolerance is 5 minutes
  Check: Device clock is correct
  Check: Relay server clock is correct

Problem: "RLS policy violation"
  Solution: Verify user is authenticated to Supabase
  Check: Auth token in headers

Problem: Messages not arriving
  Solution: Check relay is forwarding
  Debug: Add logs in relay message handler
  Check: Recipient uid in relay forwarding logic


## PERFORMANCE CONSIDERATIONS
─────────────────────────────────────────────────────────────────────────────

Key Count Management:
  • Generate 50+ one-time prekeys at startup
  • Refill when count < 10
  • Consume 1 per new session
  • Query uses: WHERE user_id=? AND used_at IS NULL LIMIT 1

Database Indexes:
  • users(user_id) - covered
  • signed_prekeys(user_id, key_id) - compound
  • prekeys(user_id, used_at) - for refill checks
  • messages(to_user_id, delivered_at) - for inbox

Message Cleanup:
  • Messages expire after ttl_seconds (default 24h)
  • Run: DELETE FROM messages WHERE created_at < NOW() - (ttl_seconds || ' seconds')::INTERVAL
  • Schedule as: pg_cron job in Supabase


## SECURITY NOTES
─────────────────────────────────────────────────────────────────────────────

• Identity keys: NEVER shared, kept in device secure enclave
• Signed prekeys: Public, signed with identity private key
• One-time prekeys: Public, consumed after use
• Sessions: Cached in memory, cleared on app background
• Messages: Encrypted end-to-end before relay sees them
• Relay: Sees only metadata (uid, timestamp, message id)
• RLS: Prevents cross-user data access at database level


════════════════════════════════════════════════════════════════════════════
Deployment ready. Execute Phase 1-2 first, then test Phase 7.
════════════════════════════════════════════════════════════════════════════

