// lib/models/message.dart
// Immutable message model used across layers (DB, UI, WebSocket).

import 'dart:convert';

enum MessageType { preKey, signal, group }
enum MessageStatus { sending, sent, delivered, read }

class GhostMessage {
  final String id;
  final String conversationId;
  final String senderId;
  final String ciphertext;       // base64 Signal ciphertext — never decrypted here
  final MessageType msgType;
  final bool isEphemeral;
  final int ttlSeconds;
  final int createdAt;           // unix ms
  final int? deleteAt;           // unix ms; null = on-read-triggered
  final bool viewOnce;
  final bool isRead;
  final MessageStatus status;
  final String? mediaType;       // 'image' | 'video' | null (text only)
  /// 1 = ciphertext not yet decrypted successfully (incoming from relay).
  final int decryptPending;
  final int decryptAttempts;
  final String? lastDecryptError;
  /// 1 = duplicate/consumed prekey etc.; do not retry blindly.
  final int decryptPermanentFail;
  /// Cleartext for UI only; stored inside SQLCipher (survives process / hot restart).
  final String? bodyPlaintext;

  const GhostMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.ciphertext,
    required this.msgType,
    this.isEphemeral      = true,
    this.ttlSeconds       = 3600,
    required this.createdAt,
    this.deleteAt,
    this.viewOnce         = false,
    this.isRead           = false,
    this.status           = MessageStatus.sending,
    this.mediaType,
    this.decryptPending = 0,
    this.decryptAttempts = 0,
    this.lastDecryptError,
    this.decryptPermanentFail = 0,
    this.bodyPlaintext,
  });

  Map<String, dynamic> toDbMap() => {
    'id':              id,
    'conversation_id': conversationId,
    'sender_id':       senderId,
    'ciphertext':      ciphertext,
    'msg_type':        msgType.index,
    'is_read':         isRead ? 1 : 0,
    'is_ephemeral':    isEphemeral ? 1 : 0,
    'ttl_seconds':     ttlSeconds,
    'created_at':      createdAt,
    'delete_at':       deleteAt,
    'view_once':       viewOnce ? 1 : 0,
    'status':          status.index,
    'decrypt_pending':      decryptPending,
    'decrypt_attempts':     decryptAttempts,
    'last_decrypt_error':   lastDecryptError,
    'decrypt_permanent_fail': decryptPermanentFail,
    'body_plaintext': bodyPlaintext,
  };

  factory GhostMessage.fromDbMap(Map<String, dynamic> m) => GhostMessage(
    id:             m['id'] as String,
    conversationId: m['conversation_id'] as String,
    senderId:       m['sender_id'] as String,
    ciphertext:     m['ciphertext'] as String,
    msgType:        MessageType.values[m['msg_type'] as int],
    isRead:        (m['is_read'] as int) == 1,
    isEphemeral:   (m['is_ephemeral'] as int) == 1,
    ttlSeconds:     m['ttl_seconds'] as int,
    createdAt:      m['created_at'] as int,
    deleteAt:       m['delete_at'] as int?,
    viewOnce:      (m['view_once'] as int) == 1,
    status:         MessageStatus.values[m['status'] as int? ?? 1],
    decryptPending: (m['decrypt_pending'] as int?) ?? 0,
    decryptAttempts: (m['decrypt_attempts'] as int?) ?? 0,
    lastDecryptError: m['last_decrypt_error'] as String?,
    decryptPermanentFail: (m['decrypt_permanent_fail'] as int?) ?? 0,
    bodyPlaintext: m['body_plaintext'] as String?,
  );

  Map<String, dynamic> toRelayPacket(String toUserId) => {
    'id':          id, // Nonce for relay server replay protection
    'to':          toUserId,
    'ciphertext':  ciphertext,
    'ttl_seconds': ttlSeconds,
    'msg_type':    msgType.index == 0 ? 'prekey' : (msgType == MessageType.group ? 'group' : 'signal'),
  };

  GhostMessage copyWith({
    MessageStatus? status,
    bool? isRead,
    int? deleteAt,
    int? decryptPending,
    int? decryptAttempts,
    String? lastDecryptError,
    int? decryptPermanentFail,
    String? bodyPlaintext,
  }) =>
    GhostMessage(
      id:             id,
      conversationId: conversationId,
      senderId:       senderId,
      ciphertext:     ciphertext,
      msgType:        msgType,
      isEphemeral:    isEphemeral,
      ttlSeconds:     ttlSeconds,
      createdAt:      createdAt,
      deleteAt:       deleteAt ?? this.deleteAt,
      viewOnce:       viewOnce,
      isRead:         isRead  ?? this.isRead,
      status:         status  ?? this.status,
      mediaType:      mediaType,
      decryptPending: decryptPending ?? this.decryptPending,
      decryptAttempts: decryptAttempts ?? this.decryptAttempts,
      lastDecryptError: lastDecryptError ?? this.lastDecryptError,
      decryptPermanentFail: decryptPermanentFail ?? this.decryptPermanentFail,
      bodyPlaintext: bodyPlaintext ?? this.bodyPlaintext,
    );
}
