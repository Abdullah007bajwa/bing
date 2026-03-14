// COMPLETE IMPLEMENTATION GUIDE
// Ghost Messaging App - Full Integration Checklist
// ════════════════════════════════════════════════════════════════════════════

## QUICK START (30 minutes)
─────────────────────────────────────────────────────────────────────────────

### Step 1: Supabase Setup (5 minutes)
  1. Go to supabase.com → Create new project
  2. Copy Project URL + Anon Key to app_config.dart
  3. In Supabase Console → SQL Editor
  4. Paste supabase_schema.sql → Execute
  5. Verify: 6 tables visible in Table Editor
  6. Check: RLS enabled (lock icon on each table)

### Step 2: Update Identity Service (5 minutes)
  No changes needed - already correct

### Step 3: Update App Initialization (5 minutes)
  Update lib/auth_gate.dart or main app init:

  final initService = AppInitializationService();
  final success = await initService.initialize();

  initService.stepStream.listen((step) {
    debugPrint('Initialization: $step');
  });

### Step 4: Update Contact Establishment (5 minutes)
  In contact_establishment_service.dart:

  // OLD:
  await signalSessionService.getOrCreateSession(...)

  // NEW:
  final sessionBuilder = SignalSessionBuilder(
    store: signalStore,
    keysService: SignalKeysUploadService(),
  );
  final cipher = await sessionBuilder.buildSession(
    recipientUserId: contactId,
    deviceId: 1,
  );

### Step 5: Start Prekey Rotation (2 minutes)
  In main.dart or app init:

  final prekeyService = PrekeyManagementService();
  prekeyService.startAutoRotation(userId: userId);

### Step 6: Update Relay Connection (3 minutes)
  No changes needed - already handles wss:// correctly

Done! Run: flutter clean && flutter pub get && flutter run


## DETAILED INTEGRATION
─────────────────────────────────────────────────────────────────────────────

### SUPABASE_SCHEMA.SQL DEPLOYMENT

In Supabase Console:
1. Click "SQL Editor" in left sidebar
2. Click "New Query"
3. Copy entire contents of supabase_schema.sql
4. Paste into editor
5. Click "RUN"
6. Wait for "Success" message

Verify in Table Editor:
✓ users - should exist, 0 rows
✓ signed_prekeys - should exist, 0 rows
✓ prekeys - should exist, 0 rows
✓ contacts - should exist, 0 rows
✓ messages - should exist, 0 rows
✓ sessions - should exist, 0 rows

Verify RLS Policies (click on each table):
✓ All tables show "enable" under Security
✓ Each table has 4-5 policies


### AUTH_GATE.DART UPDATE

Before (current):
```dart
@override
void initState() {
  super.initState();
  _checkAuth();
}

Future<void> _checkAuth() async {
  final keyPair = await IdentityService().loadIdentityKeyPair();
  if (keyPair == null) {
    Navigator.pushReplacementNamed(context, '/onboarding');
  } else {
    Navigator.pushReplacementNamed(context, '/home');
  }
}
```

After (with initialization):
```dart
@override
void initState() {
  super.initState();
  _initialize();
}

Future<void> _initialize() async {
  final initService = AppInitializationService();
  
  initService.stepStream.listen((step) {
    debugPrint('[AuthGate] Init step: $step');
  });

  final success = await initService.initialize();
  
  if (!success) {
    Navigator.pushReplacementNamed(context, '/error');
    return;
  }
  
  // All initialized, go to home
  Navigator.pushReplacementNamed(context, '/home');
}
```


### CONTACT_ESTABLISHMENT_SERVICE.DART UPDATE

Before (current):
```dart
Future<SessionCipher> _buildSession(String contactId) async {
  return await signalSessionService.getOrCreateSession(
    contactUserId: contactId,
    contactPublicKeyB64: pubKey,
    store: store,
    deviceId: 1,
  );
}
```

After (with Supabase keys):
```dart
Future<SessionCipher> _buildSession(String contactId) async {
  final sessionBuilder = SignalSessionBuilder(
    store: store,
    keysService: SignalKeysUploadService(),
  );
  
  try {
    return await sessionBuilder.buildSession(
      recipientUserId: contactId,
      deviceId: 1,
    );
  } catch (e) {
    debugPrint('[ContactEstablishment] Session build failed: $e');
    throw 'Failed to establish session with $contactId';
  }
}
```


### MAIN.DART UPDATE

Add to initState or after app initialization:

```dart
void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _prekeyService = PrekeyManagementService();

  @override
  void initState() {
    super.initState();
    _startBackgroundTasks();
  }

  Future<void> _startBackgroundTasks() async {
    final userId = await IdentityService().getUserId();
    if (userId.isNotEmpty) {
      // Start auto-refill of one-time prekeys
      _prekeyService.startAutoRotation(userId: userId);
    }
  }

  @override
  void dispose() {
    _prekeyService.stopAutoRotation();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: const AuthGate(),
      // ... rest of app config
    );
  }
}
```


## TESTING CHECKLIST
─────────────────────────────────────────────────────────────────────────────

