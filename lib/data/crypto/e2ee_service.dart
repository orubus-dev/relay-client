import 'dart:convert';

import 'package:supabase/supabase.dart';

import '../../core/constants.dart';
import '../../util/encoding.dart';
import 'signal_protocol.dart';

/// Thrown when an envelope can never be decrypted on this device (bare
/// continuation of a session we don't share, or sealed to an identity we no
/// longer hold). The caller kicks the session-reset protocol.
class RelaySessionDead implements Exception {
  final String message;
  RelaySessionDead([this.message = 'session unrecoverable']);
  @override
  String toString() => 'RelaySessionDead: $message';
}

/// Orchestration: identity registration, per-(conversation, peer) sessions,
/// R1 single envelopes (DMs) and R2 fan-out envelopes (groups/channels).
/// Mirrors the web client's cryptoService.ts — messages interop both ways.
class E2eeService {
  final SupabaseClient sb;
  final CryptoStore store;
  LocalIdentity? _identity;
  String? _meId;
  final Map<String, RatchetState> _sessionCache = {};
  final Map<String, Future<RatchetState>> _inflight = {};

  E2eeService({required this.sb, required this.store});

  static const dmPrefix = 'R1:';
  static const fanoutPrefix = 'R2:';

  String _sKey(String conversationId, String peerId) => '$conversationId:$peerId';

  bool isEnvelope(String content) => content.startsWith(dmPrefix);
  bool isFanout(String content) => content.startsWith(fanoutPrefix);

  Envelope parseEnvelope(String content) =>
      Envelope.fromJson(jsonDecode(content.substring(dmPrefix.length)) as Map<String, dynamic>);

  /// R2 payload: {v:2, to:[{p: profileId, e: envelope}]}
  List<MapEntry<String, Envelope>> parseFanout(String content) {
    final j = jsonDecode(content.substring(fanoutPrefix.length)) as Map<String, dynamic>;
    final to = (j['to'] as List).cast<Map<String, dynamic>>();
    return to
        .map((e) => MapEntry(e['p'] as String, Envelope.fromJson(Map<String, dynamic>.from(e['e']))))
        .toList();
  }

  String sealFanout(List<MapEntry<String, Envelope>> entries) => fanoutPrefix +
      jsonEncode({
        'v': 2,
        'to': [
          for (final e in entries)
            {'p': e.key, 'e': e.value.toJson()}
        ],
      });

  Future<LocalIdentity> ensureIdentity(String profileId) async {
    if (_identity != null && _meId == profileId) return _identity!;
    _meId = profileId;
    var local = await store.getIdentity(profileId);
    final reg = await sb.from('signal_identities').select('ik_pub, sign_pub, spk_id').eq('profile_id', profileId).maybeSingle();

    final ikPub = local == null ? null : B64u.encode(local.ik.publicKey);
    if (local != null && reg != null && reg['ik_pub'] == ikPub) {
      _identity = local;
      return local;
    }
    // fresh device — new identity, replace server bundle
    local = await generateIdentity();
    await store.setIdentity(profileId, local);
    await _registerIdentity(profileId, local);
    _identity = local;
    return local;
  }

