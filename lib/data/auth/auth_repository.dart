import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gotrue/gotrue.dart' show AuthApiException, AuthException, AuthRetryableFetchError;
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
  String get bridgeScript {
    // key derived from the configured backend — never hardcoded
    final lsKey = 'sb-${RelayConfig.supabaseRef}-auth-token';
    return '''
    (function(){
      var KEY = '$lsKey';
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
  }

  Future<bool> hasStoredSession() async => await _secure.read(key: _kSession) != null;

  /// Restore a persisted session into the Supabase client. Returns profile map
  /// or null when the session is unusable.
  ///
  /// OFFLINE-FIRST: recoverSession refreshes tokens over the network, so a
  /// cold start in airplane mode throws a TRANSIENT error. That must never
  /// sign the user out — we re-enter with the cached tokens (setSession is a
  /// local operation) and let [refreshInBackground] heal the session once the
  /// network returns. Only an explicit auth rejection (invalid refresh token,
  /// 400/401/403 from the auth server) clears the stored session.
  Future<Map<String, dynamic>?> restore() async {
    final raw = await _secure.read(key: _kSession);
    if (raw == null) return null;
    try {
      final response = await client.auth.recoverSession(raw);
      final user = response.user ?? response.session?.user;
      if (user == null) return null;
      final profile = await fetchProfile(user.id);
      if (profile != null) {
        await _secure.write(key: _kProfile, value: jsonEncode(profile));
        return profile;
      }
      // The session itself is valid — an offline/flaky profile fetch must not
      // sign the user out. Fall back to the cached profile; the app re-fetches
      // once the network is back.
      final cached = await cachedProfile();
      return cached ?? {'id': user.id}; // may lack a profile row — UI degrades gracefully
    } catch (e) {
      final isAuthRejection = e is AuthApiException ||
          (e is AuthException && e is! AuthRetryableFetchError) ||
          _looksLikeAuthRejection(e.toString());
      if (!isAuthRejection) {
        // transient (offline / timeout / 5xx): enter with the cached session
        try {
          final session = jsonDecode(raw) as Map<String, dynamic>;
          await client.auth.setSession(jsonEncode(session));
          final user = client.auth.currentUser;
          if (user != null) {
            final cached = await cachedProfile();
            return cached ?? {'id': user.id};
          }
        } catch (_) {
          // the stored JSON itself is unusable — nothing to restore
        }
        return null;
      }
      // genuinely dead/expired-refresh session — sign out
      await _secure.delete(key: _kSession);
      return null;
    }
  }

  static bool _looksLikeAuthRejection(String message) {
    final m = message.toLowerCase();
    return m.contains('invalid refresh token') ||
        m.contains('refresh_token_not_found') ||
        m.contains('invalid claims') ||
        m.contains('jwt expired') ||
        m.contains('session_not_found');
  }

  /// Fire-and-forget token refresh for the OFFLINE-FIRST cold start: heals
  /// the cached session once the network returns and persists the rotated
  /// tokens. Transient failures are swallowed — auto-refresh + the next cold
  /// start retry; an actual auth rejection is only cleaned up on next boot.
  Future<void> refreshInBackground() async {
    try {
      if (client.auth.currentSession == null) return;
      final res = await client.auth.refreshSession();
      final s = res.session;
      if (s != null) {
        await _secure.write(
          key: _kSession,
          value: jsonEncode({
            'access_token': s.accessToken,
            'refresh_token': s.refreshToken,
            'token_type': s.tokenType,
            'expires_in': s.expiresIn,
            'expires_at': s.expiresAt,
            'user': s.user.toJson(),
          }),
        );
      }
    } catch (_) {
      // offline / transient — never fatal, never signs the user out
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
      if (profile != null) {
        await _secure.write(key: _kProfile, value: jsonEncode(profile));
        return profile;
      }
      // Session is IN — an offline/flaky profile fetch must not bounce the
      // user back to the sign-in WebView. Fall back to the cached profile or
      // a minimal identity; the real profile re-fetches once online.
      final cached = await cachedProfile();
      return cached ?? {'id': user.id};
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
