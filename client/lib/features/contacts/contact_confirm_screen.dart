// lib/features/contacts/contact_confirm_screen.dart
// Contact confirmation: fingerprint verification + local nickname before saving.
// No contact is stored until user confirms; nicknames stay local only.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../core/storage/secure_db.dart';
import '../../core/contacts/contact_establishment_service.dart';
import '../../models/contact.dart';

class ContactConfirmScreen extends StatefulWidget {
  final String userId;
  final String publicKeyB64;
  final String fingerprint;

  const ContactConfirmScreen({
    super.key,
    required this.userId,
    required this.publicKeyB64,
    required this.fingerprint,
  });

  @override
  State<ContactConfirmScreen> createState() => _ContactConfirmScreenState();
}

class _ContactConfirmScreenState extends State<ContactConfirmScreen> {
  final _nicknameController = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _nicknameController.dispose();
    super.dispose();
  }

  Future<void> _addContact() async {
    if (_saving) return;
    setState(() => _saving = true);

    final nickname = _nicknameController.text.trim();
    final now = DateTime.now().millisecondsSinceEpoch;

    final contact = GhostContact(
      userId:       widget.userId,
      publicKeyB64: widget.publicKeyB64,
      fingerprint:  widget.fingerprint,
      nickname:     nickname.isEmpty ? null : nickname,
      verified:     false,
      addedAt:      now,
    );

    await SecureDb().upsertContact(contact.toDbMap());

    // Send automated message so recipient sees this contact and conversation is established
    final sent = await ContactEstablishmentService().sendContactEstablishmentMessage(contact);

    if (mounted) {
      if (!sent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Contact added. If the other person doesn\'t see you yet, ask them to open the app.'),
            duration: Duration(seconds: 4),
          ),
        );
      }
      Navigator.popUntil(context, ModalRoute.withName('/home'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final blocks = widget.fingerprint.split(' ');

    return Scaffold(
      appBar: AppBar(title: const Text('Add Contact')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Confirmation
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color:        cs.primary.withOpacity(0.08),
                borderRadius: BorderRadius.circular(14),
                border:       Border.all(color: cs.primary.withOpacity(0.25)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.person_add_rounded, color: cs.primary, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        'Confirm contact',
                        style: GoogleFonts.inter(
                          fontWeight: FontWeight.w700,
                          color: cs.primary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Verify the fingerprint with this person over a trusted channel, '
                    'then set a local nickname (optional).',
                    style: GoogleFonts.inter(fontSize: 12, color: Colors.white60),
                  ),
                ],
              ),
            ).animate().fadeIn(duration: 400.ms),

            const SizedBox(height: 24),

            Text(
              'Ghost ID',
              style: GoogleFonts.inter(
                fontSize: 12,
                color: Colors.white38,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            SelectableText(
              widget.userId,
              style: GoogleFonts.robotoMono(fontSize: 11, color: cs.primary),
            ),

            const SizedBox(height: 20),

            Text(
              'Fingerprint (Safety Number)',
              style: GoogleFonts.inter(
                fontSize: 12,
                color: Colors.white38,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            GridView.builder(
              shrinkWrap:  true,
              physics:   const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount:    4,
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
                    fontSize: 11,
                    color: cs.primary,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 24),

            Text(
              'Nickname (local only, never sent to server)',
              style: GoogleFonts.inter(
                fontSize: 12,
                color: Colors.white38,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _nicknameController,
              autocorrect: false,
              style:      GoogleFonts.inter(fontSize: 15),
              decoration: const InputDecoration(
                hintText: 'e.g. Alice',
              ),
            ),

            const SizedBox(height: 32),

            ElevatedButton.icon(
              onPressed: _saving ? null : _addContact,
              icon:  _saving
                  ? const SizedBox(
                      width:  20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_rounded),
              label: Text(_saving ? 'Adding…' : 'Add Contact'),
              style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 52)),
            ).animate().fadeIn(delay: 300.ms),

            const SizedBox(height: 12),

            TextButton.icon(
              onPressed: () => Navigator.pop(context),
              icon:  const Icon(Icons.close_rounded, size: 18),
              label: const Text('Cancel'),
              style: TextButton.styleFrom(foregroundColor: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }
}
