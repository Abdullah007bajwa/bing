// lib/core/initialization/app_initialization_service.dart
// Atomic initialization of cryptography, storage, relay, and Supabase
// Ensures keys are generated → uploaded → relay connected in order
// Handles failures gracefully with retries

import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import '../identity/identity_service.dart';
import '../crypto/signal_key_service.dart';
import '../crypto/signal_keys_upload_service.dart';
import '../crypto/prekey_management_service.dart';
import '../../relay/relay_auth_service.dart';
import '../../relay/relay_coordinator.dart';
import '../../relay/websocket_client.dart';
import '../../app_config.dart';

enum InitializationStep {
  checkExistingKeys,
  generateKeys,
  uploadToSupabase,
  connectToRelay,
  complete,
  error,
}

class AppInitializationService {
  static final AppInitializationService _instance =
      AppInitializationService._();
  factory AppInitializationService() => _instance;
  AppInitializationService._();

  final _identityService = IdentityService();
  final _signalKeyService = SignalKeyService();
  final _signalUploadService = SignalKeysUploadService();
  final _prekeyService = PrekeyManagementService();
  final _relayAuthService = RelayAuthService();
  final _relayClient = GhostRelayClient();

  InitializationStep _currentStep = InitializationStep.checkExistingKeys;
  InitializationStep get currentStep => _currentStep;

  // Stream for monitoring initialization progress
  final _stepStream = StreamController<InitializationStep>.broadcast();
  Stream<InitializationStep> get stepStream => _stepStream.stream;

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;
  bool _signedPreKeyEnsuredThisRun = false;

