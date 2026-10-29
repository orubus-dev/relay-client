import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../data/api/relay_api.dart';
import '../data/auth/auth_repository.dart';
import '../data/crypto/crypto_store.dart';
import '../data/crypto/e2ee_service.dart';
import '../data/local/local_db.dart';
import '../data/local/sync_engine.dart';
import '../services/voice_recorder.dart';

// ---------------- infra (singletons) ----------------

final authRepositoryProvider = Provider<AuthRepository>((ref) => AuthRepository());

final cryptoStoreProvider = Provider<CryptoStore>((ref) => HiveCryptoStore());

final e2eeProvider = Provider<E2eeService>((ref) {
  final auth = ref.watch(authRepositoryProvider);
  return E2eeService(sb: auth.client, store: ref.watch(cryptoStoreProvider));
});

final apiProvider = Provider<RelayApi>((ref) {
  final auth = ref.watch(authRepositoryProvider);
  return RelayApi(sb: auth.client, e2ee: ref.watch(e2eeProvider));
});

final localDbProvider = Provider<LocalDb>((ref) => LocalDb());

final syncEngineProvider = Provider<SyncEngine>((ref) {
  return SyncEngine(api: ref.watch(apiProvider), db: ref.watch(localDbProvider));
});

final voiceRecorderProvider = Provider<VoiceRecorder>((ref) => VoiceRecorder());

// ---------------- auth ----------------

class AuthState {
  final bool ready;
  final bool signedIn;
  final Map<String, dynamic>? profile;
  const AuthState({this.ready = false, this.signedIn = false, this.profile});
}

class AuthController extends StateNotifier<AuthState> {
  final Ref ref;
  AuthController(this.ref) : super(const AuthState());

  Future<void> bootstrap() async {
    final db = ref.read(localDbProvider);
    try {
      await db.init();
    } catch (_) {}
    try {
      final store = ref.read(cryptoStoreProvider);
      if (store is HiveCryptoStore) await store.init();
    } catch (_) {}
    final auth = ref.read(authRepositoryProvider);
    final profile = await auth.restore();
    if (profile != null) {
      final sync = ref.read(syncEngineProvider);
      await sync.bootstrap();
      state = AuthState(ready: true, signedIn: true, profile: profile);
    } else {
      state = AuthState(ready: true, signedIn: false);
    }
  }

  Future<void> onWebViewSession(Map<String, dynamic> profile) async {
    final sync = ref.read(syncEngineProvider);
    await sync.bootstrap();
    state = AuthState(ready: true, signedIn: true, profile: profile);
  }

  Future<void> refreshProfile() async {
    final api = ref.read(apiProvider);
    final id = api.myProfileId;
    if (id == null) return;
    final profile = await api.fetchProfile(id);
    if (profile != null) {
      state = AuthState(ready: true, signedIn: true, profile: profile);
    }
  }

  Future<void> signOut() async {
    await ref.read(authRepositoryProvider).signOut();
    await ref.read(localDbProvider).wipe();
    state = const AuthState(ready: true, signedIn: false);
  }
}

final authControllerProvider = StateNotifierProvider<AuthController, AuthState>((ref) => AuthController(ref));

// ---------------- theme (accent-driven) ----------------

class ThemeState {
  final int accentValue;
  final String themeModeId; // system | light | dark | pure-black
  const ThemeState({this.accentValue = 0xFF2563EB, this.themeModeId = 'dark'});

  Color get accent => Color(accentValue);
  ThemeMode get materialMode {
    switch (themeModeId) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
      case 'pure-black':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  bool get pureBlack => themeModeId == 'pure-black';

  ThemeState copyWith({int? accentValue, String? themeModeId}) =>
      ThemeState(accentValue: accentValue ?? this.accentValue, themeModeId: themeModeId ?? this.themeModeId);
}

class ThemeController extends StateNotifier<ThemeState> {
  ThemeController() : super(const ThemeState());

  Future<void> setAccent(int value) async {
    state = state.copyWith(accentValue: value);
    // persist with the account so web + client stay in sync
    try {
      final api = _ref?.read(apiProvider);
      final id = api?.myProfileId;
      if (api != null && id != null) {
        await api.updateProfile(id, {'theme_preference': value.toRadixString(16)});
      }
    } catch (_) {}
  }

  Ref? _ref;

  Future<void> setThemeMode(String id) => Future.value(state = state.copyWith(themeModeId: id));
}

final themeControllerProvider = StateNotifierProvider<ThemeController, ThemeState>((ref) {
  final c = ThemeController();
  c._ref = ref;
  return c;
});

// ---------------- chats (reads the LOCAL database) ----------------

class ChatsController extends StateNotifier<List<Map<String, Object?>>> {
  final Ref ref;
  ChatsController(this.ref) : super(const []);

  void reload() {
    state = ref.read(localDbProvider).listChats();
  }

  Future<void> markReadAndReload(String chatId) async {
    ref.read(localDbProvider).clearUnread(chatId);
    reload();
    try {
      await ref.read(apiProvider).markRead(chatId);
    } catch (_) {}
  }
}

final chatsControllerProvider = StateNotifierProvider<ChatsController, List<Map<String, Object?>>>(
  (ref) => ChatsController(ref),
);

// ---------------- notifications ----------------

class NotificationsController extends StateNotifier<List<Map<String, dynamic>>> {
  final Ref ref;
  NotificationsController(this.ref) : super(const []);

  Future<void> reload() async {
    try {
      state = await ref.read(apiProvider).fetchNotifications();
    } catch (_) {}
  }

  Future<void> markAllRead() async {
    await ref.read(apiProvider).markAllNotificationsRead();
    await reload();
  }
}

final notificationsControllerProvider =
    StateNotifierProvider<NotificationsController, List<Map<String, dynamic>>>(
  (ref) => NotificationsController(ref),
);

// ---------------- app constants passthrough ----------------

const kAppUrl = RelayConfig.authBaseUrl;
