// lib/core/auth/auth_gate.dart
// AuthGate determines whether to show onboarding or home based on initialization status

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import '../initialization/app_initialization_service.dart';
import '../../features/onboarding/onboarding_screen.dart';
import '../../features/contacts/contacts_screen.dart';

class AuthGate extends StatefulWidget {
  final bool isNewUser;
  const AuthGate({super.key, this.isNewUser = false});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

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
      // If flagged as new user, go to onboarding
      if (widget.isNewUser) {
        _child = const OnboardingScreen();
        if (mounted) setState(() => _loading = false);
        return;
      }

      // Monitor initialization progress
      _initService.stepStream.listen((step) {
        if (kDebugMode) {
          debugPrint('[AuthGate] Init step: $step');
        }
      });

      // Run atomic initialization
      final success = await _initService.initialize();

      if (success) {
        if (kDebugMode) {
          debugPrint('[AuthGate] Initialization complete, showing contacts');
        }
        _child = const ContactsScreen();
      } else {
        if (kDebugMode) {
          debugPrint('[AuthGate] Initialization failed, showing onboarding');
        }
        _child = const OnboardingScreen();
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AuthGate] Error: $e');
      }
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

