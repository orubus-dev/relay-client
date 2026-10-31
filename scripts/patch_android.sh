#!/usr/bin/env bash
# Idempotent Android hardening after `flutter create .`:
#  · applicationId / namespace -> app.orubus.relay
#  · signing config wired to CI secrets (falls back to debug when absent)
set -euo pipefail

APP_ID="app.orubus.relay"

GRADLE_FILE="android/app/build.gradle"
if [ ! -f "$GRADLE_FILE" ] && [ -f "android/app/build.gradle.kts" ]; then
  GRADLE_FILE="android/app/build.gradle.kts"
fi
[ -f "$GRADLE_FILE" ] || { echo "no android gradle file found"; exit 1; }

# --- applicationId / namespace ---
sed -i.bak -E "s|namespace = \"[^\"]+\"|namespace = \"$APP_ID\"|g; s|namespace '[^']+'|namespace '$APP_ID'|g" "$GRADLE_FILE"
sed -i.bak -E "s|applicationId = \"[^\"]+\"|applicationId = \"$APP_ID\"|g; s|applicationId \"[^\"]+\"|applicationId \"$APP_ID\"|g" "$GRADLE_FILE"
rm -f "$GRADLE_FILE.bak"

# --- launcher label: the app drawer must say "Relay", not the flutter
#     create project name ("relay_client") ---
# Drop the forced NDK requirement — no externalNativeBuild/jni code exists;
# AGP then skips symbol stripping instead of pulling a 3GB NDK.
APP_GRADLE="android/app/build.gradle.kts"
if [ -f "$APP_GRADLE" ]; then
  sed -i.bak 's|^\s*ndkVersion = .*||' "$APP_GRADLE"; rm -f "$APP_GRADLE.bak"
fi

# -all -> -bin wrapper dist (the -all dist is 700MB with sources/docs)
WPROPS="android/gradle/wrapper/gradle-wrapper.properties"
if [ -f "$WPROPS" ]; then
  sed -i.bak 's|-all.zip|-bin.zip|' "$WPROPS"; rm -f "$WPROPS.bak"
fi

GP="android/gradle.properties"
if [ -f "$GP" ] && ! grep -q "org.gradle.jvmargs" "$GP"; then
  cat >> "$GP" <<'GPEOF'

# memory caps for constrained CI runners (4GB)
org.gradle.jvmargs=-Xmx1536m -XX:MaxMetaspaceSize=512m
kotlin.daemon.jvmargs=-Xmx1024m
kotlin.compiler.execution.strategy=in-process
org.gradle.workers.max=1
org.gradle.parallel=false
GPEOF
  echo "patched gradle.properties (memory caps)"
fi

SETTINGS="android/settings.gradle.kts"
if [ -f "$SETTINGS" ] && ! grep -q "maven-central.storage-download" "$SETTINGS"; then
  # mirror-first plugin resolution: Maven Central 429s behind shared egress IPs
  sed -i.bak 's|repositories {|repositories {\n        maven("https://maven-central.storage-download.googleapis.com/maven2/")|' "$SETTINGS"
  rm -f "$SETTINGS.bak"
  grep -q "maven-central.storage-download" "$SETTINGS" && echo "patched settings.gradle.kts (central mirror first)" || echo "::warning::failed to patch settings repos"
fi

MANIFEST="android/app/src/main/AndroidManifest.xml"
if [ -f "$MANIFEST" ]; then
  sed -i.bak -E 's|android:label="relay_client"|android:label="Relay"|g; s|android:label="[a-z_]+"|android:label="Relay"|g' "$MANIFEST"
  rm -f "$MANIFEST.bak"
  grep -q 'android:label="Relay"' "$MANIFEST" || echo "::warning::failed to set android:label=Relay"

  # Microphone: the flutter-generated template does NOT declare RECORD_AUDIO.
  # record_android merges it via its own manifest, but belt-and-braces so the
  # permission check NEVER false-negotiates on a manifest that lacks it.
  if ! grep -q 'android.permission.RECORD_AUDIO' "$MANIFEST"; then
    sed -i.bak 's|<manifest xmlns:android="http://schemas.android.com/apk/res/android">|<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n\n    <uses-permission android:name="android.permission.RECORD_AUDIO" />|' "$MANIFEST"
    rm -f "$MANIFEST.bak"
    grep -q 'android.permission.RECORD_AUDIO' "$MANIFEST" && echo "patched RECORD_AUDIO into manifest" || echo "::warning::failed to add RECORD_AUDIO"
  fi

  # INTERNET: belt-and-braces (the webview plugin normally merges it; a
  # manifest without it = a silent offline app)
  if ! grep -q 'android.permission.INTERNET' "$MANIFEST"; then
    sed -i.bak 's|<manifest xmlns:android="http://schemas.android.com/apk/res/android">|<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n    <uses-permission android:name="android.permission.INTERNET" />|' "$MANIFEST"
    rm -f "$MANIFEST.bak"
    grep -q 'android.permission.INTERNET' "$MANIFEST" && echo "patched INTERNET into manifest" || echo "::warning::failed to add INTERNET"
  fi
