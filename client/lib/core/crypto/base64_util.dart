// lib/core/crypto/base64_util.dart
// Safe base64 for untrusted input (QR, relay payloads). Dart's base64Decode
// requires length multiple of 4; many encodings omit padding.

import 'dart:convert';
import 'dart:typed_data';

/// Ensures [input] length is a multiple of 4 by appending '=' as needed.
/// Use before base64Decode when input may be unpadded (e.g. from QR or relay).
String base64Pad(String input) {
  if (input.isEmpty) return input;
  final remainder = input.length % 4;
  if (remainder == 0) return input;
  return input + ('=' * (4 - remainder));
}

/// Decodes base64 after padding. Use for untrusted input to avoid FormatException.
/// Throws FormatException if padding-normalized string is still invalid.
Uint8List safeBase64Decode(String input) {
  return base64Decode(base64Pad(input));
}
