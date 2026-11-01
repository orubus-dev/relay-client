/**
 * Relay client core constants.
 */
class RelayConfig {
  /// Backend (same Supabase project as the web client — ciphertext-only).
  ///
  /// Credentials are injected at BUILD time via --dart-define and never live
  /// in the repository:
  ///   --dart-define=RELAY_SUPABASE_URL=https://<ref>.supabase.co
  ///   --dart-define=RELAY_SUPABASE_ANON_KEY=<anon key>
  /// CI reads them from GitHub Actions secrets (RELAY_SUPABASE_URL /
  /// RELAY_SUPABASE_ANON_KEY). The anon key is a public client credential and
  /// still ends up in the compiled binary — keeping it out of git is repo
  /// hygiene, not a security boundary; RLS is the boundary.
  static const String supabaseUrl = String.fromEnvironment('RELAY_SUPABASE_URL');
  static const String supabaseAnonKey = String.fromEnvironment('RELAY_SUPABASE_ANON_KEY');

  // A getter, not a const: String.isNotEmpty is not a constant expression.
  static bool get hasBackendCredentials =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  /// Web app the WebView auth flow runs against (signup / OTP / Continue with
  /// Google all handled there — zero native OAuth configuration needed).
  static const String authBaseUrl = 'https://relayid.vercel.app';

  /// Project ref parsed from [supabaseUrl] — the WebView session bridge keys
  /// its localStorage lookups on it (sb-<ref>-auth-token). Never hardcode the
  /// ref again; a backend change updates it in exactly one place.
  static String get supabaseRef => Uri.parse(supabaseUrl).host.split('.').first;

  static const String packageName = 'app.orubus.relay';
  static const String appName = 'Relay';

  /// Keep in sync with pubspec.yaml `version:` — shown in Profile → Developer.
  static const String appVersion = '1.0.12+1102';
}

/// E2EE wire-format constants — MUST match the web client exactly.
class E2ee {
  static const String dmPrefix = 'R1:'; // single envelope (DMs)
  static const String fanoutPrefix = 'R2:'; // per-recipient envelopes (groups)
  static const List<int> rootInfo = [
    0x52, 0x65, 0x6c, 0x61, 0x79, 0x44, 0x52, 0x52, 0x6f, 0x6f, 0x74, 0x4b, 0x65, 0x79, 0x76, 0x31 // "RelayDRRootKeyv1"
  ];
}
