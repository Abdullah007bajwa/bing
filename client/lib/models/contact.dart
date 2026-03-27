// lib/models/contact.dart

class GhostContact {
  final String userId;
  final String publicKeyB64;
  final String fingerprint;
  final String? nickname;        // local only, never synced
  final bool verified;
  final int addedAt;             // unix ms
  final int? lastMessageAt;      // unix ms; null = never chatted
  final int chatTtlSeconds;      // per-chat default disappearing timer

  const GhostContact({
    required this.userId,
    required this.publicKeyB64,
    required this.fingerprint,
    this.nickname,
    this.verified = false,
    required this.addedAt,
    this.lastMessageAt,
    this.chatTtlSeconds = 3600,
  });

  Map<String, dynamic> toDbMap() => {
    'user_id':        userId,
    'public_key_b64': publicKeyB64,
    'nickname':       nickname,
    'fingerprint':    fingerprint,
    'verified':       verified ? 1 : 0,
    'added_at':       addedAt,
    'last_message_at': lastMessageAt,
    'chat_ttl_seconds': chatTtlSeconds,
  };

  factory GhostContact.fromDbMap(Map<String, dynamic> m) => GhostContact(
    userId:       m['user_id']        as String,
    publicKeyB64: m['public_key_b64'] as String,
    nickname:     m['nickname']       as String?,
    fingerprint:  m['fingerprint']    as String,
    verified:    (m['verified']       as int) == 1,
    addedAt:      m['added_at']       as int,
    lastMessageAt: m['last_message_at'] as int?,
    chatTtlSeconds: (m['chat_ttl_seconds'] as int?) ?? 3600,
  );

  String get displayName => nickname ?? userId.substring(0, 12);
  String get shortId     => '${userId.substring(0, 8)}...${userId.substring(userId.length - 6)}';

  GhostContact copyWith({
    String? nickname,
    bool? verified,
    int? lastMessageAt,
    int? chatTtlSeconds,
  }) => GhostContact(
    userId:       userId,
    publicKeyB64: publicKeyB64,
    fingerprint:  fingerprint,
    nickname:     nickname    ?? this.nickname,
    verified:     verified    ?? this.verified,
    addedAt:      addedAt,
    lastMessageAt: lastMessageAt ?? this.lastMessageAt,
    chatTtlSeconds: chatTtlSeconds ?? this.chatTtlSeconds,
  );
}
