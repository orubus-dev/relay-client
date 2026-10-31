import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/constants.dart';
import 'core/theme.dart';
import 'state/providers.dart';
import 'ui/auth/auth_webview_screen.dart';
import 'ui/home_shell.dart';

class RelayApp extends ConsumerWidget {
  const RelayApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeControllerProvider);
    return MaterialApp(
      title: RelayConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: RelayTheme.light(theme.accent),
      darkTheme: RelayTheme.dark(theme.accent, pureBlack: theme.pureBlack),
      themeMode: theme.materialMode,
      home: const _Root(),
    );
  }
}

class _Root extends ConsumerWidget {
  const _Root();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    if (!auth.ready) {
      return const _Splash();
    }
    if (!auth.signedIn) {
      return AuthWebViewScreen(
        auth: ref.read(authRepositoryProvider),
        onAuthenticated: (profile) => ref.read(authControllerProvider.notifier).onWebViewSession(profile),
      );
    }
    return const HomeShell();
  }
}

class _Splash extends ConsumerStatefulWidget {
  const _Splash();

  @override
  ConsumerState<_Splash> createState() => _SplashState();
}

class _SplashState extends ConsumerState<_Splash> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(authControllerProvider.notifier).bootstrap());
  }

  @override
  Widget build(BuildContext context) {
    final accent = ref.watch(themeControllerProvider).accent;
    // Background pinned to the native splash color (#0B1220 — see
    // flutter_native_splash.yaml) so the launch screen → first Flutter frame
    // hand-off is seamless: same brand dark, no flash, in EITHER theme mode.
    return Scaffold(
      backgroundColor: const Color(0xFF0B1220),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Icon(Icons.bolt_rounded, color: Colors.white, size: 36),
            ),
            const SizedBox(height: 16),
            Text(
              RelayConfig.appName.toUpperCase(),
              style: const TextStyle(letterSpacing: 4, fontWeight: FontWeight.w800, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
