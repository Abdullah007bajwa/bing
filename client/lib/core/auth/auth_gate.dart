// lib/core/auth/auth_gate.dart
// AuthGate determines whether to show onboarding or home based on initialization status

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import '../initialization/app_initialization_service.dart';
import '../../features/onboarding/onboarding_screen.dart';
import '../../features/contacts/contacts_screen.dart';
import '../../features/splash/vexa_splash_screen1.dart';
import '../../features/splash/vexa_splash_screen2.dart';
import 'dart:async';

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
  int _splashStage = 1; // 1 -> splash1, 2 -> splash2
  bool _splash2Done = false;
  bool _initDone = false;
  bool _initSuccess = false;
  StreamSubscription<InitializationStep>? _stepSub;

  @override
  void initState() {
    super.initState();
    _determineStart();
  }

  Future<void> _determineStart() async {
    try {
      // If flagged as new user, go to onboarding
      if (widget.isNewUser) {
        _initDone = true;
        _initSuccess = false;
        if (mounted) setState(() => _loading = true);
      }

      // Monitor initialization progress
      if (!widget.isNewUser) {
        _stepSub = _initService.stepStream.listen((step) {
          if (kDebugMode) debugPrint('[AuthGate] Init step: $step');
        });

        // Run atomic initialization concurrently while splash plays.
        _initService.initialize().then((success) {
          _initSuccess = success;
          _initDone = true;
          _maybeFinishSplash();
        }).catchError((e) {
          if (kDebugMode) debugPrint('[AuthGate] Error: $e');
          _initSuccess = false;
          _initDone = true;
          _maybeFinishSplash();
        });
      } else {
        // New user: no init work needed.
        _maybeFinishSplash();
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AuthGate] Error: $e');
      }
      _initSuccess = false;
      _initDone = true;
      _maybeFinishSplash();
    }
  }

  void _onSplashNext() {
    if (!mounted) return;
    setState(() => _splashStage = 2);
  }

  void _onSplashComplete() {
    if (!mounted) return;
    setState(() => _splash2Done = true);
    _maybeFinishSplash();
  }

  void _maybeFinishSplash() {
    if (!_initDone || !_splash2Done) return;

    _child = _initSuccess ? const ContactsScreen() : const OnboardingScreen();
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _stepSub?.cancel();
    _initService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      if (_splashStage == 1) {
        return VexaSplashScreen1(onNext: _onSplashNext);
      }
      return VexaSplashScreen2(onComplete: _onSplashComplete);
    }

    return _child ?? const OnboardingScreen();
  }
}

