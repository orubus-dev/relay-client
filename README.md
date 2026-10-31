# Relay Client (Flutter — Android + Windows)

Unified Flutter/Dart codebase for the Relay messenger: Signal-grade E2EE,
WhatsApp-style voice notes, Discord-style community channels, local-first
message database.

- **Package name:** `app.orubus.relay`
- **Web app:** https://relayid.vercel.app (same backend, same E2EE wire format)

## Auth — WebView (zero native OAuth setup)

Sign-in opens the production web app in a WebView. **Continue with Google,
email OTP, password reset — all work out of the box** because the flows run on
the web app; the client just captures the Supabase session via a JS bridge
(`localStorage sb-<ref>-auth-token` → secure storage) and continues into the
app. No SHA-1 fingerprints, no consent screens, no platform-specific config.

## Local-first messages

`lib/data/local/local_db.dart` (SQLite via `sqlite3_flutter_libs`) is the
device source of truth. The network only contributes **new** messages:
cursor-based sync (`sync_cursor` table) + realtime INSERTs. Opening a chat
never re-downloads history.

## E2EE (wire-compatible with the web client)

`lib/data/crypto/signal_protocol.dart` is a byte-faithful Dart port of the web
client's X3DH + Double Ratchet (X25519/Ed25519, HKDF-SHA256, AES-256-GCM,
identical info strings and AAD). DMs send single `R1:` envelopes; groups and
community channels fan out per-recipient `R2:` envelopes so every member can
decrypt. Identity keys live in a Hive store, never leave the device.

## Accent-driven icon

`assets/icon/` ships the accent-tinted icon plus an Android 13 **monochrome**
layer — on Android 13+ the launcher icon follows the system themed-icon tint,
and the in-app accent (Profile → Accent color) recolors the whole UI. Change
the build-time accent by regenerating with the accent hex in
`assets/icon` (see `flutter_launcher_icons` in pubspec).

## CI

- `.github/workflows/android.yml` — signed APK/AAB on every push; release on
  `v*` tags. Required secrets:
  | Secret | Value |
  |---|---|
  | `KEYSTORE_BASE64` | `base64 -w0 relay-release.jks` |
  | `KEYSTORE_PASSWORD` | keystore password |
  | `KEY_ALIAS` | key alias |
  | `KEY_PASSWORD` | key password |
  Missing secrets → unsigned release build (CI never hard-fails).

- `.github/workflows/windows.yml` — zipped Windows release build.

Create the keystore once:

```bash
keytool -genkey -v -keystore relay-release.jks -keyalg RSA -keysize 2048 \
  -validity 10000 -alias relay
base64 -w0 relay-release.jks   # -> KEYSTORE_BASE64
```

## Run

```bash
flutter pub get
flutter run                 # android
flutter config --enable-windows-desktop
flutter run -d windows      # windows
```

## Changelog

### v1.0.9+1090
- **Brand splash** — native launch screen (flutter_native_splash) now shows the
  Relay signal mark centered on `#0B1220`; the first Flutter frame uses the
  same background so there is no flash. Android 12+ uses the adaptive-icon
  layers on the same brand color.
- **Crash hardening** — proguard-rules.pro keeps for every reflection-heavy
  plugin (inappwebview, record, just_audio, permission_handler),
  `proguardFiles` wired into the release buildType, minSdk raised to 24,
  defensive parsing of server JSON in the sync engine, trim-safe avatar
  initials (a whitespace-only name could throw inside build), realtime
  message ingestion wrapped so a bad row can't kill the chat.
- **Manifest permissions** — RECORD_AUDIO, CAMERA, media reader grants,
  POST_NOTIFICATIONS, VIBRATE, MODIFY_AUDIO_SETTINGS, BLUETOOTH_CONNECT,
  WAKE_LOCK (+ optional camera `<uses-feature>`) inserted by the CI patch
  script; fixes the mic-permission false positive and enables the in-app
  camera.
- **Mic ground truth** — granted/limited both count as usable; a tappable
  hint re-fires the OS dialog when merely un-asked and opens app settings
  only when the permission was permanently denied.
- **Google sign-up in-app** — the entire flow (auth page → Google consent →
  session capture) navigates inside the app's own full-screen WebView; the
  localStorage bridge key is now derived from the configured Supabase ref.
- **SQLite cache verified end-to-end** — chats render instantly from the
  device DB; only NEW messages cross the wire (cursor-based sync), history
  stays readable in airplane mode.
- **Offline keeps you signed in** — a cold start without network re-enters
  with the cached session and refreshes tokens in the background; sign-out
  happens only on an explicit auth rejection (invalid refresh token).
- **Chat scroll rebuilt** — the message list is bottom-anchored
  (`reverse: true`) with always-scrollable physics; no more stuck/jumpy
  scrolling in conversations.

