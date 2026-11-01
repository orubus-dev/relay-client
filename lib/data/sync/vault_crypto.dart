import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/export.dart' as pc;

/// Zero-knowledge sync vault crypto for Relay (Dart side).
///
/// Byte-compatible with the web client (src/lib/sync/vaultCrypto.ts):
///   - storage fields use STANDARD base64 (btoa), padded
///   - AES-256-GCM records store ciphertext||tag; the IV is stored alongside
///   - passphrase wrap = PBKDF2-SHA-256, 650k iterations, per-user salt
///   - share channel  = ephemeral ECDH P-256 + HKDF-SHA-256
///     (salt = info = 'relay-sync-share-v1')
///
/// The server only ever sees wrapped keys and ciphertext.

const int pbkdf2Iterations = 650000;
const String hkdfInfo = 'relay-sync-share-v1';

final AesGcm _aesGcm = AesGcm.with256bits();
final Pbkdf2 _pbkdf2 = Pbkdf2(
  macAlgorithm: Hmac.sha256(),
  iterations: pbkdf2Iterations,
  bits: 256,
);
final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

/// P-256 via pointycastle — package:cryptography's pure-Dart ECDH is
/// unimplemented (throws UnimplementedError) and Flutter desktop/Android
/// must not depend on a platform plugin for the vault to work.
final pc.ECDomainParameters _p256 = pc.ECDomainParameters('prime256v1');

BigInt _randomScalar() {
  final n = _p256.n;
  while (true) {
    final raw = randomBytes(32);
    final d = _bytesToBigInt(raw);
    if (d.sign > 0 && d < n) return d;
  }
}

BigInt _bytesToBigInt(List<int> bytes) => BigInt.parse(
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      radix: 16,
    );

Uint8List _bigIntTo32(BigInt x) {
  var hex = x.toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  if (hex.length < 64) hex = hex.padLeft(64, '0');
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

Uint8List randomBytes(int length) {
  final r = Random.secure();
  return Uint8List.fromList(List<int>.generate(length, (_) => r.nextInt(256)));
}

String b64(Uint8List bytes) => base64.encode(bytes);

Uint8List unb64(String s) => Uint8List.fromList(base64.decode(s));

String b64u(Uint8List bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List unb64u(String s) =>
    Uint8List.fromList(base64Url.decode(base64Url.normalize(s)));

// --------------------------------------------------------------- AES-GCM --

Future<Uint8List> aesEncrypt(
    Uint8List key, Uint8List plaintext, Uint8List iv) async {
  final box =
      await _aesGcm.encrypt(plaintext, secretKey: SecretKey(key), nonce: iv);
  // Web AES-GCM output = ciphertext || tag(16)
  return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
}

Future<Uint8List> aesDecrypt(
    Uint8List key, Uint8List iv, Uint8List ctAndTag) async {
  if (ctAndTag.length < 16) throw StateError('ciphertext too short');
  final cipherText = ctAndTag.sublist(0, ctAndTag.length - 16);
  final mac = Mac(ctAndTag.sublist(ctAndTag.length - 16));
  final plain = await _aesGcm.decrypt(
    SecretBox(cipherText, nonce: iv, mac: mac),
    secretKey: SecretKey(key),
  );
  return Uint8List.fromList(plain);
}

// ------------------------------------------------- passphrase wrap (UK) --

Future<Uint8List> derivePassphraseWrapKey(
    String passphrase, Uint8List salt) async {
  final key = await _pbkdf2.deriveKey(
    secretKey: SecretKey(utf8.encode(passphrase)),
    nonce: salt,
  );
  return Uint8List.fromList(await key.extractBytes());
}

// ------------------------------------------------------- ECDH share chan --

Uint8List _fixed32(List<int> component) {
  if (component.length == 32) return Uint8List.fromList(component);
  if (component.length > 32) {
    return Uint8List.fromList(component.sublist(component.length - 32));
  }
  final out = Uint8List(32);
  out.setRange(32 - component.length, 32, component);
  return out;
}

/// JWK for a fresh P-256 key pair ({x, y, d} base64url, web-compatible).
Map<String, dynamic> newEcdhJwk() {
  final d = _randomScalar();
  final q = _p256.G * d;
  return {
    'kty': 'EC',
    'crv': 'P-256',
    'x': b64u(_bigIntTo32(q!.x!.toBigInteger()!)),
    'y': b64u(_bigIntTo32(q!.y!.toBigInteger()!)),
    'd': b64u(_bigIntTo32(d)),
    'ext': true,
  };
}

/// Rebuild the full key pair from a JWK private scalar (recomputes x, y).
(pc.ECPrivateKey, pc.ECPublicKey) ecdhPairFromJwk(
    Map<String, dynamic> privJwk) {
  final d = _bytesToBigInt(unb64u(privJwk['d'] as String));
  final q = _p256.G * d;
  return (
    pc.ECPrivateKey(d, _p256),
    pc.ECPublicKey(q, _p256),
  );
}

pc.ECPublicKey ecPubFromJwk(Map<String, dynamic> jwk) {
  final x = _bytesToBigInt(unb64u(jwk['x'] as String));
  final y = _bytesToBigInt(unb64u(jwk['y'] as String));
  final q = _p256.curve.createPoint(x, y);
  return pc.ECPublicKey(q, _p256);
}

/// HKDF over an ECDH shared secret — same parameters as the web client.
Future<Uint8List> channelKeyBytes(
    pc.ECPrivateKey priv, pc.ECPublicKey peer) async {
  final agreement = pc.ECDHBasicAgreement()..init(priv);
  final shared = agreement.calculateAgreement(peer);
  final bits = _bigIntTo32(shared); // P-256 shared secret = X coordinate
  final key = await _hkdf.deriveKey(
    secretKey: SecretKey(bits),
    nonce: utf8.encode(hkdfInfo),
    info: utf8.encode(hkdfInfo),
  );
  return Uint8List.fromList(await key.extractBytes());
}

Future<Uint8List> sha256(Uint8List data) async =>
    Uint8List.fromList((await Sha256().hash(data)).bytes);