fi
STRINGS="android/app/src/main/res/values/strings.xml"
if [ -f "$STRINGS" ]; then
  sed -i.bak -E 's|<string name="app_name">[^<]*</string>|<string name="app_name">Relay</string>|' "$STRINGS"
  rm -f "$STRINGS.bak"
fi

# --- signing config (groovy) ---
if [[ "$GRADLE_FILE" == *.gradle ]]; then
  grep -q "KEYSTORE_PATH" "$GRADLE_FILE" || cat >> "$GRADLE_FILE" <<'EOF'

// ==== Relay CI signing (appended by scripts/patch_android.sh) ====
def keystoreEnvPath = System.getenv("KEYSTORE_PATH")
android {
    signingConfigs {
        release {
            if (keystoreEnvPath != null) {
                storeFile file(keystoreEnvPath)
                storePassword System.getenv("KEYSTORE_PASSWORD")
                keyAlias System.getenv("KEY_ALIAS")
                keyPassword System.getenv("KEY_PASSWORD")
            }
        }
    }
    buildTypes {
        release {
            if (keystoreEnvPath != null) {
                signingConfig signingConfigs.release
            }
            // flutter 3.47 template enables R8 by default — a plugin fails
            // minifyReleaseWithR8, so force it off (size comes from split-per-abi)
            minifyEnabled false
            shrinkResources false
        }
    }
}
EOF
fi

# --- signing config (kotlin DSL) ---
if [[ "$GRADLE_FILE" == *.kts ]]; then
  grep -q "KEYSTORE_PATH" "$GRADLE_FILE" || cat >> "$GRADLE_FILE" <<'EOF'

// ==== Relay CI signing (appended by scripts/patch_android.sh) ====
val keystoreEnvPath: String? = System.getenv("KEYSTORE_PATH")
android {
    signingConfigs {
        create("relayRelease") {
            if (keystoreEnvPath != null) {
                storeFile = file(keystoreEnvPath)
                storePassword = System.getenv("KEYSTORE_PASSWORD")
                keyAlias = System.getenv("KEY_ALIAS")
                keyPassword = System.getenv("KEY_PASSWORD")
            }
        }
    }
    buildTypes {
        release {
            if (keystoreEnvPath != null) {
                signingConfig = signingConfigs.getByName("relayRelease")
            }
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
    // v1 (JAR) keeps META-INF signatures visible to lenient third-party
    // installers; v2/v3 cover Android 7+ and key rotation. Without v1 some
    // installer apps report a perfectly valid v2 APK as "unsigned".
    signingConfigs {
        named("relayRelease") {
            enableV1Signing = true
            enableV2Signing = true
            enableV3Signing = true
        }
    }
}
EOF
fi

# permissive keep rules — the app ships shrunk but every Flutter plugin stays intact
PROGUARD_FILE="$(dirname "$GRADLE_FILE")/proguard-rules.pro"
if [ ! -f "$PROGUARD_FILE" ]; then
  cat > "$PROGUARD_FILE" <<'PROGUARD_EOF'
# Relay R8 rules: keep Flutter + plugin entrypoints; strip the rest
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class com.pichillilorenzo.** { *; }
-dontwarn com.pichillilorenzo.**
-keep class app.orubus.relay.** { *; }
-keepattributes *Annotation*
PROGUARD_EOF
fi

echo "patched $GRADLE_FILE (id: $APP_ID)"
