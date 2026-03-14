// EXACT CODE CHANGES NEEDED
// Copy-paste this section into each file
// ════════════════════════════════════════════════════════════════════════════

## 1. lib/core/auth/auth_gate.dart (Update to use AppInitializationService)
─────────────────────────────────────────────────────────────────────────────

ADD this import at top:
  import '../initialization/app_initialization_service.dart';

REPLACE the _AuthGateState class:

class _AuthGateState extends State<AuthGate> {
  bool _loading = true;
  Widget? _child;
  final _initService = AppInitializationService();

  @override
  void initState() {
    super.initState();
    _determineStart();
  }

  Future<void> _determineStart() async {
    try {
      final user = Supabase.instance.client.auth.currentUser;

      // New user -> go to onboarding
      if (widget.isNewUser) {
        _child = const OnboardingScreen();
      } else if (user == null) {
        // Try to initialize existing keys
        final success = await _initService.initialize();
        if (success) {
          _child = const ContactsScreen();
        } else {
          _child = const OnboardingScreen();
        }
      } else {
        // Session exists -> show home
        _child = const ContactsScreen();
      }
    } catch (e) {
      debugPrint('[AuthGate] Error: $e');
      _child = const OnboardingScreen();
    }

    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _initService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Color(0xFF0A0B0D),
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return _child ?? const OnboardingScreen();
  }
}


## 2. lib/features/onboarding/onboarding_screen.dart (Add key generation)
─────────────────────────────────────────────────────────────────────────────

ADD this import at top:
  import '../../core/crypto/prekey_management_service.dart';
  import '../../core/crypto/signal_keys_upload_service.dart';

REPLACE the _initialize() method in _OnboardingScreenState:

Future<void> _initialize() async {
  try {
    // Step 1: Generate identity keypair
    await _identity.generateIdentityKeyPair();
    final uid = await _identity.getUserId();
    final pk = await _identity.getPublicKeyBase64();

    // Step 2: Initialize Signal Protocol keys in correct order
    // This generates: identity key, registration ID, signed prekey, signature
    await _signalKeyService.initializeSignalKeys();

    // Step 3: Generate initial one-time prekeys (50+)
    final prekeyService = PrekeyManagementService();
    final initialPreKeys = await prekeyService.generateInitialPreKeys();

    // Step 4: Upload public keys to Supabase
    final uploadService = SignalKeysUploadService();
    
    // Get the keys we just generated
    final identityKeyPair = await _identity.loadIdentityKeyPair();
    if (identityKeyPair != null) {
      final regId = Random().nextInt(16384);
      final signedPreKeyPair = Curve.generateKeyPair();
      final signedPreKeySig = Curve.calculateSignature(
        identityKeyPair.getPrivateKey(),
        signedPreKeyPair.publicKey.serialize(),
      );

      // Upload identity + signed prekey
      await uploadService.uploadSignalKeys(
        userId: uid,
        identityKeyPair: identityKeyPair,
        registrationId: regId,
        signedPreKeyPair: signedPreKeyPair,
        signedPreKeyId: 1,
        signedPreKeySignature: signedPreKeySig,
      );

      // Upload initial prekeys
      await uploadService.uploadOneTimePreKeys(
        userId: uid,
        preKeys: initialPreKeys,
      );
    }

    // Step 5: Register identity to Supabase (legacy, for backward compat)
    final registered = await _identity.registerToSupabase(
      supabaseUrl: AppConfig.supabaseUrl,
      supabaseAnonKey: AppConfig.supabaseAnonKey,
    );
    if (!registered) {
      // Non-fatal: allow offline
    }

    setState(() {
      _isGenerating = false;
      _userId = uid;
      _pubKeyB64 = pk;
    });
  } catch (e) {
    debugPrint('[Onboarding] Init error: $e');
    setState(() => _isGenerating = false);
  }
}

ADD these imports if not already present:
  import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
  import 'dart:math';


## 3. lib/main.dart (Start prekey rotation)
─────────────────────────────────────────────────────────────────────────────

ADD import at top:
  import 'core/crypto/prekey_management_service.dart';

ADD this inside _GhostAppState initState():

@override
void initState() {
  super.initState();
  WidgetsBinding.instance.addObserver(this);
  _initializeBackgroundTasks();
}

Future<void> _initializeBackgroundTasks() async {
  try {
    final userId = await IdentityService().getUserId();
    if (userId.isNotEmpty) {
      // Start auto-refill of one-time prekeys every 24 hours
      final prekeyService = PrekeyManagementService();
      prekeyService.startAutoRotation(userId: userId);
    }
  } catch (e) {
    debugPrint('[Main] Failed to start background tasks: $e');
  }
}

