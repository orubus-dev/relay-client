/**
 * Relay client core constants.
 */
class RelayConfig {
  /// Backend (same Supabase project as the web client — ciphertext-only).
  static const String supabaseUrl = 'https://gobwknacvpgysmgpvzqt.supabase.co';
  static const String supabaseAnonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdvYndrbmFjdnBneXNtZ3B2enF0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODEwMTk5MzUsImV4cCI6MjA5NjU5NTkzNX0.1PsVy5VJiTr2vp7Qfj4zBEfBWHYrR6mvfqTkcZl48N4';

  /// Web app the WebView auth flow runs against (signup / OTP / Continue with
  /// Google all handled there — zero native OAuth configuration needed).
  static const String authBaseUrl = 'https://relayid.vercel.app';

  /// Project ref parsed from [supabaseUrl] — the WebView session bridge keys
  /// its localStorage lookups on it (sb-<ref>-auth-token). Never hardcode the
  /// ref again; a backend change updates it in exactly one place.
  static String get supabaseRef => Uri.parse(supabaseUrl).host.split('.').first;

  static const String packageName = 'app.orubus.relay';
  static const String appName = 'Relay';
}

/// E2EE wire-format constants — MUST match the web client exactly.
class E2ee {
  static const String dmPrefix = 'R1:'; // single envelope (DMs)
  static const String fanoutPrefix = 'R2:'; // per-recipient envelopes (groups)
  static const List<int> rootInfo = [
    0x52, 0x65, 0x6c, 0x61, 0x79, 0x44, 0x52, 0x52, 0x6f, 0x6f, 0x74, 0x4b, 0x65, 0x79, 0x76, 0x31 // "RelayDRRootKeyv1"
  ];
}