### Test 1: Initialization & Key Upload
□ Uninstall app
□ Run: flutter run
□ Watch console for:
  [AppInit] Checking for existing keys...
  [AppInit] Generating new keys...
  [AppInit] Uploading keys to Supabase...
  [AppInit] Connecting to relay...
  [AppInit] Successfully connected to relay

□ In Supabase Console:
  SELECT COUNT(*) FROM users; → Should see 1 row
  SELECT COUNT(*) FROM signed_prekeys; → Should see 1 row
  SELECT COUNT(*) FROM prekeys; → Should see ~50 rows

### Test 2: Relay Authentication
□ Open app
□ Check relay logs: [Relay] Authenticated: <uid>
□ WebSocket stays connected
□ No errors about invalid signature

### Test 3: Contact Addition
□ On device A: Share QR code
□ On device B: Scan QR → Add contact
□ Check console:
  [SignalSessionBuilder] Building session with <contact_id>
  [SignalSessionBuilder] Session created for <contact_id>
□ No errors about "Invalid signature on device key"

### Test 4: Message Send
□ Device B sends message to Device A
□ Check relay logs: message relayed
□ Device A receives decrypted text
□ Repeat 3 times (tests ratcheting)

### Test 5: App Restart
□ Send message
□ Force close app
□ Reopen app
□ Should recover existing keys (not regenerate)
□ Session should work (no re-setup needed)

### Test 6: Prekey Rotation
□ Monitor: SELECT COUNT(*) FROM prekeys WHERE used_at IS NULL;
□ Send 15+ messages (uses prekeys)
□ used_at count should increase
□ Background task should refill (if enabled)

### Test 7: Error Scenarios
□ Go offline, try to send → should queue/retry
□ Disconnect relay, reconnect → should auto-recover
□ Delete prekeys table manually → should detect and warn
□ Invalid relay URL → should retry with exponential backoff


## PRODUCTION DEPLOYMENT CHECKLIST
─────────────────────────────────────────────────────────────────────────────

### Code Review
□ RelayAuthService validates signatures correctly
□ SignalKeysUploadService handles errors gracefully
□ AppInitializationService is atomic (no partial state)
□ PrekeyManagementService maintains 50+ keys
□ All error paths logged with debugPrint

### Database
□ supabase_schema.sql applied
□ RLS policies enabled on all tables
□ Indexes created on high-traffic columns
□ TTL cleanup job scheduled (optional but recommended)

### Configuration
□ AppConfig.relayUrl correct (wss://...)
□ AppConfig.supabaseUrl correct
□ AppConfig.supabaseAnonKey correct
□ No hardcoded IPs or credentials

### Security
□ Identity keys stored in secure storage
□ Relay requires signed handshakes
□ RLS prevents cross-user access
□ Messages expire after 24h (configurable)
□ No plaintext in logs (except debug mode)

### Monitoring
□ Set up error tracking (Sentry/Firebase)
□ Monitor prekey consumption rate
□ Alert if prekey count drops
□ Monitor message delivery times
□ Track initialization failures

### Backup & Recovery
□ Test: Export identity key → import to new device
□ Test: Reset identity → full regeneration
□ Test: Panic wipe → all data deleted
□ Document recovery procedure for users


## COMMON ISSUES & FIXES
─────────────────────────────────────────────────────────────────────────────

Issue: "RLS policy violation on users"
  Cause: User not authenticated to Supabase
  Fix: Ensure supabase.auth.currentUser is not null

Issue: "Recipient keys not found"
  Cause: Recipient hasn't uploaded keys yet
  Fix: Recipient must complete initialization first

Issue: "Invalid signature on device key"
  Cause: Prekey not signed with identity private key
  Fix: Ensure SignalKeyService signing order correct

Issue: "Prekey not found"
  Cause: Used all one-time prekeys
  Fix: Increase prekey generation or lower refill threshold

Issue: "WebSocket connection timeout"
  Cause: Relay server down or unreachable
  Fix: Check relay URL, enable exponential backoff

Issue: "Message delivery delayed"
  Cause: Relay buffering or network slow
  Fix: Check message TTL, monitor relay queue depth


## PERFORMANCE OPTIMIZATION
─────────────────────────────────────────────────────────────────────────────

### Database Queries
• Use connection pooling in relay server
• Batch inserts: 50 prekeys in one query
• Index on (user_id, used_at) for prekey lookup
• Archive old messages (> 30 days) to archive table

### Key Management
• Cache identity key in app memory
• Cache prekeys locally (limit: 100 entries)
• Refresh prekey list periodically (every 12h)
• Delete consumed prekeys after 24h

### Relay Performance
• Use message batching (send multiple in one frame)
• Implement rate limiting (max 100 msg/min per user)
• Monitor queue depth (alert if > 1000)
• Log slow queries (> 100ms)

### App Performance
• Lazy-load contacts (pagination)
• Cache decrypted messages (configurable TTL)
• Pre-generate prekeys during app background
• Compress messages > 1KB


════════════════════════════════════════════════════════════════════════════
Integration complete. Start with Quick Start section.
════════════════════════════════════════════════════════════════════════════

