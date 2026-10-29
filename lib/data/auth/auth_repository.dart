import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase/supabase.dart';

import '../../core/constants.dart';

/// Auth via WebView: the app opens the production web app's auth surface
/// (/signup, /signin, Continue with Google — all inside a WebView, zero
/// native OAuth configuration). When the web app reaches the authenticated
/// shell, the injected bridge hands the Supabase session back to the client.
class AuthRepository {
  final FlutterSecureStorage _secure = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _kSession = 'relay_session_json';
  static const _kProfile = 'relay_profile_json';

  SupabaseClient? _client;

  SupabaseClient get client {
    _client ??= SupabaseClient(RelayConfig.supabaseUrl, RelayConfig.supabaseAnonKey);
    return _client!;
  }

  /// The JS bridge listens for this handler name from the page.
  static const jsHandlerName = 'relaySession';

  /// JS injected into every page load — watches for an authenticated
  /// supabase-js session in localStorage and ships it to the client.
  String get bridgeScript => '''
    (function(){
      var KEY = 'sb-gobwknacvpgysmgpvzqt-auth-token';
      function grab(){
        try {
          var raw = localStorage.getItem(KEY);
          if (!raw) return;
          var parsed = JSON.parse(raw);
          var session = parsed && parsed.currentSession ? parsed.currentSession : parsed;
          if (session && session.access_token && !session.__shipped) {
            window.flutter_inappwebview.callHandler('$jsHandlerName', JSON.stringify(session));
          }
        } catch(e) {}
      }
      setInterval(grab, 700);
      setTimeout(grab, 300);
    })();
  ''';

  Future<bool> hasStoredSession() async => await _secure.read(key: _kSession) != null;

  /// Restore a persisted session into the Supabase client. Returns profile map
  /// or null when the session is unusable.
  Future<Map<String, dynamic>?> restore() async {
    final raw = await _secure.read(key: _kSession);
    if (raw == null) return null;
    try {
      final response = await client.auth.recoverSession(raw);
      final user = response.user ?? response.session?.user;
      if (user == null) return null;
      final profile = await fetchProfile(user.id);
      if (profile != null) await _secure.write(key: _kProfile, value: jsonEncode(profile));
      return profile;
    } catch (_) {
      await _secure.delete(key: _kSession);
      return null;
    }
  }

  /// Called by the WebView screen once the page hands over a session.
  Future<Map<String, dynamic>?> captureSession(String sessionJson) async {
    try {
      final session = jsonDecode(sessionJson) as Map<String, dynamic>;
      final accessToken = session['access_token'] as String?;
      final refreshToken = session['refresh_token'] as String?;
      if (accessToken == null || refreshToken == null) return null;
      await client.auth.setSession(jsonEncode(session));
      await _secure.write(key: _kSession, value: jsonEncode(session));
      final user = client.auth.currentUser;
      if (user == null) return null;
      final profile = await fetchProfile(user.id);
      if (profile != null) await _secure.write(key: _kProfile, value: jsonEncode(profile));
      return profile;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> fetchProfile(String userId) async {
    try {
      final res = await client
          .from('profiles')
          .select()
          .or('auth_user_id.eq.$userId,id.eq.$userId')
          .maybeSingle();
      return res == null ? null : Map<String, dynamic>.from(res);
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> cachedProfile() async {
    final raw = await _secure.read(key: _kProfile);
    if (raw == null) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return null;
    }
  }

  Future<void> signOut() async {
    try { await client.auth.signOut(); } catch (_) {}
    await _secure.delete(key: _kSession);
  }
}
