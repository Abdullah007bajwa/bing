// lib/features/contacts/contacts_screen.dart
// Main home screen: list of contacts (chats).
// Add via QR scan or paste ID. All contacts stored locally in SQLCipher.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../core/storage/secure_db.dart';
import '../../core/identity/identity_service.dart';
import '../../relay/relay_coordinator.dart';
import '../../models/contact.dart';
import '../../app_config.dart';
import '../chat/chat_screen.dart';
import '../settings/panic_wipe_screen.dart';
import 'qr_scanner_screen.dart';
import 'add_by_id_screen.dart';
import '../settings/settings_screen.dart';
import '../settings/ghost_id_screen.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final _db = SecureDb();
  List<GhostContact> _contacts = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final identity = IdentityService();
    final userId = await identity.getUserId();
    if (userId.isNotEmpty) {
      await RelayCoordinator().connect(
        relayUrl: AppConfig.relayWssUrl,
        userId:   userId,
      );
    }
    await _loadContacts();
  }

  Future<void> _loadContacts() async {
    final rows = await _db.getAllContacts();
    if (mounted) {
      setState(() {
        _contacts = rows.map(GhostContact.fromDbMap).toList();
        _loading  = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.shield_rounded, color: cs.primary, size: 20),
            const SizedBox(width: 8),
            const Text('Ghost'),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.settings_rounded, color: cs.onSurface),
            tooltip: 'Settings',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ).then((_) => _loadContacts()),
          ),
          IconButton(
            icon: Icon(Icons.local_fire_department_rounded, color: cs.error),
            tooltip: 'Panic Wipe',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PanicWipeScreen()),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _contacts.isEmpty
              ? _buildEmptyState(cs)
              : _buildContactList(cs),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddContactSheet,
        backgroundColor: cs.primary,
        foregroundColor: const Color(0xFF0A0B0D),
        icon:  const Icon(Icons.person_add_rounded),
        label: Text('Add Contact', style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.person_off_rounded, size: 64, color: Colors.white12),
          const SizedBox(height: 16),
          Text(
            'No contacts yet',
            style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white54),
          ),
          const SizedBox(height: 8),
          Text(
            'Add someone via QR or Ghost ID',
            style: GoogleFonts.inter(fontSize: 13, color: Colors.white30),
          ),
        ],
      ).animate().fadeIn(duration: 600.ms),
    );
  }

  Widget _buildContactList(ColorScheme cs) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: _contacts.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (ctx, i) {
        final c = _contacts[i];
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: cs.primary.withOpacity(0.15),
            child: Text(
              c.displayName[0].toUpperCase(),
              style: GoogleFonts.inter(fontWeight: FontWeight.w700, color: cs.primary),
            ),
          ),
          title: Text(
            c.displayName,
            style: GoogleFonts.inter(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            c.shortId,
            style: GoogleFonts.robotoMono(fontSize: 10, color: Colors.white38),
          ),
          trailing: c.verified
              ? Icon(Icons.verified_rounded, color: cs.primary, size: 18)
              : Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 18),
          tileColor: const Color(0xFF111318),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          onTap: () => Navigator.push(
            ctx,
            MaterialPageRoute(builder: (_) => ChatScreen(contact: c)),
          ),
        ).animate().fadeIn(delay: Duration(milliseconds: i * 50)).slideX(begin: 0.05);
      },
    );
  }

  void _showAddContactSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF111318),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 40, height: 4, decoration: BoxDecoration(
                color: Colors.white24, borderRadius: BorderRadius.circular(2),
              )),
              const SizedBox(height: 20),
              Text('Add Contact', style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 24),
              _BottomSheetOption(
              icon:  Icons.qr_code_scanner_rounded,
              label: 'Scan QR Code',
              sub:   'Nearby contact',
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(context, MaterialPageRoute(builder: (_) => const QrScannerScreen()))
                    .then((_) => _loadContacts());
              },
            ),
            const SizedBox(height: 12),
            _BottomSheetOption(
              icon:  Icons.fingerprint_rounded,
              label: 'Enter Ghost ID',
              sub:   'Remote contact',
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(context, MaterialPageRoute(builder: (_) => const AddByIdScreen()))
                    .then((_) => _loadContacts());
              },
            ),
            const SizedBox(height: 12),
            _BottomSheetOption(
              icon:  Icons.qr_code_rounded,
              label: 'Share my Ghost ID',
              sub:   'QR code or link — anytime',
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(context, MaterialPageRoute(builder: (_) => const GhostIdScreen()));
              },
            ),
            const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomSheetOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sub;
  final VoidCallback onTap;
  const _BottomSheetOption({required this.icon, required this.label, required this.sub, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color:        Colors.white.withOpacity(0.04),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          children: [
            Icon(icon, color: cs.primary, size: 28),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 15)),
                Text(sub,   style: GoogleFonts.inter(color: Colors.white38, fontSize: 12)),
              ],
            ),
            const Spacer(),
            const Icon(Icons.chevron_right_rounded, color: Colors.white30),
          ],
        ),
      ),
    );
  }
}