  /// Run complete initialization sequence
  /// Returns true if successful, false if failed
  Future<bool> initialize() async {
    try {
      _isInitialized = false;
      _signedPreKeyEnsuredThisRun = false;

      // Step 1: Check for existing keys
      _updateStep(InitializationStep.checkExistingKeys);
      if (kDebugMode) {
        debugPrint('[AppInit] Checking for existing keys...');
      }

      final existingKeyPair = await _identityService.loadIdentityKeyPair();
      final signalKeysInitialized =
          await _signalKeyService.areSignalKeysInitialized();

      if (existingKeyPair != null && signalKeysInitialized) {
        if (kDebugMode) {
          debugPrint('[AppInit] Using existing keys');
        }
        final userId = await _identityService.getUserId();

        // Migration: older installs may have the flag but not the signed-prekey record.
        try {
          await _ensureSignedPreKeyOnce(identityKeyPair: existingKeyPair);
        } catch (_) {}

        // Migration: ensure local private prekeys exist and top up Supabase if needed.
        await _prekeyService.ensureLocalPrekeysAndUpload(userId: userId);

        // Always upsert identity/signed-prekey on launch.
        // This is safe and idempotent: local keys never change after first init
        // (guarded by areSignalKeysInitialized), so the same bytes are written every time.
        // Skipping the upload risks Supabase having stale/incorrect keys if external
        // resets happened, which breaks session establishment for all senders.
        try {
          await _uploadKeysToSupabase(userId: userId, identityKeyPair: existingKeyPair);
        } catch (_) {}
        return await _connectToRelay();
      }

      // Step 2: Generate new keys
      _updateStep(InitializationStep.generateKeys);
      if (kDebugMode) {
        debugPrint('[AppInit] Generating new keys...');
      }

      final identityKeyPair = await _identityService.generateIdentityKeyPair();
      await _signalKeyService.initializeSignalKeys(identityKeyPair: identityKeyPair);

      if (kDebugMode) {
        debugPrint('[AppInit] Keys generated successfully');
      }

      // Step 3: Upload public keys to Supabase
      _updateStep(InitializationStep.uploadToSupabase);
      if (kDebugMode) {
        debugPrint('[AppInit] Uploading keys to Supabase...');
      }

      final userId = await _identityService.getUserId();

      // CRITICAL: Register user in Supabase FIRST before uploading any keys
      // This creates the users table row, so foreign key constraints don't fail
      try {
        await _identityService.registerToSupabase(
          supabaseUrl: AppConfig.supabaseUrl,
          supabaseAnonKey: AppConfig.supabaseAnonKey,
        );
        if (kDebugMode) {
          debugPrint('[AppInit] User registered to Supabase');
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[AppInit] User registration to Supabase failed: $e (will retry)');
        }
      }

      final uploadSuccess = await _uploadKeysToSupabase(
        userId: userId,
        identityKeyPair: identityKeyPair,
      );

      if (!uploadSuccess) {
        if (kDebugMode) {
          debugPrint('[AppInit] Key upload failed (non-blocking)');
        }
        // Non-fatal: allow offline operation, will retry on next launch
      }

      // Step 4: Connect to relay
      return await _connectToRelay();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AppInit] Initialization error: $e');
      }
      _updateStep(InitializationStep.error);
      _isInitialized = false;
      return false;
    }
  }

  /// Upload keys to Supabase with retry logic
  Future<bool> _uploadKeysToSupabase({
    required String userId,
    required IdentityKeyPair identityKeyPair,
  }) async {
    const maxRetries = 3;
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        final registrationId = await _signalKeyService.getRegistrationId();
        // Always verify/regenerate the local SignedPreKeyRecord so it matches
        // the identity that is being uploaded to Supabase.
        final signedPreKey = await _ensureSignedPreKeyOnce(
          identityKeyPair: identityKeyPair,
        );

        // Upload identity key + signed prekey
        final success = await _signalUploadService.uploadSignalKeys(
          userId: userId,
          identityKeyPair: identityKeyPair,
          registrationId: registrationId,
          signedPreKeyPair: signedPreKey.getKeyPair(),
          signedPreKeyId: signedPreKey.id,
          signedPreKeySignature: signedPreKey.signature,
        );

        if (success) {
          if (kDebugMode) {
            debugPrint('[AppInit] Keys uploaded successfully');
          }
          return true;
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[AppInit] Upload attempt $attempt failed: $e');
        }
        if (attempt < maxRetries) {
          await Future.delayed(Duration(seconds: attempt * 2));
        }
      }
    }
    return false;
  }

  Future<SignedPreKeyRecord> _ensureSignedPreKeyOnce({
    required IdentityKeyPair identityKeyPair,
  }) async {
    if (_signedPreKeyEnsuredThisRun) {
      final existing = await _signalKeyService.loadSignedPreKeyRecord();
      if (existing != null) return existing;
    }
    final ensured = await _signalKeyService.ensureSignedPreKeyRecord(
      identityKeyPair: identityKeyPair,
      keyId: 1,
    );
    _signedPreKeyEnsuredThisRun = true;
    return ensured;
  }

  /// Connect to relay with signed handshake
  Future<bool> _connectToRelay() async {
    try {
      _updateStep(InitializationStep.connectToRelay);
      if (kDebugMode) {
        debugPrint('[AppInit] Connecting to relay...');
      }

      final userId = await _identityService.getUserId();
      final identityKeyPair =
          await _identityService.loadIdentityKeyPair();

      if (userId.isEmpty || identityKeyPair == null) {
        if (kDebugMode) {
          debugPrint('[AppInit] Missing userId or identity keys');
        }
        _updateStep(InitializationStep.error);
        return false;
      }

      // Generate signed handshake for relay authentication
      final handshake = await _relayAuthService.generateAuthHandshake(
        userId: userId,
        identityKeyPair: identityKeyPair,
      );

      // Set handshake on relay client before connecting
      _relayClient.setAuthHandshake(handshake);

      // Connect to relay
      await _relayClient.connect(
        relayUrl: AppConfig.relayWssUrl,
        userId: userId,
      );

      if (_relayClient.isConnected) {
        if (kDebugMode) {
          debugPrint('[AppInit] Successfully connected to relay');
        }
        // Install app-level packet handler immediately so deliverPending / any inbound packets are not dropped
        await RelayCoordinator().connect(
          relayUrl: AppConfig.relayWssUrl,
          userId:   userId,
        );
        _updateStep(InitializationStep.complete);
        _isInitialized = true;
        return true;
      } else {
        if (kDebugMode) {
          debugPrint('[AppInit] Relay connection failed');
        }
        _updateStep(InitializationStep.error);
        return false;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AppInit] Relay connection error: $e');
      }
      _updateStep(InitializationStep.error);
      return false;
    }
  }

  void _updateStep(InitializationStep step) {
    _currentStep = step;
    _stepStream.add(step);
  }

  void dispose() {
    _stepStream.close();
  }

}

