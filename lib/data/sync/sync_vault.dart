import 'dart:convert';
import 'dart:typed_data';

import 'package:supabase/supabase.dart';

import 'vault_crypto.dart';

/// Encrypted cloud sync vault — high-level API (Dart side).
///
/// Byte-compatible with the web client (src/lib/sync/vault.ts); both write
/// the same tables and the same wire formats, so a vault created on web
/// unlocks on Android with the same passphrase and vice versa.
///
///   universal key (UK)  256-bit, born on-device, wrapped by PBKDF2(pass)
///   space key (SK)      one per space, wrapped by the UK
///   record key (RK)     fresh per write, wraps the record, wrapped by the SK
///   shares              SK re-wrapped through an ephemeral ECDH channel

enum VaultStatus { missing, locked, unlocked }

class VaultMeta {
  final VaultStatus status;
  final String? createdAt;
  final String? updatedAt;
  const VaultMeta({required this.status, this.createdAt, this.updatedAt});
}

class SyncVault {
  final SupabaseClient sb;
  final String profileId;

  Uint8List? _uk;
  final Map<String, Uint8List> _spaceKeys = {};

  SyncVault({required this.sb, required this.profileId});

  bool get isUnlocked => _uk != null;

  // ------------------------------------------------------------- helpers --

  Future<Map<String, dynamic>?> _vaultRow() async {
    final rows = await sb
        .from('sync_vaults')
        .select('user_id,kdf_salt,uk_wrap,wrap_iv,created_at,updated_at')
        .eq('user_id', profileId)
        .limit(1);
    final list = (rows as List).cast<Map<String, dynamic>>();
    return list.isEmpty ? null : list.first;
  }

  Uint8List get _requireUk {
    final uk = _uk;
    if (uk == null) throw StateError('Sync vault is locked — unlock it first.');
    return uk;
  }

  Future<Map<String, dynamic>?> _wrappedPrivateJwk() async {
    final rows = await sb
        .from('vault_private_keys')
        .select('priv_wrap,priv_wrap_iv')
        .eq('user_id', profileId)
        .limit(1);
    final list = (rows as List).cast<Map<String, dynamic>>();
    if (list.isEmpty) return null;
    final row = list.first;
    final raw = await aesDecrypt(
      _requireUk,
      unb64(row['priv_wrap_iv'] as String),
      unb64(row['priv_wrap'] as String),
    );
    return Map<String, dynamic>.from(jsonDecode(utf8.decode(raw)) as Map);
  }

  // --------------------------------------------------------------- setup --

  Future<void> setupVault(String passphrase) async {
    if (passphrase.length < 8) {
      throw StateError('Use a passphrase of at least 8 characters.');
    }
    if (await _vaultRow() != null) {
      throw StateError('A sync vault already exists on this account.');
    }

    final uk = randomBytes(32);
    final salt = randomBytes(16);
    final wrapKey = await derivePassphraseWrapKey(passphrase, salt);
    final ukIv = randomBytes(12);
    final ukBox = await aesEncrypt(wrapKey, uk, ukIv);

    await sb.from('sync_vaults').insert({
      'user_id': profileId,
      'kdf_salt': b64(salt),
      'uk_wrap': b64(ukBox),
      'wrap_iv': b64(ukIv),
    });

    // Vault keypair: publish the public half, wrap the private half with the UK.
    final privJwk = await newEcdhJwk();

    await sb.from('vault_pubkeys').upsert({
      'user_id': profileId,
      'pub_jwk': {
        'kty': 'EC',
        'crv': 'P-256',
        'x': privJwk['x'],
        'y': privJwk['y'],
        'ext': true,
      },
    });

    final privIv = randomBytes(12);
    final privBox =
        await aesEncrypt(uk, utf8.encode(jsonEncode(privJwk)), privIv);
    await sb.from('vault_private_keys').upsert({
      'user_id': profileId,
      'priv_wrap': b64(privBox),
      'priv_wrap_iv': b64(privIv),
    });

    _uk = uk;
    _spaceKeys.clear();
    await ensureSpaceKey('app_settings');
  }

