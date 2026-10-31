// Smoke test — build-time invariants of the client config.
//
// The previous widget test referenced `MyApp`, a class that no longer exists
// in main.dart (the app uses a runZonedGuarded crash shell + RelayApp), so it
// could never compile. These tests run without platform bindings and pin the
// production-critical constants.
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_client/core/constants.dart';

void main() {
  test('RelayConfig points at the production backend + web auth surface', () {
    expect(RelayConfig.authBaseUrl, 'https://relayid.vercel.app');
    expect(RelayConfig.appName, 'Relay');
    expect(RelayConfig.packageName, 'app.orubus.relay');
    expect(RelayConfig.supabaseUrl, startsWith('https://'));
  });

  test('supabaseRef is derived from supabaseUrl (no hardcoded ref)', () {
    final host = Uri.parse(RelayConfig.supabaseUrl).host;
    expect(RelayConfig.supabaseRef, host.split('.').first);
    expect(RelayConfig.supabaseRef, isNotEmpty);
  });
}
