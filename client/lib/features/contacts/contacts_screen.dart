// lib/features/contacts/contacts_screen.dart
// Main home screen: list of contacts (chats).
// Add via QR scan or paste ID. All contacts stored locally in SQLCipher.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../core/storage/secure_db.dart';
import '../../core/identity/identity_service.dart';
import '../../relay/relay_coordinator.dart';
import '../../models/contact.dart';
import '../../app_config.dart';
import '../chat/chat_screen.dart';
import 'qr_scanner_screen.dart';
import 'add_by_id_screen.dart';
import '../settings/ghost_id_screen.dart';
import '../settings/settings_screen.dart';
import '../../widgets/vexa_brand_mark.dart';
import '../../core/theme/vexa_colors.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final _db = SecureDb();
  List<GhostContact> _contacts = [];
  bool _loading = true;
  StreamSubscription<String>? _incomingSub;

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

    // Live refresh when a new packet/contact arrives (no restart needed)
    _incomingSub ??= RelayCoordinator().incomingNotify.listen((_) {
      _loadContacts();
    });
  }

  @override
  void dispose() {
    _incomingSub?.cancel();
    super.dispose();
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
            const VexaAppBarTitle(iconSize: 28),
            const SizedBox(width: 10),
            Text(
              'Chats',
              style: GoogleFonts.inter(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
                color: cs.primary,
              ),
            ),
          ],
        ),
        centerTitle: true,
        automaticallyImplyLeading: false,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(Icons.settings_rounded, color: cs.primary, size: 24),
            tooltip: 'Settings',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ).then((_) => _loadContacts()),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 8),
            _buildAddContactRow(cs),
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _contacts.isEmpty
                      ? _buildEmptyState(cs)
                      : _buildContactList(cs),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _buildAddContactRow(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: InkWell(
        onTap: _showAddContactSheet,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: cs.primary.withValues(alpha: 0.35)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_rounded, color: cs.primary, size: 18),
              const SizedBox(width: 10),
              Text(
                'New Contact',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: VexaColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
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
            'Add someone via QR or Vexa ID',
            style: GoogleFonts.inter(fontSize: 13, color: Colors.white30),
          ),
        ],
      ).animate().fadeIn(duration: 600.ms),
    );
  }

  Widget _buildContactList(ColorScheme cs) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: _contacts.length,
      separatorBuilder: (_, __) => Divider(
        height: 1,
        thickness: 1,
        color: VexaColors.divider,
        indent: 72,
        endIndent: 16,
      ),
      itemBuilder: (ctx, i) {
        final c = _contacts[i];
        final timeLabel = _formatTimestamp(c.lastMessageAt);
        return ListTile(
          leading: CircleAvatar(
            radius: 22,
            backgroundColor:
                VexaColors.textSecondary.withValues(alpha: 0.12),
            child: const Icon(Icons.person_rounded, color: VexaColors.textSecondary, size: 18),
          ),
          title: Text(
            c.displayName,
            style: GoogleFonts.inter(
              fontWeight: FontWeight.w600,
              color: VexaColors.textPrimary,
            ),
          ),
          subtitle: Text(
            c.shortId,
            style: GoogleFonts.inter(
              fontSize: 13,
              color: VexaColors.textSecondary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                timeLabel,
                textAlign: TextAlign.right,
                style: GoogleFonts.inter(
                  color: VexaColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          tileColor: VexaColors.background,
          onLongPress: () => _editContactName(ctx, c),
          onTap: () => Navigator.push(
            ctx,
            MaterialPageRoute(builder: (_) => ChatScreen(contact: c)),
          ).then((_) => _loadContacts()),
        ).animate().fadeIn(delay: Duration(milliseconds: i * 50)).slideX(begin: 0.05);
      },
    );
  }

  String _formatTimestamp(int? unixMs) {
    if (unixMs == null) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(unixMs);
    final now = DateTime.now();
    final isSameDay = dt.year == now.year && dt.month == now.month && dt.day == now.day;
    if (isSameDay) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')}';
  }

  Future<void> _editContactName(BuildContext context, GhostContact c) async {
    final controller = TextEditingController(text: c.nickname ?? '');
    final cs = Theme.of(context).colorScheme;

    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF111318),
        title: Text('Edit contact name', style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: GoogleFonts.inter(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Nickname (optional)',
            hintStyle: GoogleFonts.inter(color: Colors.white38),
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(color: cs.primary.withValues(alpha: 0.25)),
              borderRadius: BorderRadius.circular(12),
            ),
            focusedBorder: OutlineInputBorder(
              borderSide: BorderSide(color: cs.primary.withValues(alpha: 0.6)),
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: Text('Cancel', style: GoogleFonts.inter(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ''),
            child: Text('Clear', style: GoogleFonts.inter(color: cs.error)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: cs.primary, foregroundColor: const Color(0xFF0A0B0D)),
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text('Save', style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );

    if (result == null) return; // cancel
    await _db.updateContactNickname(c.userId, result);
    await _loadContacts();
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
              label: 'Enter Vexa ID',
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
              label: 'Share my Vexa ID',
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
        color:        Colors.white.withValues(alpha: 0.04),
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
