// lib/core/crypto/onion_router.dart
// Implements multi-hop Onion Routing payload wrapping: E3(E2(E1(msg)))
// This provides network anonymity, obscuring sender/recipient metadata from ISPs and Relays.

import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

class OnionRelayNode {
  final String ip;
  final SimplePublicKey publicKey; // X25519 public key of the relay
  
  OnionRelayNode(this.ip, this.publicKey);
}

class OnionRouter {
  static final _x25519 = X25519();
  static final _chacha20 = Chacha20.poly1305Aead();

  /// Wraps a Signal ciphertext payload into multiple AES-GCM/Chacha20 layers.
  /// Each layer contains the routing instruction for the *next* hop, and the encrypted remaining payload.
  /// 
  /// Format of each unwrapped layer:
  /// {
  ///    "next_hop": "198.51.100.2" (or recipient ID for final hop),
  ///    "payload": "<nested_ciphertext or final_signal_ciphertext>"
  /// }
  static Future<String> wrapPayload({
    required String finalSignalCiphertext,
    required String finalRecipientId,
    required List<OnionRelayNode> circuit,
  }) async {
    if (circuit.isEmpty) {
      return finalSignalCiphertext; // Fallback to direct routing if no circuit
    }

    String currentPayload = finalSignalCiphertext;
    String currentNextHop = finalRecipientId;

    // Wrap from the inside out (Loop backwards through the circuit)
    // Relay 3 -> Relay 2 -> Relay 1
    for (int i = circuit.length - 1; i >= 0; i--) {
      final node = circuit[i];
      
      // The instruction for THIS node
      final instruction = jsonEncode({
        'next_hop': currentNextHop,
        'payload': currentPayload,
      });

      // 1. Generate ephemeral keypair for this hop
      final ephemeralKp = await _x25519.newKeyPair();
      final ephemeralPub = await ephemeralKp.extractPublicKey();

      // 2. Perform ECDH to get shared secret with this specific relay
      final sharedSecret = await _x25519.sharedSecretKey(
        keyPair: ephemeralKp,
        remotePublicKey: node.publicKey,
      );

      // 3. Encrypt the instruction
      final secretBox = await _chacha20.encrypt(
        utf8.encode(instruction),
        secretKey: sharedSecret,
      );

      // 4. The new payload is the combination of the ephemeral pubkey + ciphertext
      // The relay needs our ephemeral pubkey to compute the same shared secret!
      final bundle = {
        'ephemeral_key': base64Encode(ephemeralPub.bytes),
        'nonce':         base64Encode(secretBox.nonce),
        'mac':           base64Encode(secretBox.mac.bytes),
        'ciphertext':    base64Encode(secretBox.cipherText),
      };

      currentPayload = base64Encode(utf8.encode(jsonEncode(bundle)));
      
      // The next hop for the PREVIOUS loop iteration is THIS node's IP
      currentNextHop = node.ip;
    }

    // The final currentPayload is E1(E2(E3(message)))
    // To be sent to circuit[0] (Entry Node)
    return currentPayload;
  }

  /// Unwraps the outermost layer of an Onion packet.
  /// (This simulates what a Relay Node does when receiving a packet).
  static Future<Map<String, String>> unwrapPayload({
    required String relayCiphertext,
    required SimpleKeyPair relayPrivateKey,
  }) async {
    final bundle = jsonDecode(utf8.decode(base64Decode(relayCiphertext))) as Map<String, dynamic>;
    
    final ephemeralPubBytes = base64Decode(bundle['ephemeral_key'] as String);
    final ephemeralPub      = SimplePublicKey(ephemeralPubBytes, type: KeyPairType.x25519);
    
    final nonceBytes = base64Decode(bundle['nonce'] as String);
    final macBytes   = base64Decode(bundle['mac'] as String);
    final cipherText = base64Decode(bundle['ciphertext'] as String);

    // 1. Compute shared secret using the Relay's private key and Sender's ephemeral public key
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: relayPrivateKey,
      remotePublicKey: ephemeralPub,
    );

    // 2. Decrypt the box
    final secretBox = SecretBox(
      cipherText,
      nonce: nonceBytes,
      mac: Mac(macBytes),
    );

    final cleartextBytes = await _chacha20.decrypt(
      secretBox,
      secretKey: sharedSecret,
    );

    final instruction = jsonDecode(utf8.decode(cleartextBytes)) as Map<String, dynamic>;

    return {
      'next_hop': instruction['next_hop'] as String,
      'payload':  instruction['payload'] as String,
    };
  }
}
