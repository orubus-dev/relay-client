import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../util/encoding.dart';

/// Signal-level E2EE primitives — a faithful Dart port of the web client's
/// signalProtocol.ts. Byte-for-byte wire compatible:
///  · X25519 + Ed25519, HKDF-SHA256
///  · X3DH info: "RelayX3DHv1", salt: 32 zero bytes
///  · Root info: "RelayDRRootKeyv1", message info: "RelayDRMessageKeyv1"
///  · AES-256-GCM, 12-byte IV, AAD = JSON [conversationId, senderIk, dh, pn, n]

final _x25519 = X25519();
final _ed25519 = Ed25519();
final _aesGcm = AesGcm.with256bits();
final _hmacSha256 = Hmac.sha256();

final Uint8List kF32 = Uint8List.fromList(List.filled(32, 0xff));
final Uint8List kZero32 = Uint8List(32);
final Uint8List rootInfo = utf8bytes('RelayDRRootKeyv1');
final Uint8List msgInfo = utf8bytes('RelayDRMessageKeyv1');
final Uint8List x3dhInfo = utf8bytes('RelayX3DHv1');

Uint8List _randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

// ---------------------------------------------------------------------------
// key pairs
// ---------------------------------------------------------------------------

class DhKeyPair {
  final Uint8List publicKey;
  final Uint8List privateKey;
  DhKeyPair(this.publicKey, this.privateKey);
}

class SignKeyPair {
  final Uint8List publicKey;
  final Uint8List privateKey;
  SignKeyPair(this.publicKey, this.privateKey);
}

Future<DhKeyPair> generateDhPair() async {
  final kp = await _x25519.newKeyPair();
  final priv = Uint8List.fromList(await kp.extractPrivateKeyBytes());
  final pub = await kp.extractPublicKey();
  return DhKeyPair(Uint8List.fromList(pub.bytes), priv);
}

Future<Uint8List> dh(DhKeyPair mine, Uint8List remotePub) async {
  final keyPair = SimpleKeyPairData(
    mine.privateKey,
    publicKey: SimplePublicKey(mine.publicKey, type: KeyPairType.x25519),
    type: KeyPairType.x25519,
  );
  final shared = await _x25519.sharedSecretKey(
    keyPair: keyPair,
    remotePublicKey: SimplePublicKey(remotePub, type: KeyPairType.x25519),
  );
  return Uint8List.fromList(await shared.extractBytes());
}

Future<SignKeyPair> generateSignPair() async {
  final kp = await _ed25519.newKeyPair();
  final priv = Uint8List.fromList(await kp.extractPrivateKeyBytes());
  final pub = await kp.extractPublicKey();
  return SignKeyPair(Uint8List.fromList(pub.bytes), priv);
}

Future<Uint8List> edSign(Uint8List msg, SignKeyPair keys) async {
  final sig = await _ed25519.sign(
    msg,
    keyPair: SimpleKeyPairData(
      keys.privateKey,
      publicKey: SimplePublicKey(keys.publicKey, type: KeyPairType.ed25519),
      type: KeyPairType.ed25519,
    ),
  );
  return Uint8List.fromList(sig.bytes);
}

Future<bool> edVerify(Uint8List msg, Uint8List sig, Uint8List pub) async {
  try {
    return await _ed25519.verify(
      msg,
      signature: Signature(sig, publicKey: SimplePublicKey(pub, type: KeyPairType.ed25519)),
    );
  } catch (_) {
    return false;
  }
}

// ---------------------------------------------------------------------------
// HKDF-Extract / Expand (SHA-256) — explicit implementation, no API drift
// ---------------------------------------------------------------------------

final _sha256 = Sha256Pure();

Uint8List _hmacSha256Raw(Uint8List key, Uint8List data) {
  var k = key;
  if (k.length > 64) k = _sha256.process(k);
  if (k.length < 64) {
    k = Uint8List.fromList([...k, ...List.filled(64 - k.length, 0)]);
  }
  final ipad = Uint8List.fromList(k.map((b) => b ^ 0x36).toList());
  final opad = Uint8List.fromList(k.map((b) => b ^ 0x5c).toList());
  final inner = _sha256.process(Uint8List.fromList([...ipad, ...data]));
  return _sha256.process(Uint8List.fromList([...opad, ...inner]));
}

