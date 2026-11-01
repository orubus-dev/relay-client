// Cross-engine regression test for the zero-knowledge sync vault.
//
// The fixture JSON was produced by scripts/make_sync_vault_fixtures.js —
// the EXACT algorithm of the web client (src/lib/sync/vaultCrypto.ts on the
// Relay web repo): PBKDF2-SHA-256 650k, AES-256-GCM (ct||tag), ephemeral
// ECDH P-256 + HKDF-SHA-256 share channel. These fixtures must keep opening
// byte-for-byte in Dart — that is what makes one passphrase work on both
// platforms (web + Android/Windows).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../lib/data/sync/vault_crypto.dart';

bool _eq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void main() {
  final f = jsonDecode(
          File('test/fixtures/sync_vault_web_fixtures.json').readAsStringSync())
      as Map<String, dynamic>;

  test('PBKDF2 wrap key is byte-identical to the web client', () async {
    final wrapKey = await derivePassphraseWrapKey(
        f['passphrase'] as String, unb64(f['salt_b64'] as String));
    expect(_eq(wrapKey, unb64(f['wrap_key_raw_b64'] as String)), isTrue);
  });

  test('web-sealed universal key opens in Dart', () async {
    final wrapKey = await derivePassphraseWrapKey(
        f['passphrase'] as String, unb64(f['salt_b64'] as String));
    final uk = await aesDecrypt(wrapKey, unb64(f['uk_iv_b64'] as String),
        unb64(f['uk_box_b64'] as String));
    expect(_eq(uk, unb64(f['uk_b64'] as String)), isTrue);

    // Dart seal must round-trip in the web wire format (iv || ct||tag).
    final iv = Uint8List.fromList(List.filled(12, 7));
    final box = await aesEncrypt(wrapKey, uk, iv);
    expect(_eq(await aesDecrypt(wrapKey, iv, box), uk), isTrue);
  });

  test('ECDH P-256 + HKDF share channel opens web-wrapped space keys',
      () async {
    final (priv, _) =
        ecdhPairFromJwk(Map<String, dynamic>.from(f['vault_priv_jwk'] as Map));
    final peer =
        ecPubFromJwk(Map<String, dynamic>.from(f['eph_pub_jwk'] as Map));
    final channel = await channelKeyBytes(priv, peer);
    final sk = await aesDecrypt(channel, unb64(f['share_iv_b64'] as String),
        unb64(f['sk_wrap_b64'] as String));
    expect(_eq(sk, unb64(f['space_key_b64'] as String)), isTrue);

    // A Dart-side ephemeral JWK must have the exact web shape.
    final eph = newEcdhJwk();
    expect(eph['kty'], 'EC');
    expect(eph['crv'], 'P-256');
    expect((eph['x'] as String).length, 43); // 32 bytes base64url, no padding
    expect((eph['y'] as String).length, 43);
    expect((eph['d'] as String).length, 43);

    // And a Dart-wrapped share must decrypt back to the same space key.
    final (ephPriv, _) = ecdhPairFromJwk(eph);
    final vaultPub =
        ecPubFromJwk(Map<String, dynamic>.from(f['vault_pub_jwk'] as Map));
    final dartChannel = await channelKeyBytes(ephPriv, vaultPub);
    final iv = Uint8List.fromList(List.filled(12, 9));
    final wrapped = await aesEncrypt(dartChannel, sk, iv);
    final unwrapped = await aesDecrypt(dartChannel, iv, wrapped);
    expect(_eq(unwrapped, sk), isTrue);
  });

  test('record envelope (RK/SK) opens web-sealed payloads', () async {
    final sk = unb64(f['space_key_b64'] as String);
    final rk = await aesDecrypt(
        sk, unb64(f['rk_iv_b64'] as String), unb64(f['rk_box_b64'] as String));
    final plain = await aesDecrypt(rk, unb64(f['rec_iv_b64'] as String),
        unb64(f['rec_box_b64'] as String));
    final payload = jsonDecode(utf8.decode(plain)) as Map;
    expect(payload['hello'], 'world');
    expect(payload['n'], 42);
    expect(payload['web'], true);
  });

  test('PBKDF2 650k completes in reasonable time (pure Dart)', () async {
    final sw = Stopwatch()..start();
    await derivePassphraseWrapKey(
        f['passphrase'] as String, unb64(f['salt_b64'] as String));
    expect(sw.elapsed.inSeconds, lessThan(30));
  });
}
