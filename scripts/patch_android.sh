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

# --- minSdk 24 (crash hardening) ---
# The flutter template sets minSdk = flutter.minSdkVersion (21 on current
# stable). record_android and just_audio need >= 23; 24 is the safe floor and
# covers 99.9% of devices. Idempotent: re-running always yields 24.
sed -i.bak -E 's|minSdk = [a-zA-Z0-9_.*]+|minSdk = 24|g; s|minSdkVersion [a-zA-Z0-9_.*]+|minSdkVersion 24|g' "$GRADLE_FILE"
rm -f "$GRADLE_FILE.bak"
grep -qE 'minSdk( = |Version )?24' "$GRADLE_FILE" && echo "minSdk raised to 24" || echo "::warning::failed to set minSdk=24"

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

  # Relay runtime permissions — inserted as one idempotent marker-keyed block
  # right after <manifest>. Covers the mic (RECORD_AUDIO — fixes the
  # "microphone permission" false positive on manifests that lack it), the
  # in-app camera, Android 13/14 media + notification grants, vibration and
  # the audio/bluetooth bits the voice room needs. The camera is OPTIONAL
  # (<uses-feature required=false>) so the app stays installable on
  # camera-less devices.
  if ! grep -q 'RELAY-PERMISSIONS-BLOCK' "$MANIFEST"; then
    sed -i.bak '0,/<manifest /s|<manifest \(.*\)>|<manifest \1>\n\n    <!-- RELAY-PERMISSIONS-BLOCK (added by scripts/patch_android.sh) -->\n    <uses-permission android:name="android.permission.INTERNET" />\n    <uses-permission android:name="android.permission.RECORD_AUDIO" />\n    <uses-permission android:name="android.permission.CAMERA" />\n    <uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />\n    <uses-permission android:name="android.permission.READ_MEDIA_VIDEO" />\n    <uses-permission android:name="android.permission.READ_MEDIA_VISUAL_USER_SELECTED" />\n    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />\n    <uses-permission android:name="android.permission.VIBRATE" />\n    <uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />\n    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />\n    <uses-permission android:name="android.permission.WAKE_LOCK" />\n    <uses-feature android:name="android.hardware.camera" android:required="false" />|' "$MANIFEST"
    rm -f "$MANIFEST.bak"
    grep -q 'RELAY-PERMISSIONS-BLOCK' "$MANIFEST" && echo "patched manifest permissions block" || echo "::warning::failed to add manifest permissions"
  fi

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
            proguardFiles getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro"
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
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
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

# --- R8 wiring (belt-and-braces, idempotent) ---
# The appended signing blocks above already carry proguardFiles; this guard
# covers the case where the append was skipped (KEYSTORE_PATH already
# defined by an earlier run) but the release block still lacks the rules file.
if ! grep -q "proguard-rules.pro" "$GRADLE_FILE"; then
  if [[ "$GRADLE_FILE" == *.kts ]]; then
    sed -i.bak 's|^\(\s*\)isMinifyEnabled = false$|\1isMinifyEnabled = false\n\1proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")|' "$GRADLE_FILE"
  else
    sed -i.bak 's|^\(\s*\)minifyEnabled false$|\1minifyEnabled false\n\1proguardFiles getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro"|' "$GRADLE_FILE"
  fi
  rm -f "$GRADLE_FILE.bak"
  grep -q "proguard-rules.pro" "$GRADLE_FILE" && echo "wired proguardFiles into release buildType" || echo "::warning::failed to wire proguardFiles"
fi

# permissive keep rules — the app ships shrunk but every Flutter plugin stays intact
PROGUARD_FILE="$(dirname "$GRADLE_FILE")/proguard-rules.pro"
if [ ! -f "$PROGUARD_FILE" ]; then
  cat > "$PROGUARD_FILE" <<'PROGUARD_EOF'
# Relay R8 rules: keep Flutter + plugin entrypoints; strip the rest.
# Release builds run with minifyEnabled=false today, but these keeps keep the
# app correct the moment R8 is turned on — every reflection-heavy plugin in
# the dependency tree is pinned here.
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class com.pichillilorenzo.** { *; }
-dontwarn com.pichillilorenzo.**
-keep class app.orubus.relay.** { *; }
-keepattributes *Annotation*

# plugin keeps (reflection-heavy plugins break under R8 without these)
-keep class dev.fluttercommunity.** { *; }
-keep class com.llfbandit.** { *; }
-keep class com.ryanheize.** { *; }
-keep class com.baseflow.** { *; }
-keep class io.inappwebview.** { *; }
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn org.slf4j.**
-dontwarn javax.naming.**
PROGUARD_EOF
fi

echo "patched $GRADLE_FILE (id: $APP_ID)"
