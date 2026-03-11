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
  );

  Map<String, dynamic> toRelayPacket(String toUserId) => {
    'id':          id, // Nonce for relay server replay protection
    'to':          toUserId,
    'ciphertext':  ciphertext,
    'ttl_seconds': ttlSeconds,
    'msg_type':    msgType.index == 0 ? 'prekey' : (msgType == MessageType.group ? 'group' : 'signal'),
  };

  GhostMessage copyWith({MessageStatus? status, bool? isRead, int? deleteAt}) =>
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
    );
}
