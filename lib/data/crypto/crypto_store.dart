import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';

import 'e2ee_service.dart';
import 'signal_protocol.dart';

/// Hive-backed crypto store. Private key material NEVER leaves the device.
class HiveCryptoStore implements CryptoStore {
  static const _identityBox = 'relay_e2ee_identity';
  static const _sessionsBox = 'relay_e2ee_sessions';

  Box? _idBox;
  Box? _sessBox;

  Future<void> init() async {
    // Without an explicit init Hive falls back to Directory.current — which on
    // Android is read-only, so openBox threw, every identity/session op
    // silently no-op'd, and the identity re-registered (losing ALL sessions)
    // on every launch. initFlutter() points Hive at the app documents dir on
    // both Android and Windows.
    await Hive.initFlutter();
    _idBox = await Hive.openBox(_identityBox);
    _sessBox = await Hive.openBox(_sessionsBox);
  }

  String _sessionKey(String profileId, String conversationId, String? peerId) =>
      peerId == null ? '$profileId:$conversationId' : '$profileId:$conversationId:$peerId';

  @override
  Future<LocalIdentity?> getIdentity(String profileId) async {
    final raw = _idBox?.get(profileId);
    if (raw == null) return null;
    try {
      return LocalIdentity.fromJson(Map<String, dynamic>.from(jsonDecode(raw as String) as Map));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> setIdentity(String profileId, LocalIdentity identity) async {
    await _idBox?.put(profileId, jsonEncode(identity.toJson()));
  }

  @override
  Future<RatchetState?> getSession(String profileId, String conversationId, String peerId) async {
    final raw = _sessBox?.get(_sessionKey(profileId, conversationId, peerId));
    if (raw == null) return null;
    try {
      return RatchetState.fromJson(Map<String, dynamic>.from(jsonDecode(raw as String) as Map));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> setSession(String profileId, String conversationId, String peerId, RatchetState state) async {
    await _sessBox?.put(_sessionKey(profileId, conversationId, peerId), jsonEncode(state.toJson()));
  }

  @override
  Future<void> deleteSession(String profileId, String conversationId, String peerId) async {
    await _sessBox?.delete(_sessionKey(profileId, conversationId, peerId));
  }

  @override
  Future<RatchetState?> getLegacySession(String profileId, String conversationId) async {
    final raw = _sessBox?.get(_sessionKey(profileId, conversationId, null));
    if (raw == null) return null;
    try {
      return RatchetState.fromJson(Map<String, dynamic>.from(jsonDecode(raw as String) as Map));
    } catch (_) {
      return null;
    }
  }
}
