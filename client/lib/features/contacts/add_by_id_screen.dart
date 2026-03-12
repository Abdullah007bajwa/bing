// lib/features/contacts/add_by_id_screen.dart
// Add a remote contact by pasting their Ghost ID.
// Uses RPC get_public_key_by_hash (RLS-safe), then shows confirmation + fingerprint + nickname.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/identity/identity_service.dart';
import 'contact_confirm_screen.dart';

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
      // RPC bypasses RLS SELECT; returns public_key only when user_id matches
      final result = await supabase.rpc(
        'get_public_key_by_hash',
        params: {'lookup_hash': uid},
      );

      if (result == null || result is! String || (result as String).isEmpty) {
        setState(() { _error = 'User not found. Check the ID.'; _isLooking = false; });
        return;
      }

      final pubKeyB64 = result as String;
      final identity  = IdentityService();
      final fingerprint = await identity.getFingerprint(pubKeyB64);

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => ContactConfirmScreen(
              userId:       uid,
              publicKeyB64: pubKeyB64,
              fingerprint:  fingerprint,
            ),
          ),
        );
      }
    } on PostgrestException catch (_) {
      setState(() { _error = 'User not found. Check the ID.'; _isLooking = false; });
    } catch (_) {
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
