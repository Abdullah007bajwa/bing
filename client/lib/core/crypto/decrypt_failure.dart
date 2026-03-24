// Classification for Signal decrypt errors (retry vs permanent vs ratchet order).

enum DecryptFailureType {
  staleSession,
  badMac,
  duplicatePrekey,
  unknown,
}

DecryptFailureType classifyDecryptError(Object e) {
  final s = e.toString().toLowerCase();
  if (s.contains('duplicate')) return DecryptFailureType.duplicatePrekey;
  if (s.contains('bad mac') ||
      s.contains('badmac') ||
      s.contains('mac is invalid') ||
      s.contains('invalid mac') ||
      s.contains('authentication') ||
      s.contains('integrity') ||
      s.contains('invalidmessage') ||
      s.contains('invalid message')) {
    return DecryptFailureType.badMac;
  }
  if (s.contains('no valid sessions') ||
      s.contains('no session') ||
      s.contains('unknown session')) {
    return DecryptFailureType.staleSession;
  }
  return DecryptFailureType.unknown;
}

/// Thrown when decrypt cannot complete; [retryLater] means another message may advance the ratchet.
class DecryptException implements Exception {
  DecryptException(
    this.failureType, {
    required this.message,
    this.permanentFailure = false,
    this.retryLater = false,
  });

  final DecryptFailureType failureType;
  final String message;
  final bool permanentFailure;
  final bool retryLater;

  @override
  String toString() =>
      'DecryptException($failureType, permanent=$permanentFailure, retryLater=$retryLater): $message';
}

/// Encrypt failed while a Signal session row already existed locally.
/// The UI/relay layer should notify the peer, clear local state, and retry
/// outbound X3DH once (bilateral reset — no manual session file deletion).
class SessionDesyncException implements Exception {
  SessionDesyncException(this.cause);
  final Object cause;

  @override
  String toString() => 'SessionDesyncException: $cause';
}