  Future<void> _registerIdentity(String profileId, LocalIdentity id) async {
    await sb.from('signal_identities').upsert({
      'profile_id': profileId,
      'ik_pub': B64u.encode(id.ik.publicKey),
      'sign_pub': B64u.encode(id.sign.publicKey),
      'spk_pub': B64u.encode(id.spk.publicKey),
      'spk_id': id.spkId,
      'spk_sig': B64u.encode(id.spkSig),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'profile_id');

    await sb.from('signal_one_time_prekeys').delete().eq('profile_id', profileId);
    await sb.from('signal_one_time_prekeys').insert([
      for (final opk in id.opks)
        {
          'profile_id': profileId,
          'opk_id': opk.key,
          'opk_pub': B64u.encode(opk.value.publicKey),
        }
    ]);
  }

  Future<void> topUpPrekeys(String profileId) async {
    final identity = _identity;
    if (identity == null) return;
    final countRes = await sb.from('signal_one_time_prekeys').count().eq('profile_id', profileId);
    if ((countRes ?? 0) > 8) return;
    for (var i = 0; i < 15; i++) {
      final pair = await generateDhPair();
      final id = DateTime.now().microsecondsSinceEpoch % (1 << 31);
      await sb.from('signal_one_time_prekeys').insert({
        'profile_id': profileId,
        'opk_id': id,
        'opk_pub': B64u.encode(pair.publicKey),
      });
      identity.opks.add(MapEntry(id, pair));
    }
  }

  Future<PrekeyBundle> _fetchBundle(String peerId) async {
    final data = await sb.rpc('get_prekey_bundle', params: {'p_profile_id': peerId});
    if (data == null) throw StateError('No prekey bundle for peer');
    return PrekeyBundle.fromJson(Map<String, dynamic>.from(data as Map));
  }

  Future<RatchetState> ensureSession(String myProfileId, String conversationId, String peerProfileId) async {
    final identity = await ensureIdentity(myProfileId);
    final key = _sKey(conversationId, peerProfileId);
    final cached = _sessionCache[key];
    if (cached != null) return cached;
    final inflight = _inflight[key];
    if (inflight != null) return inflight;

    final fut = () async {
      final bundle = await _fetchBundle(peerProfileId);
      var stored = await store.getSession(myProfileId, conversationId, peerProfileId);
      if (stored == null) {
        // legacy (pre-fanout) session continuity for DMs
        final legacy = await store.getLegacySession(myProfileId, conversationId);
        if (legacy != null && legacy.peerIk != null && legacy.peerIk == bundle.ikPub) {
          await store.setSession(myProfileId, conversationId, peerProfileId, legacy);
          stored = legacy;
        }
      }
      if (stored != null) {
        if (stored.peerIk != null && stored.peerIk != bundle.ikPub) {
          await store.deleteSession(myProfileId, conversationId, peerProfileId);
        } else {
          stored.peerIk ??= bundle.ikPub;
          _sessionCache[key] = stored;
          return stored;
        }
      }
      final init = await x3dhInitiate(identity.ik, bundle);
      final pre = {
        'ek': B64u.encode(init.ephemeralPub),
        'spkId': bundle.spkId,
        'opkId': init.usedOpkId,
      };
      final initResult = await initRatchetAsInitiatorAsync(init.sharedSecret, B64u.decode(bundle.spkPub), pre);
      final state = initResult.state;
      state.peerIk = bundle.ikPub;
      await store.setSession(myProfileId, conversationId, peerProfileId, state);
      _sessionCache[key] = state;
      topUpPrekeys(myProfileId).catchError((_) {});
      return state;
    }();

    _inflight[key] = fut;
    try {
      return await fut;
    } finally {
      _inflight.remove(key);
    }
  }

  /// Build a session from an incoming prekey message (responder side).
  ///
  /// NOTE: does NOT persist the built session — the caller must only persist
  /// it after ratchetDecrypt actually succeeds. Persisting an unverified
  /// responder session poisoned the store whenever the envelope was sealed to
  /// a previous identity (spk/opk mismatch): the wrong shared secret got
  /// stored and every later send reused the broken session (bare envelopes,
  /// no `pre` block) the peer could never decrypt.
  Future<RatchetState> _sessionFromPrekeyMessage(
    String myProfileId,
    String conversationId,
    String peerProfileId,
    Envelope env,
  ) async {
    final identity = await ensureIdentity(myProfileId);
    final existing = await store.getSession(myProfileId, conversationId, peerProfileId);
    if (existing != null && existing.dhRemote == env.dh) {
      _sessionCache[_sKey(conversationId, peerProfileId)] = existing;
      return existing;
    }
    final opk = env.pre?['opkId'] == null
        ? null
        : identity.opks.where((o) => o.key == (env.pre!['opkId'] as num).toInt()).firstOrNull?.value;
    final shared = await x3dhRespond(
      identity.ik,
      identity.spk,
      opk,
      B64u.decode(env.s),
      B64u.decode(env.pre!['ek'] as String),
    );
    final state = await initRatchetAsResponder(shared, identity.spk);
    state.peerIk = env.s;
    return state;
  }

  /// Encrypt a payload to ONE recipient → sealed R1 envelope string.
  Future<String> encryptFor(String myProfileId, String conversationId, String peerProfileId, String plaintextPayload) async {
    final identity = await ensureIdentity(myProfileId);
    final state = await ensureSession(myProfileId, conversationId, peerProfileId);
    final env = await ratchetEncrypt(state, conversationId, B64u.encode(identity.ik.publicKey), plaintextPayload);
    await store.setSession(myProfileId, conversationId, peerProfileId, state);
    return dmPrefix + jsonEncode(env.toJson());
  }

  /// Encrypt a payload to EVERY member → sealed R2 fan-out string.
  Future<String> encryptFanout(
    String myProfileId,
    String conversationId,
    List<String> peerProfileIds,
    String plaintextPayload,
  ) async {
    final identity = await ensureIdentity(myProfileId);
    final senderIk = B64u.encode(identity.ik.publicKey);
    final entries = <MapEntry<String, Envelope>>[];
    for (final pid in peerProfileIds) {
      if (pid.isEmpty || pid == myProfileId) continue;
      final state = await ensureSession(myProfileId, conversationId, pid);
      final env = await ratchetEncrypt(state, conversationId, senderIk, plaintextPayload);
      await store.setSession(myProfileId, conversationId, pid, state);
      entries.add(MapEntry(pid, env));
    }
    if (entries.isEmpty) throw StateError('No recipients for fan-out');
    return sealFanout(entries);
  }

  /// Decrypt an envelope from [peerProfileId] (the sender).
  Future<String> decryptFor(String myProfileId, String conversationId, String peerProfileId, Envelope env) async {
    final identity = await ensureIdentity(myProfileId);
    final key = _sKey(conversationId, peerProfileId);
    var state = _sessionCache[key] ?? await store.getSession(myProfileId, conversationId, peerProfileId);

    // Pristine copy of the persisted session. Failed decrypt attempts MUTATE
    // the ratchet state in place (dh ratchet steps, chain advances) — a sweep
    // over old undecryptable messages used to corrupt the live session, after
    // which every new message failed. Only successful decrypts commit.
    RatchetState? snapshot;
    if (state != null) {
      snapshot = RatchetState.fromJson(jsonDecode(jsonEncode(state.toJson())) as Map<String, dynamic>);
    }

    final envelopeTargetsCurrentIdentity =
        env.pre == null || env.pre!['spkId'] == null || (env.pre!['spkId'] as num).toInt() == identity.spkId;

    RatchetState? candidate = state;
    if (candidate == null && env.pre != null) {
      if (!envelopeTargetsCurrentIdentity) {
        throw RelaySessionDead('prekey envelope targets a previous identity (spk mismatch)');
      }
      candidate = await _sessionFromPrekeyMessage(myProfileId, conversationId, peerProfileId, env);
    }
    if (candidate == null) throw RelaySessionDead('no session for conversation');
    try {
      final pt = await ratchetDecrypt(candidate, conversationId, env);
      // Verified good — commit the evolved state.
      await store.setSession(myProfileId, conversationId, peerProfileId, candidate);
      _sessionCache[key] = candidate;
      return pt;
    } catch (err) {
      // Restore the pristine persisted session first — failed attempts leave no trace.
      if (snapshot != null) {
        await store.setSession(myProfileId, conversationId, peerProfileId, snapshot);
        _sessionCache[key] = snapshot;
      } else {
        await store.deleteSession(myProfileId, conversationId, peerProfileId);
        _sessionCache.remove(key);
      }
      final msg = err.toString();
      if (msg.contains('replay/underflow')) rethrow;
      // A prekey (first-contact) message that still fails means the peer
      // re-initiated against our CURRENT identity — rebuild once and retry.
      if (env.pre != null && envelopeTargetsCurrentIdentity) {
        final fresh = await _sessionFromPrekeyMessage(myProfileId, conversationId, peerProfileId, env);
        final pt2 = await ratchetDecrypt(fresh, conversationId, env);
        await store.setSession(myProfileId, conversationId, peerProfileId, fresh);
        _sessionCache[key] = fresh;
        return pt2;
      }
      // Unrecoverable locally — the session-reset protocol re-syncs both devices.
      throw RelaySessionDead('bare envelope undecryptable: $msg');
    }
  }

  /// Session-reset protocol: drop the local session, initiate a fresh X3DH
  /// against the peer's CURRENT prekey bundle, and return the sealed {k:'r'}
  /// control envelope (carries a `pre` block) for the caller to send. The peer
  /// rebuilds from the header and both sides converge on the same keys.
  Future<String> buildSessionResetWire(String myProfileId, String conversationId, String peerProfileId) async {
    await store.deleteSession(myProfileId, conversationId, peerProfileId);
    _sessionCache.remove(_sKey(conversationId, peerProfileId));
    return encryptFor(myProfileId, conversationId, peerProfileId, jsonEncode({'k': 'r'}));
  }

  /// Decrypt either wire format; returns null when this device has no envelope.
  Future<String?> decryptAny(String myProfileId, String conversationId, String senderId, String content) async {
    if (isFanout(content)) {
      final mine = parseFanout(content).where((e) => e.key == myProfileId).firstOrNull;
      if (mine == null) return null;
      return decryptFor(myProfileId, conversationId, senderId, mine.value);
    }
    if (isEnvelope(content)) {
      return decryptFor(myProfileId, conversationId, senderId, parseEnvelope(content));
    }
    return content; // plaintext (system)
  }
}

/// Persistent device-side crypto storage (identity + sessions) on Hive.
abstract class CryptoStore {
  Future<LocalIdentity?> getIdentity(String profileId);
  Future<void> setIdentity(String profileId, LocalIdentity identity);
  Future<RatchetState?> getSession(String profileId, String conversationId, String peerId);
  Future<void> setSession(String profileId, String conversationId, String peerId, RatchetState state);
  Future<void> deleteSession(String profileId, String conversationId, String peerId);
  Future<RatchetState?> getLegacySession(String profileId, String conversationId);
}
