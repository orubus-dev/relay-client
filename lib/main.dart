import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'data/local/local_db.dart';
import 'state/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = LocalDb();
  try {
    await db.init();
  } catch (_) {
    // desktop storage may be unavailable in early CI runs — keep the app alive
  }

  runApp(
    ProviderScope(
      overrides: [localDbProvider.overrideWithValue(db)],
      child: const RelayApp(),
    ),
  );
}
