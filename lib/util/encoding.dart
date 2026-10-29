import 'dart:convert';
import 'dart:typed_data';

/// base64url without padding — byte-identical to the web client's `b64u`.
class B64u {
  static String encode(List<int> bytes) {
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static Uint8List decode(String s) {
    final normalized = base64Url.normalize(s);
    return base64Url.decode(normalized);
  }
}

String utf8str(List<int> bytes) => utf8.decode(bytes);

Uint8List utf8bytes(String s) => Uint8List.fromList(utf8.encode(s));
