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
MANIFEST="android/app/src/main/AndroidManifest.xml"
if [ -f "$MANIFEST" ]; then
  sed -i.bak -E 's|android:label="relay_client"|android:label="Relay"|g; s|android:label="[a-z_]+"|android:label="Relay"|g' "$MANIFEST"
  rm -f "$MANIFEST.bak"
  grep -q 'android:label="Relay"' "$MANIFEST" || echo "::warning::failed to set android:label=Relay"
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