ALSO update dispose():

@override
void dispose() {
  WidgetsBinding.instance.removeObserver(this);
  PrekeyManagementService().stopAutoRotation();
  super.dispose();
}


## 4. lib/core/contacts/contact_establishment_service.dart
─────────────────────────────────────────────────────────────────────────────

If this file exists, ADD import:
  import '../crypto/signal_session_builder.dart';
  import '../crypto/signal_keys_upload_service.dart';

FIND this method (or create if not exists):

Future<SessionCipher> buildSessionWithContact({
  required String contactUserId,
  required InMemorySignalProtocolStore store,
  required int deviceId,
}) async {
  try {
    final sessionBuilder = SignalSessionBuilder(
      store: store,
      keysService: SignalKeysUploadService(),
    );
    
    return await sessionBuilder.buildSession(
      recipientUserId: contactUserId,
      deviceId: deviceId,
    );
  } catch (e) {
    debugPrint('[ContactEstablishment] Session build failed: $e');
    rethrow;
  }
}


## 5. Supabase Database Setup (One-time, manual step)
─────────────────────────────────────────────────────────────────────────────

1. Go to supabase.com → Login → Your Project
2. Click "SQL Editor" in left sidebar
3. Click "New Query"
4. Copy entire contents of supabase_schema.sql from workspace
5. Paste into SQL editor
6. Click "RUN"
7. Wait for "Success" message

Verify:
  • Click "Table Editor" in left sidebar
  • Should see 6 tables:
    - users
    - signed_prekeys
    - prekeys
    - contacts
    - messages
    - sessions
  • Each table should show lock icon (RLS enabled)


## 6. Environment Variables (.env file)
─────────────────────────────────────────────────────────────────────────────

Ensure .env file in project root has:

RELAY_WSS_URL=wss://bing-2iqr.onrender.com/ws
SUPABASE_URL=https://xxxxx.supabase.co
SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...

Get values from:
  • Supabase Console → Settings → API
  • Copy: Project URL and anon public key


## 7. Relay Server Update (If you control the relay)
─────────────────────────────────────────────────────────────────────────────

When client connects, relay should:

const handshake = JSON.parse(message);  // {uid, timestamp, signature}

// Fetch user's public key from your DB
const publicKey = await getPublicKeyForUser(handshake.uid);

// Verify signature
const isValid = verifySignature(
  handshake.uid + ':' + handshake.timestamp,
  handshake.signature,
  publicKey
);

if (!isValid) {
  socket.close(4003, 'Invalid signature');
  return;
}

// Accept connection
socket.isAuthenticated = true;

This prevents impersonation on the relay.


════════════════════════════════════════════════════════════════════════════
INTEGRATION STEPS (In Order)
════════════════════════════════════════════════════════════════════════════

Step 1: Database (Manual, Supabase Console)
  □ Copy supabase_schema.sql
  □ Paste into SQL Editor
  □ Click Run
  □ Verify 6 tables created

Step 2: Update onboarding_screen.dart
  □ Add imports
  □ Replace _initialize() method
  □ Save and check for compile errors

Step 3: Update auth_gate.dart
  □ Add import
  □ Replace _AuthGateState class
  □ Save and check for compile errors

Step 4: Update main.dart
  □ Add import
  □ Add _initializeBackgroundTasks()
  □ Update initState() and dispose()
  □ Save and check for compile errors

Step 5: (Optional) Update contact_establishment_service.dart
  □ Add imports
  □ Add buildSessionWithContact() method
  □ Save and check for compile errors

Step 6: Update .env file
  □ Add SUPABASE_URL
  □ Add SUPABASE_ANON_KEY
  □ RELAY_WSS_URL already set

Step 7: Clean build
  □ flutter clean
  □ flutter pub get
  □ flutter run

Step 8: Test initialization
  □ Uninstall app from device
  □ Run on clean device
  □ Watch logs for:
    [AppInit] Checking for existing keys...
    [AppInit] Generating new keys...
    [AppInit] Uploading keys to Supabase...
    [AppInit] Connecting to relay...
    [AppInit] Successfully connected to relay

Step 9: Verify Supabase
  □ Open Supabase Console
  □ Table Editor → users
  □ Should see 1 row with your identity_key
  □ Check signed_prekeys table → 1 row
  □ Check prekeys table → ~50 rows

Step 10: Test messaging
  □ Add a contact
  □ Send a message
  □ Watch for no "Invalid signature" errors
  □ Message should be encrypted end-to-end


════════════════════════════════════════════════════════════════════════════

