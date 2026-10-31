import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'data/local/local_db.dart';
import 'state/providers.dart';

/// Crash-safety shell — "keeps stopping" fix. Any uncaught async exception or
/// framework error is logged and swallowed instead of tearing the isolate
/// down; a storage failure in LocalDb can no longer produce an unguarded
/// postFrame crash either (the db degrades to no-cache, the app still runs).
Future<void> main() async {
  await runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        // ignore: avoid_print
        print('[relay] flutter error: ${details.exception}');
      };
      PlatformDispatcher.instance.onError = (error, stack) {
        // ignore: avoid_print
        print('[relay] uncaught zone error: $error');
        return true; // handled — do not crash the app
      };

      final db = LocalDb();
      try {
        await db.init();
      } catch (e) {
        // desktop storage may be unavailable in early CI runs — keep the app
        // alive (db stays closed; data layer degrades, UI still works)
        // ignore: avoid_print
        print('[relay] local db init failed: $e');
      }

      runApp(
        ProviderScope(
          overrides: [localDbProvider.overrideWithValue(db)],
          child: const RelayApp(),
        ),
      );
    },
    (error, stack) {
      // ignore: avoid_print
      print('[relay] zone error: $error');
    },
  );
}
