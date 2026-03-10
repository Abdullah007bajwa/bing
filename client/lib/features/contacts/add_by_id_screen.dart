// lib/features/contacts/add_by_id_screen.dart
// Add a remote contact by pasting their Ghost ID.
// Fetches their public key from Supabase, then shows fingerprint for verification.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/storage/secure_db.dart';
import '../../core/identity/identity_service.dart';
import '../../models/contact.dart';
import '../../app_config.dart';
import 'fingerprint_screen.dart';

class AddByIdScreen extends StatefulWidget {
  const AddByIdScreen({super.key});

  @override
  State<AddByIdScreen> createState() => _AddByIdScreenState();
}

class _AddByIdScreenState extends State<AddByIdScreen> {
  final _idController = TextEditingController();
  bool   _isLooking   = false;
  String? _error;

  @override
  void dispose() {
    _idController.dispose();
    super.dispose();
  }

  Future<void> _lookup() async {
    final uid = _idController.text.trim();
    if (uid.isEmpty) return;

    setState(() { _isLooking = true; _error = null; });

    try {
      final supabase = Supabase.instance.client;
      final result   = await supabase
          .from('users')
          .select('user_id, public_key')
          .eq('user_id', uid)
          .single();

      final pubKeyB64 = result['public_key'] as String;
      final identity  = IdentityService();
      final fingerprint = await identity.getFingerprint(pubKeyB64);
      final now = DateTime.now().millisecondsSinceEpoch;

      final contact = GhostContact(
        userId:       uid,
        publicKeyB64: pubKeyB64,
        fingerprint:  fingerprint,
        addedAt:      now,
      );

      await SecureDb().upsertContact(contact.toDbMap());

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => FingerprintScreen(contact: contact)),
        );
      }
    } on PostgrestException catch (e) {
      setState(() { _error = 'User not found. Check the ID.'; _isLooking = false; });
    } catch (e) {
      setState(() { _error = 'Network error. Try again.'; _isLooking = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add by Ghost ID')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Enter Ghost ID',
              style: GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 16),
            ),
            const SizedBox(height: 8),
            TextField(
              controller:   _idController,
              autocorrect:  false,
              style: GoogleFonts.robotoMono(fontSize: 13),
              decoration: const InputDecoration(hintText: 'Paste Ghost ID here…'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
            ],
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _isLooking ? null : _lookup,
              child: _isLooking
                  ? const CircularProgressIndicator(strokeWidth: 2, color: Colors.black)
                  : const Text('Look Up & Add'),
            ),
          ],
        ),
      ),
    );
  }
}