/// Sync SHA-256 (pure Dart) so KDFs stay synchronous like the web implementation.
class Sha256Pure {
  static const _k = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  Uint8List process(Uint8List message) {
    var h = [
      0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
      0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ];
    final bitLen = message.length * 8;
    final padded = Uint8List.fromList([...message, 0x80]);
    while (padded.length % 64 != 56) {
      padded.add(0);
    }
    final lenBytes = ByteData(8)..setUint64(0, bitLen);
    padded.addAll(lenBytes.buffer.asUint8List());

    final w = Uint32List(64);
    for (var off = 0; off < padded.length; off += 64) {
      for (var i = 0; i < 16; i++) {
        w[i] = ByteData.sublistView(padded, off + i * 4, off + i * 4 + 4).getUint32(0);
      }
      for (var i = 16; i < 64; i++) {
        final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
        final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
      }
      var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
      for (var i = 0; i < 64; i++) {
        final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
        final ch = (e & f) ^ ((~e & 0xffffffff) & g);
        final t1 = (hh + s1 + ch + _k[i] + w[i]) & 0xffffffff;
        final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
        final maj = (a & b) ^ (a & c) ^ (b & c);
        final t2 = (s0 + maj) & 0xffffffff;
        hh = g; g = f; f = e; e = (d + t1) & 0xffffffff;
        d = c; c = b; b = a; a = (t1 + t2) & 0xffffffff;
      }
      h[0] = (h[0] + a) & 0xffffffff; h[1] = (h[1] + b) & 0xffffffff;
      h[2] = (h[2] + c) & 0xffffffff; h[3] = (h[3] + d) & 0xffffffff;
      h[4] = (h[4] + e) & 0xffffffff; h[5] = (h[5] + f) & 0xffffffff;
      h[6] = (h[6] + g) & 0xffffffff; h[7] = (h[7] + hh) & 0xffffffff;
    }
    final out = Uint8List(32);
    final bd = ByteData(32);
    for (var i = 0; i < 8; i++) {
      bd.setUint32(i * 4, h[i]);
    }
    out.setAll(0, bd.buffer.asUint8List());
    return out;
  }

  int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;
}

Uint8List hkdfExtractExpand(Uint8List ikm, Uint8List salt, Uint8List info, int length) {
  // Extract
  final prk = _hmacSha256Raw(salt.isEmpty ? Uint8List(32) : salt, ikm);
  // Expand
  final out = <int>[];
  var t = Uint8List(0);
  var counter = 1;
  while (out.length < length) {
    t = _hmacSha256Raw(prk, Uint8List.fromList([...t, ...info, counter]));
    out.addAll(t);
    counter++;
  }
  return Uint8List.fromList(out.sublist(0, length));
}

// ---------------------------------------------------------------------------
// KDFs (matching the web client exactly)
// ---------------------------------------------------------------------------

class RootKdfResult {
  final Uint8List rootKey;
  final Uint8List chainKey;
  RootKdfResult(this.rootKey, this.chainKey);
}

RootKdfResult kdfRootKey(Uint8List rootKey, Uint8List dhOut) {
  final okm = hkdfExtractExpand(dhOut, rootKey, rootInfo, 64);
  return RootKdfResult(
    Uint8List.sublistView(okm, 0, 32),
    Uint8List.sublistView(okm, 32, 64),
  );
}

class ChainKdfResult {
  final Uint8List chainKey;
  final Uint8List messageKey;
  ChainKdfResult(this.chainKey, this.messageKey);
}

ChainKdfResult kdfChainKey(Uint8List chainKey) {
  final messageKey = _hmacSha256Raw(chainKey, Uint8List.fromList([0x01]));
  final next = _hmacSha256Raw(chainKey, Uint8List.fromList([0x02]));
  return ChainKdfResult(next, messageKey);
}

Uint8List deriveAesKey(Uint8List messageKey) {
  final okm = hkdfExtractExpand(messageKey, kZero32, msgInfo, 80);
  return Uint8List.sublistView(okm, 0, 32);
}

// ---------------------------------------------------------------------------
// X3DH
// ---------------------------------------------------------------------------

class PrekeyBundle {
  final String ikPub;
  final String signPub;
  final String spkPub;
  final int spkId;
  final String spkSig;
  final String? opkPub;
  final int? opkId;
  PrekeyBundle({
    required this.ikPub,
    required this.signPub,
    required this.spkPub,
    required this.spkId,
    required this.spkSig,
    this.opkPub,
    this.opkId,
  });

