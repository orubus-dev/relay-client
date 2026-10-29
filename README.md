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
