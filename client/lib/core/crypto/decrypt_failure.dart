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
  if (s.contains('bad mac')) return DecryptFailureType.badMac;
  if (s.contains('no valid sessions')) return DecryptFailureType.staleSession;
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
