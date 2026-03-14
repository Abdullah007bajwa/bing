// lib/features/contacts/qr_scanner_screen.dart
// Scan a contact's QR code to extract their Ghost ID + public key.
// Uses MLKit (Android) / AVFoundation (iOS) via mobile_scanner.

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:google_fonts/google_fonts.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../core/identity/identity_service.dart';
import '../../core/crypto/base64_util.dart';
import 'contact_confirm_screen.dart';

class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _processed = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onScan(BarcodeCapture capture) async {
    if (_processed) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null) return;

    // Expected format: ghost://add/<user_id>/<public_key_b64>
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'ghost' || uri.host != 'add') return;

    final parts = uri.pathSegments;
    if (parts.length < 2) return;

    _processed = true;
    await _controller.stop();

    final contactUserId = parts[0];
    final pubKeyB64     = parts[1];

    await _onContactScanned(contactUserId, pubKeyB64);
  }

  Future<void> _onContactScanned(String uid, String pubKeyB64) async {
    try {
      final identity = IdentityService();
      final normalizedKey = base64Pad(pubKeyB64);
      final fingerprint = await identity.getFingerprint(normalizedKey);

      if (fingerprint.isEmpty) {
        if (mounted) _showRescanError();
        return;
      }

      if (!mounted) return;
      final result = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ContactConfirmScreen(
            userId:       uid,
            publicKeyB64: normalizedKey,
            fingerprint:  fingerprint,
          ),
        ),
      );

      if (mounted && result != null) {
        Navigator.pop(context, result);
      }
    } catch (e, st) {
      if (kDebugMode) debugPrint('[QrScanner] Error: $e\n$st');
      if (mounted) _showRescanError();
    }
  }

  void _showRescanError() {
    _processed = false;
    _controller.start();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Invalid QR code or key. Please scan again.'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR Code')),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect:   _onScan,
          ),
          // Overlay
          Center(
            child: Container(
              width: 260, height: 260,
              decoration: BoxDecoration(
                border: Border.all(color: cs.primary, width: 2),
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
          Positioned(
            bottom: 40, left: 0, right: 0,
            child: Center(
              child: Text(
                'Point at a Ghost QR code',
                style: GoogleFonts.inter(
                  color: Colors.white70, fontSize: 14,
                  shadows: [const Shadow(blurRadius: 8, color: Colors.black)],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
