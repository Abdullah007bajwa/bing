// lib/core/contacts/contact_establishment_service.dart
// Sends an automated encrypted message when a contact is added so the recipient
// receives it and the conversation is established on their side (they see the contact).

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:uuid/uuid.dart';
import '../identity/identity_service.dart';
import '../crypto/signal_session.dart';
import '../../relay/relay_coordinator.dart';
import '../../app_config.dart';
import '../../models/contact.dart';

/// System message body sent when user A adds user B — B receives it and sees A in their list.
const String kContactEstablishmentMessage =
    'Contact added. You can start chatting.';

class ContactEstablishmentService {
  static final ContactEstablishmentService _instance =
      ContactEstablishmentService._();
  factory ContactEstablishmentService() => _instance;
  ContactEstablishmentService._();

  final _identity = IdentityService();
  final _signal = SignalSessionService();
  final _uuid = const Uuid();

  /// Sends one encrypted "contact established" message to the given contact
  /// so they receive it and the conversation appears on their device.
  /// Returns true if sent (or relay not connected is non-fatal; returns false).
  Future<bool> sendContactEstablishmentMessage(GhostContact contact) async {
    final kp = await _identity.loadIdentityKeyPair();
    if (kp == null) return false;

    final store = InMemorySignalProtocolStore(kp, 1);
    SessionCipher cipher;
    try {
      cipher = await _signal.getOrCreateSession(
        contactUserId:      contact.userId,
        contactPublicKeyB64: contact.publicKeyB64,
        store:              store,
        deviceId:           1,
      );
    } catch (_) {
      return false;
    }

    final encrypted = await _signal.encryptMessage(
      cipher:   cipher,
      plaintext: kContactEstablishmentMessage,
    );

    final msgId = _uuid.v4();
    final relay = RelayCoordinator().relay;
    final sent = relay.sendPacket({
      'id':          msgId,
      'to':          contact.userId,
      'ciphertext':  encrypted['ciphertext'],
      'msg_type':    encrypted['type'] == 1 ? 'prekey' : 'signal',
      'ttl_seconds': AppConfig.defaultTtlSeconds,
    });

    _signal.evictSession(contact.userId);
    return sent;
  }
}