  factory PrekeyBundle.fromJson(Map<String, dynamic> j) => PrekeyBundle(
        ikPub: j['ik_pub'] as String,
        signPub: j['sign_pub'] as String,
        spkPub: j['spk_pub'] as String,
        spkId: (j['spk_id'] as num).toInt(),
        spkSig: j['spk_sig'] as String,
        opkPub: j['opk_pub'] as String?,
        opkId: j['opk_id'] == null ? null : (j['opk_id'] as num).toInt(),
      );
}

class X3dhInitResult {
  final Uint8List sharedSecret;
  final Uint8List ephemeralPub;
  final int? usedOpkId;
  X3dhInitResult(this.sharedSecret, this.ephemeralPub, this.usedOpkId);
}

Future<X3dhInitResult> x3dhInitiate(DhKeyPair myIk, PrekeyBundle bundle) async {
  final spkPub = B64u.decode(bundle.spkPub);
  final sig = B64u.decode(bundle.spkSig);
  final signPub = B64u.decode(bundle.signPub);
  if (!await edVerify(spkPub, sig, signPub)) {
    throw StateError('Prekey signature verification failed');
  }
  final ek = await generateDhPair();
  final dh1 = await dh(myIk, spkPub); // DH(IKa, SPKb)
  final dh2 = await dh(ek, B64u.decode(bundle.ikPub)); // DH(EKa, IKb)
  final dh3 = await dh(ek, spkPub); // DH(EKa, SPKb)
  var dh4 = Uint8List(32);
  int? usedOpkId;
  if (bundle.opkPub != null && bundle.opkId != null) {
    dh4 = await dh(ek, B64u.decode(bundle.opkPub!)); // DH(EKa, OPKb)
    usedOpkId = bundle.opkId;
  }
  final ikm = Uint8List.fromList([...kF32, ...dh1, ...dh2, ...dh3, ...dh4]);
  final shared = hkdfExtractExpand(ikm, kZero32, x3dhInfo, 32);
  return X3dhInitResult(shared, ek.publicKey, usedOpkId);
}

Future<Uint8List> x3dhRespond(
  DhKeyPair myIk,
  DhKeyPair mySpk,
  DhKeyPair? myOpk,
  Uint8List initiatorIkPub,
  Uint8List ephemeralPub,
) async {
  final dh1 = await dh(mySpk, initiatorIkPub); // DH(SPKb, IKa)
  final dh2 = await dh(myIk, ephemeralPub); // DH(IKb, EKa)
  final dh3 = await dh(mySpk, ephemeralPub); // DH(SPKb, EKa)
  var dh4 = Uint8List(32);
  if (myOpk != null) dh4 = await dh(myOpk, ephemeralPub); // DH(OPKb, EKa)
  final ikm = Uint8List.fromList([...kF32, ...dh1, ...dh2, ...dh3, ...dh4]);
  return hkdfExtractExpand(ikm, kZero32, x3dhInfo, 32);
}

// ---------------------------------------------------------------------------
// Double Ratchet
// ---------------------------------------------------------------------------

class RatchetHeader {
  final String dh;
  final int pn;
  final int n;
  RatchetHeader(this.dh, this.pn, this.n);
}

/// Wire envelope — JSON keys identical to the web client.
class Envelope {
  final int v;
  final String s;
  Map<String, dynamic>? pre; // {ek, spkId, opkId}
  final String dh;
  final int pn;
  final int n;
  final String ct;
  final String iv;
  Envelope({
    required this.v,
    required this.s,
    this.pre,
    required this.dh,
    required this.pn,
    required this.n,
    required this.ct,
    required this.iv,
  });

  Map<String, dynamic> toJson() => {
        'v': v,
        's': s,
        if (pre != null) 'pre': pre,
        'dh': dh,
        'pn': pn,
        'n': n,
        'ct': ct,
        'iv': iv,
      };

  factory Envelope.fromJson(Map<String, dynamic> j) => Envelope(
        v: (j['v'] as num).toInt(),
        s: j['s'] as String,
        pre: j['pre'] == null ? null : Map<String, dynamic>.from(j['pre'] as Map),
        dh: j['dh'] as String,
        pn: (j['pn'] as num).toInt(),
        n: (j['n'] as num).toInt(),
        ct: j['ct'] as String,
        iv: j['iv'] as String,
      );
}

