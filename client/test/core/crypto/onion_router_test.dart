import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';
import '../../../lib/core/crypto/onion_router.dart';

void main() {
  group('Onion Routing E3(E2(E1(msg)))', () {
    test('Should wrap and unwrap a message through 3 simulated relay nodes', () async {
      final x25519 = X25519();

      // 1. Generate 3 "Relay" keypairs (simulating 3 separate servers)
      final relay1Kp = await x25519.newKeyPair();
      final relay1Pub = await relay1Kp.extractPublicKey();

      final relay2Kp = await x25519.newKeyPair();
      final relay2Pub = await relay2Kp.extractPublicKey();

      final relay3Kp = await x25519.newKeyPair();
      final relay3Pub = await relay3Kp.extractPublicKey();

      // The circuit path: Client -> Relay 1 -> Relay 2 -> Relay 3 -> Bob
      final circuit = [
        OnionRelayNode('relay1.ghost.net', relay1Pub),
        OnionRelayNode('relay2.ghost.net', relay2Pub),
        OnionRelayNode('relay3.ghost.net', relay3Pub),
      ];

      const originalMessage = "base64_signal_ciphertext_payload";
      const finalRecipientId = "bob_user_id";

      // 2. Wrap the payload (Client Side)
      final onionPacket = await OnionRouter.wrapPayload(
        finalSignalCiphertext: originalMessage,
        finalRecipientId: finalRecipientId,
        circuit: circuit,
      );

      expect(onionPacket, isNot(originalMessage));
      expect(onionPacket.contains(originalMessage), isFalse); // Proven ciphertext obscures everything

      // 3. Unwrap Layer 1 (Relay 1 Side)
      final layer1Unwrapped = await OnionRouter.unwrapPayload(
        relayCiphertext: onionPacket,
        relayPrivateKey: relay1Kp,
      );
      expect(layer1Unwrapped['next_hop'], 'relay2.ghost.net'); // Correctly routes to node 2

      // 4. Unwrap Layer 2 (Relay 2 Side)
      final layer2Unwrapped = await OnionRouter.unwrapPayload(
        relayCiphertext: layer1Unwrapped['payload']!,
        relayPrivateKey: relay2Kp,
      );
      expect(layer2Unwrapped['next_hop'], 'relay3.ghost.net'); // Correctly routes to node 3

      // 5. Unwrap Layer 3 (Relay 3 Side - Exit Node)
      final layer3Unwrapped = await OnionRouter.unwrapPayload(
        relayCiphertext: layer2Unwrapped['payload']!,
        relayPrivateKey: relay3Kp,
      );
      expect(layer3Unwrapped['next_hop'], finalRecipientId); // Routes to Bob
      expect(layer3Unwrapped['payload'], originalMessage); // Payload is the pristine Signal ciphertext!
    });
  });
}
