import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';

void main() async {
  print('Resolving SSL certificate for bing-2iqr.onrender.com...');
  
  try {
    final client = HttpClient();
    
    client.badCertificateCallback = (X509Certificate cert, String host, int port) {
       print('\n--- CERTIFICATE HASH START ---');
       // Android pinning explicitly requires the SHA-256 hash of the 
       // SubjectPublicKeyInfo (SPKI) ASN.1 structure, NOT the whole certificate DER.
       // Without PointyCastle here, we will just print the entire base64 DER 
       // so the user can easily extract the SPKI from it online.
       
       print('RAW CERTIFICATE (Base64 DER):');
       print(base64.encode(cert.der));
       print('--- CERTIFICATE HASH END ---\n');
       
       return false;
    };
    
    final request = await client.getUrl(Uri.parse('https://bing-2iqr.onrender.com'));
    await request.close();
    
  } catch (e) {
    if (e.toString().contains('CERTIFICATE_VERIFY_FAILED') || e.toString().contains('HandshakeException')) {
       print('Extraction complete.');
    } else {
       print('Error: \$e');
    }
  }
}
