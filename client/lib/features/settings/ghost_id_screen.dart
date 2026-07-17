// lib/features/settings/ghost_id_screen.dart
// Permanent Vexa ID sharing: full ID, QR code, copy, share sheet.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/identity/identity_service.dart';
import '../../core/crypto/base64_util.dart';

class GhostIdScreen extends StatefulWidget {
  const GhostIdScreen({super.key});

  @override
  State<GhostIdScreen> createState() => _GhostIdScreenState();
}

class _GhostIdScreenState extends State<GhostIdScreen> {
  final _identity = IdentityService();
  String _userId = '';
  String _pubKeyB64 = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = await _identity.getUserId();
    final pk  = await _identity.getPublicKeyBase64();
    if (mounted) setState(() { _userId = uid; _pubKeyB64 = pk; });
  }

  String get _inviteLink => 'ghost://add/$_userId/${base64Pad(_pubKeyB64)}';

  Future<void> _copyId() async {
    if (_userId.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _userId));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Vexa ID copied')),
      );
    }
  }

  Future<void> _share() async {
    if (_userId.isEmpty) return;
    await Share.share(_inviteLink, subject: 'My Vexa ID');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Ghost ID')),
      body: _userId.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const SizedBox(height: 16),
                  Text(
                    'Others can add you by scanning this QR or entering your ID.',
                    style: GoogleFonts.inter(fontSize: 13, color: Colors.white60),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color:        const Color(0xFF111318),
                      borderRadius: BorderRadius.circular(20),
                      border:       Border.all(color: cs.primary.withOpacity(0.3)),
                    ),
                    child: Column(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: QrImageView(
                            data:   _inviteLink,
                            version: QrVersions.auto,
                            size:    200,
                            backgroundColor: Colors.white,
                            eyeStyle: const QrEyeStyle(
                              eyeShape: QrEyeShape.square,
                              color:    Color(0xFF0A0B0D),
                            ),
                            dataModuleStyle: const QrDataModuleStyle(
                              dataModuleShape: QrDataModuleShape.square,
                              color:           Color(0xFF0A0B0D),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Your Vexa ID',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            color: Colors.white38,
                            letterSpacing: 1.2,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        SelectableText(
                          _userId,
                          style: GoogleFonts.robotoMono(fontSize: 11, color: cs.primary),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _copyId,
                          icon:  const Icon(Icons.copy_rounded, size: 18),
                          label: const Text('Copy ID'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: cs.primary,
                            side: BorderSide(color: cs.primary.withOpacity(0.5)),
                            minimumSize: const Size(0, 48),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _share,
                          icon:  const Icon(Icons.share_rounded, size: 18),
                          label: const Text('Share'),
                          style: ElevatedButton.styleFrom(minimumSize: const Size(0, 48)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
    );
  }
}
