// lib/features/contacts/fingerprint_screen.dart
// Key fingerprint (safety numbers) verification screen.
// Users compare fingerprints out-of-band to confirm no MITM attack.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../core/storage/secure_db.dart';
import '../../models/contact.dart';

class FingerprintScreen extends StatelessWidget {
  final GhostContact contact;
  const FingerprintScreen({super.key, required this.contact});

  Future<void> _markVerified(BuildContext ctx) async {
    await SecureDb().upsertContact(contact.copyWith(verified: true).toDbMap());
    if (ctx.mounted) {
      Navigator.popUntil(ctx, ModalRoute.withName('/home'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs     = Theme.of(context).colorScheme;
    final blocks = contact.fingerprint.split(' ');

    return Scaffold(
      appBar: AppBar(title: const Text('Verify Contact')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Explanation
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color:        cs.primary.withOpacity(0.08),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: cs.primary.withOpacity(0.25)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.security_rounded, color: cs.primary, size: 20),
                    const SizedBox(width: 8),
                    Text('Safety Number', style: GoogleFonts.inter(
                      fontWeight: FontWeight.w700, color: cs.primary,
                    )),
                  ]),
                  const SizedBox(height: 8),
                  Text(
                    'Compare this number with ${contact.displayName} over a trusted channel '
                    '(phone call, in person). If they match, mark as verified.',
                    style: GoogleFonts.inter(fontSize: 12, color: Colors.white60),
                  ),
                ],
              ),
            ).animate().fadeIn(duration: 500.ms),

            const SizedBox(height: 28),

            Text('Fingerprint', style: GoogleFonts.inter(
              fontSize: 12, color: Colors.white38, letterSpacing: 1.2, fontWeight: FontWeight.w600,
            )),
            const SizedBox(height: 12),

            // Fingerprint blocks grid
            GridView.builder(
              shrinkWrap:  true,
              physics:     const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount:   4,
                mainAxisSpacing:  8,
                crossAxisSpacing: 8,
                childAspectRatio: 2.2,
              ),
              itemCount: blocks.length,
              itemBuilder: (_, i) => Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color:        const Color(0xFF111318),
                  borderRadius: BorderRadius.circular(8),
                  border:       Border.all(color: Colors.white12),
                ),
                child: Text(
                  blocks[i],
                  style: GoogleFonts.robotoMono(
                    fontSize: 11, color: cs.primary, letterSpacing: 1,
                  ),
                ),
              ).animate(delay: Duration(milliseconds: i * 40))
                  .fadeIn().scaleXY(begin: 0.9),
            ),

            const SizedBox(height: 32),

            // Contact info
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: cs.primary.withOpacity(0.15),
                  child: Text(contact.displayName[0].toUpperCase(),
                      style: TextStyle(color: cs.primary, fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(contact.displayName,
                        style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
                    Text(contact.shortId,
                        style: GoogleFonts.robotoMono(fontSize: 10, color: Colors.white38)),
                  ],
                ),
              ],
            ),

            const Spacer(),

            ElevatedButton.icon(
              onPressed: () => _markVerified(context),
              icon:  const Icon(Icons.verified_rounded),
              label: const Text('Mark as Verified — Start Chat'),
            ).animate().fadeIn(delay: 600.ms),

            const SizedBox(height: 12),

            TextButton(
              onPressed: () => Navigator.popUntil(context, ModalRoute.withName('/home')),
              child: Text('Skip Verification (Not Recommended)',
                  style: GoogleFonts.inter(color: Colors.white30, fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }
}