  Future<void> unlockVault(String passphrase) async {
    final row = await _vaultRow();
    if (row == null) throw StateError('No sync vault on this account yet.');
    final wrapKey = await derivePassphraseWrapKey(
        passphrase, unb64(row['kdf_salt'] as String));
    final uk = await aesDecrypt(
      wrapKey,
      unb64(row['wrap_iv'] as String),
      unb64(row['uk_wrap'] as String),
    );
    _uk = uk;
    _spaceKeys.clear();
  }

  Future<void> lockVault() async {
    _uk = null;
    _spaceKeys.clear();
  }

  Future<void> changePassphrase(String oldPass, String newPass) async {
    if (newPass.length < 8) {
      throw StateError('Use a passphrase of at least 8 characters.');
    }
    final row = await _vaultRow();
    if (row == null) throw StateError('No sync vault on this account yet.');
    final oldWrap = await derivePassphraseWrapKey(
        oldPass, unb64(row['kdf_salt'] as String));
    final uk = await aesDecrypt(
      oldWrap,
      unb64(row['wrap_iv'] as String),
      unb64(row['uk_wrap'] as String),
    );
    final newSalt = randomBytes(16);
    final newWrap = await derivePassphraseWrapKey(newPass, newSalt);
    final newIv = randomBytes(12);
    final box = await aesEncrypt(newWrap, uk, newIv);
    await sb.from('sync_vaults').update({
      'kdf_salt': b64(newSalt),
      'uk_wrap': b64(box),
      'wrap_iv': b64(newIv),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('user_id', profileId);
    _uk = uk;
    _spaceKeys.clear();
  }

  Future<VaultMeta> getVaultMeta() async {
    final row = await _vaultRow();
    if (row == null) return const VaultMeta(status: VaultStatus.missing);
    return VaultMeta(
      status: isUnlocked ? VaultStatus.unlocked : VaultStatus.locked,
      createdAt: row['created_at'] as String?,
      updatedAt: row['updated_at'] as String?,
    );
  }

  /// True when the backend tables are not deployed yet.
  static bool isMissingTableError(Object error) {
    final t = '$error';
    return RegExp(
            'does not exist|schema cache|42P01|PGRST205|Could not find the table',
            caseSensitive: false)
        .hasMatch(t);
  }

  // ----------------------------------------------------------- space keys --

  Future<Uint8List> ensureSpaceKey(String space) async {
    final cached = _spaceKeys[space];
    if (cached != null) return cached;

    final rows = await sb
        .from('sync_space_keys')
        .select('space,sk_wrap,wrap_iv')
        .eq('user_id', profileId)
        .eq('space', space)
        .limit(1);
    final list = (rows as List).cast<Map<String, dynamic>>();
    if (list.isNotEmpty) {
      final row = list.first;
      final sk = await aesDecrypt(
        _requireUk,
        unb64(row['wrap_iv'] as String),
        unb64(row['sk_wrap'] as String),
      );
      _spaceKeys[space] = sk;
      return sk;
    }

    final sk = randomBytes(32);
    final iv = randomBytes(12);
    final box = await aesEncrypt(_requireUk, sk, iv);
    await sb.from('sync_space_keys').upsert({
      'user_id': profileId,
      'space': space,
      'sk_wrap': b64(box),
      'wrap_iv': b64(iv),
    });
    _spaceKeys[space] = sk;
    return sk;
  }

  // ---------------------------------------------------------- read/write --

  Future<void> vaultPut(String space, String recordId, Object payload) async {
    final sk = await ensureSpaceKey(space);
    final rk = randomBytes(32);
    final recordIv = randomBytes(12);
    final recordBox =
        await aesEncrypt(rk, utf8.encode(jsonEncode(payload)), recordIv);
    final rkIv = randomBytes(12);
    final rkBox = await aesEncrypt(sk, rk, rkIv);
    await sb.from('sync_blobs').upsert({
      'user_id': profileId,
      'space': space,
      'record_id': recordId,
      'iv': b64(recordIv),
      'ct': b64(recordBox),
      'rk_wrap': b64(rkBox),
      'rk_wrap_iv': b64(rkIv),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<dynamic> vaultGet(String space, String recordId) async {
    final rows = await sb
        .from('sync_blobs')
        .select('record_id,iv,ct,rk_wrap,rk_wrap_iv,updated_at')
        .eq('user_id', profileId)
        .eq('space', space)
        .eq('record_id', recordId)
        .limit(1);
    final list = (rows as List).cast<Map<String, dynamic>>();
    if (list.isEmpty) return null;
    final row = list.first;
    final sk = await ensureSpaceKey(space);
    final rk = await aesDecrypt(
      sk,
      unb64((row['rk_wrap_iv'] ?? row['iv']) as String),
      unb64(row['rk_wrap'] as String),
    );
    final plain = await aesDecrypt(
        rk, unb64(row['iv'] as String), unb64(row['ct'] as String));
    return jsonDecode(utf8.decode(plain));
  }

  // -------------------------------------------------------------- shares --

  Future<void> shareSpace(String space, String recipientId) async {
    if (recipientId == profileId)
      throw StateError('That is already your space.');
    final pubRows = await sb
        .from('vault_pubkeys')
        .select('pub_jwk')
        .eq('user_id', recipientId)
        .limit(1);
    final pubList = (pubRows as List).cast<Map<String, dynamic>>();
    if (pubList.isEmpty) {
      throw StateError('That account has not enabled encrypted sync yet.');
    }
    final sk = await ensureSpaceKey(space);
    final ephJwk = await newEcdhJwk();
    final (ephPriv, _) = ecdhPairFromJwk(ephJwk);
    final peer = ecPubFromJwk(
        Map<String, dynamic>.from(pubList.first['pub_jwk'] as Map));
    final channel = await channelKeyBytes(ephPriv, peer);
    final iv = randomBytes(12);
    final box = await aesEncrypt(channel, sk, iv);
    await sb.from('sync_space_shares').upsert({
      'space_owner': profileId,
      'space': space,
      'recipient_id': recipientId,
      'ephemeral_pub_jwk': {
        'kty': 'EC',
        'crv': 'P-256',
        'x': ephJwk['x'],
        'y': ephJwk['y'],
        'ext': true,
      },
      'sk_wrap': b64(box),
      'wrap_iv': b64(iv),
    });
  }

  /// Open a record from a space shared with me.
  Future<dynamic> openShared(
      String ownerId, String space, String recordId) async {
    final shareRows = await sb
        .from('sync_space_shares')
        .select('ephemeral_pub_jwk,sk_wrap,wrap_iv')
        .eq('space_owner', ownerId)
        .eq('space', space)
        .eq('recipient_id', profileId)
        .limit(1);
    final shares = (shareRows as List).cast<Map<String, dynamic>>();
    if (shares.isEmpty)
      throw StateError('No share of that space addressed to you.');
    final share = shares.first;
    final privJwk = await _wrappedPrivateJwk();
    if (privJwk == null)
      throw StateError('This account has no vault keypair yet.');
    final (myPriv, _) = ecdhPairFromJwk(privJwk);
    final ephemeralPub = ecPubFromJwk(
        Map<String, dynamic>.from(share['ephemeral_pub_jwk'] as Map));
    final channel = await channelKeyBytes(myPriv, ephemeralPub);
    final sk = await aesDecrypt(
      channel,
      unb64(share['wrap_iv'] as String),
      unb64(share['sk_wrap'] as String),
    );

    final blobRows = await sb
        .from('sync_blobs')
        .select('iv,ct,rk_wrap,rk_wrap_iv')
        .eq('user_id', ownerId)
        .eq('space', space)
        .eq('record_id', recordId)
        .limit(1);
    final blobs = (blobRows as List).cast<Map<String, dynamic>>();
    if (blobs.isEmpty) return null;
    final blob = blobs.first;
    final rk = await aesDecrypt(
      sk,
      unb64((blob['rk_wrap_iv'] ?? blob['iv']) as String),
      unb64(blob['rk_wrap'] as String),
    );
    final plain = await aesDecrypt(
        rk, unb64(blob['iv'] as String), unb64(blob['ct'] as String));
    return jsonDecode(utf8.decode(plain));
  }
}