class RatchetState {
  String rootKey;
  Map<String, String> dhSelf; // {pub, priv}
  String? dhRemote;
  String? ckSending;
  String? ckReceiving;
  int nSending;
  int nReceiving;
  int prevSendingCount;
  Map<String, String> skipped; // "dh:n" -> messageKey
  Map<String, dynamic>? pendingPre;
  String? peerIk;

  RatchetState({
    required this.rootKey,
    required this.dhSelf,
    this.dhRemote,
    this.ckSending,
    this.ckReceiving,
    this.nSending = 0,
    this.nReceiving = 0,
    this.prevSendingCount = 0,
    Map<String, String>? skipped,
    this.pendingPre,
    this.peerIk,
  }) : skipped = skipped ?? {};

  Map<String, dynamic> toJson() => {
        'rootKey': rootKey,
        'dhSelf': dhSelf,
        'dhRemote': dhRemote,
        'ckSending': ckSending,
        'ckReceiving': ckReceiving,
        'nSending': nSending,
        'nReceiving': nReceiving,
        'prevSendingCount': prevSendingCount,
        'skipped': skipped,
        if (pendingPre != null) 'pendingPre': pendingPre,
        if (peerIk != null) 'peerIk': peerIk,
      };

  static RatchetState fromJson(Map<String, dynamic> j) => RatchetState(
        rootKey: j['rootKey'] as String,
        dhSelf: Map<String, String>.from(j['dhSelf'] as Map),
        dhRemote: j['dhRemote'] as String?,
        ckSending: j['ckSending'] as String?,
        ckReceiving: j['ckReceiving'] as String?,
        nSending: (j['nSending'] as num?)?.toInt() ?? 0,
        nReceiving: (j['nReceiving'] as num?)?.toInt() ?? 0,
        prevSendingCount: (j['prevSendingCount'] as num?)?.toInt() ?? 0,
        skipped: j['skipped'] == null ? {} : Map<String, String>.from(j['skipped'] as Map),
        pendingPre: j['pendingPre'] == null ? null : Map<String, dynamic>.from(j['pendingPre'] as Map),
        peerIk: j['peerIk'] as String?,
      );
}

class InitiatorInit {
  final RatchetState state;
  final DhKeyPair dhSelfPair;
  InitiatorInit(this.state, this.dhSelfPair);
}

/// Async variant (Dart DH keygen is async). Produces identical state semantics.
Future<InitiatorInit> initRatchetAsInitiatorAsync(
  Uint8List sharedSecret,
  Uint8List remoteSpkPub,
  Map<String, dynamic> pre,
) async {
  final dhSelf = await generateDhPair();
  final rootStep = kdfRootKey(sharedSecret, await dh(dhSelf, remoteSpkPub));
  final state = RatchetState(
    rootKey: B64u.encode(rootStep.rootKey),
    dhSelf: {'pub': B64u.encode(dhSelf.publicKey), 'priv': B64u.encode(dhSelf.privateKey)},
    dhRemote: B64u.encode(remoteSpkPub),
    ckSending: B64u.encode(rootStep.chainKey),
    ckReceiving: null,
    pendingPre: pre,
  );
  return InitiatorInit(state, dhSelf);
}

Future<RatchetState> initRatchetAsResponder(Uint8List sharedSecret, DhKeyPair mySpk) async {
  return RatchetState(
    rootKey: B64u.encode(sharedSecret),
    dhSelf: {'pub': B64u.encode(mySpk.publicKey), 'priv': B64u.encode(mySpk.privateKey)},
    dhRemote: null,
    ckSending: null,
    ckReceiving: null,
  );
}

// --- AES-GCM ---------------------------------------------------------------

Future<Uint8List> _aesEncrypt(Uint8List key, Uint8List iv, Uint8List plaintext, Uint8List aad) async {
  final box = await _aesGcm.encrypt(
    plaintext,
    secretKey: SecretKey(key),
    nonce: iv,
    aad: aad,
  );
  return Uint8List.fromList(box.cipherText + box.mac.bytes);
}

Future<Uint8List> _aesDecrypt(Uint8List key, Uint8List iv, Uint8List ctAndTag, Uint8List aad) async {
  final ct = Uint8List.sublistView(ctAndTag, 0, ctAndTag.length - 16);
  final mac = Uint8List.sublistView(ctAndTag, ctAndTag.length - 16);
  final clear = await _aesGcm.decrypt(
    SecretBox(ct, nonce: iv, mac: Mac(mac)),
    secretKey: SecretKey(key),
    aad: aad,
  );
  return Uint8List.fromList(clear);
}

Uint8List aadFor(String conversationId, String senderIkPub, RatchetHeader header) {
  return utf8bytes(jsonEncodeCompat([conversationId, senderIkPub, header.dh, header.pn, header.n]));
}

/// jsonEncode compatible with JS JSON.stringify for arrays of scalars.
String jsonEncodeCompat(List<Object?> list) =>
    '[' + list.map((e) => e is String ? '"${_escapeJs(e)}"' : e.toString()).join(',') + ']';

String _escapeJs(String s) => s
    .replaceAll('\\', '\\\\')
    .replaceAll('"', '\\"')
    .replaceAll('\n', '\\n')
    .replaceAll('\r', '\\r')
    .replaceAll('\t', '\\t');

// --- ratchet encrypt / decrypt --------------------------------------------

Future<Envelope> ratchetEncrypt(
  RatchetState state,
  String conversationId,
  String senderIkPubB64u,
  String plaintext,
) async {
  if (state.ckSending == null) throw StateError('No sending chain');
  final chain = kdfChainKey(B64u.decode(state.ckSending!));
  state.ckSending = B64u.encode(chain.chainKey);
  final header = RatchetHeader(state.dhSelf['pub']!, state.prevSendingCount, state.nSending);
  final iv = _randomBytes(12);
  final aesKey = deriveAesKey(chain.messageKey);
  final ct = await _aesEncrypt(aesKey, iv, utf8bytes(plaintext), aadFor(conversationId, senderIkPubB64u, header));
  state.nSending += 1;
  final env = Envelope(
    v: 1,
    s: senderIkPubB64u,
    dh: header.dh,
    pn: header.pn,
    n: header.n,
    ct: B64u.encode(ct),
    iv: B64u.encode(iv),
  );
  if (state.pendingPre != null) {
    env.pre = state.pendingPre;
    state.pendingPre = null;
  }
  return env;
}

const maxSkip = 200;
const skippedCap = 400;

void _storeSkipped(RatchetState state, String dhRemote, int until) {
  Uint8List? ckMaybe = state.ckReceiving == null ? null : B64u.decode(state.ckReceiving!);
  if (ckMaybe == null) return;
  Uint8List ck = ckMaybe;
  for (var i = state.nReceiving; i < until; i++) {
    if (until - state.nReceiving > maxSkip) throw StateError('Too many skipped messages');
    final chain = kdfChainKey(ck);
    if (state.skipped.length >= skippedCap) {
      state.skipped.remove(state.skipped.keys.first);
    }
    state.skipped['$dhRemote:$i'] = B64u.encode(chain.messageKey);
    ck = chain.chainKey;
  }
  state.ckReceiving = B64u.encode(ck);
  state.nReceiving = until;
}

Future<String?> _trySkipped(RatchetState state, String senderIk, RatchetHeader header, Uint8List iv, Uint8List ct, String conversationId) async {
  final key = '${header.dh}:${header.n}';
  final mk = state.skipped[key];
  if (mk == null) return null;
  state.skipped.remove(key);
  final aesKey = deriveAesKey(B64u.decode(mk));
  final pt = await _aesDecrypt(aesKey, iv, ct, aadFor(conversationId, senderIk, header));
  return utf8str(pt);
}

Future<void> _dhRatchetStep(RatchetState state, String theirNewDhPub) async {
  state.prevSendingCount = state.nSending;
  state.nSending = 0;
  state.nReceiving = 0;
  state.dhRemote = theirNewDhPub;
  final step1 = kdfRootKey(B64u.decode(state.rootKey), await dh(DhKeyPair(B64u.decode(state.dhSelf['pub'] ?? ''), B64u.decode(state.dhSelf['priv'] ?? '')), B64u.decode(theirNewDhPub)));
  state.rootKey = B64u.encode(step1.rootKey);
  state.ckReceiving = B64u.encode(step1.chainKey);
  final newSelf = await generateDhPair();
  state.dhSelf = {'pub': B64u.encode(newSelf.publicKey), 'priv': B64u.encode(newSelf.privateKey)};
  final step2 = kdfRootKey(B64u.decode(state.rootKey), await dh(newSelf, B64u.decode(theirNewDhPub)));
  state.rootKey = B64u.encode(step2.rootKey);
  state.ckSending = B64u.encode(step2.chainKey);
}

/// Decrypt an incoming envelope. Mutates [state]. Throws on failure/replay.
Future<String> ratchetDecrypt(RatchetState state, String conversationId, Envelope env) async {
  final iv = B64u.decode(env.iv);
  final ct = B64u.decode(env.ct);

  final viaSkipped = await _trySkipped(state, env.s, RatchetHeader(env.dh, env.pn, env.n), iv, ct, conversationId);
  if (viaSkipped != null) return viaSkipped;

  if (env.dh != state.dhRemote) {
    _storeSkipped(state, state.dhRemote!, env.pn);
    await _dhRatchetStep(state, env.dh);
  }
  if (env.n < state.nReceiving) throw StateError('Message replay/underflow');
  _storeSkipped(state, env.dh, env.n);
  if (state.ckReceiving == null) throw StateError('No receiving chain');
  final chain = kdfChainKey(B64u.decode(state.ckReceiving!));
  state.ckReceiving = B64u.encode(chain.chainKey);
  final aesKey = deriveAesKey(chain.messageKey);
  final pt = await _aesDecrypt(aesKey, iv, ct, aadFor(conversationId, env.s, RatchetHeader(env.dh, env.pn, env.n)));
  state.nReceiving = env.n + 1;
  return utf8str(pt);
}

// ---------------------------------------------------------------------------
// identity bundle (device-local)
// ---------------------------------------------------------------------------

class LocalIdentity {
  final DhKeyPair ik;
  final SignKeyPair sign;
  final DhKeyPair spk;
  final int spkId;
  final Uint8List spkSig;
  final List<MapEntry<int, DhKeyPair>> opks;
  final String createdAt;
  LocalIdentity({
    required this.ik,
    required this.sign,
    required this.spk,
    required this.spkId,
    required this.spkSig,
    required this.opks,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'ik': {'pub': B64u.encode(ik.publicKey), 'priv': B64u.encode(ik.privateKey)},
        'sign': {'pub': B64u.encode(sign.publicKey), 'priv': B64u.encode(sign.privateKey)},
        'spk': {'pub': B64u.encode(spk.publicKey), 'priv': B64u.encode(spk.privateKey)},
        'spkId': spkId,
        'spkSig': B64u.encode(spkSig),
        'opks': opks.map((e) => {'id': e.key, 'pub': B64u.encode(e.value.publicKey), 'priv': B64u.encode(e.value.privateKey)}).toList(),
        'createdAt': createdAt,
      };

  static LocalIdentity fromJson(Map<String, dynamic> j) => LocalIdentity(
        ik: DhKeyPair(B64u.decode(j['ik']['pub']), B64u.decode(j['ik']['priv'])),
        sign: SignKeyPair(B64u.decode(j['sign']['pub']), B64u.decode(j['sign']['priv'])),
        spk: DhKeyPair(B64u.decode(j['spk']['pub']), B64u.decode(j['spk']['priv'])),
        spkId: (j['spkId'] as num).toInt(),
        spkSig: B64u.decode(j['spkSig']),
        opks: (j['opks'] as List)
            .map((e) => MapEntry((e['id'] as num).toInt(), DhKeyPair(B64u.decode(e['pub']), B64u.decode(e['priv']))))
            .toList(),
        createdAt: j['createdAt'] as String,
      );
}

Future<LocalIdentity> generateIdentity({int opkCount = 25}) async {
  final ik = await generateDhPair();
  final sign = await generateSignPair();
  final spk = await generateDhPair();
  final r = Random.secure();
  final spkId = r.nextInt(1 << 31);
  final spkSig = await edSign(spk.publicKey, sign);
  final opks = <MapEntry<int, DhKeyPair>>[];
  for (var i = 0; i < opkCount; i++) {
    opks.add(MapEntry(r.nextInt(1 << 31), await generateDhPair()));
  }
  return LocalIdentity(
    ik: ik,
    sign: sign,
    spk: spk,
    spkId: spkId,
    spkSig: spkSig,
    opks: opks,
    createdAt: DateTime.now().toUtc().toIso8601String(),
  );
}
