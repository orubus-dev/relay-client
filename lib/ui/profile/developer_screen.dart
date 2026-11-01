import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../core/constants.dart';
import '../../data/crypto/crypto_store.dart';
import '../../data/local/local_db.dart';
import '../../state/providers.dart';
import 'sync_vault_card.dart';

/// Profile → Developer: E2EE identity diagnostics, local store stats and the
/// session-recovery tool. Mirrors the web client's Settings → Developer tab.
class DeveloperScreen extends ConsumerStatefulWidget {
  const DeveloperScreen({super.key});

  @override
  ConsumerState<DeveloperScreen> createState() => _DeveloperScreenState();
}

class _DeveloperScreenState extends ConsumerState<DeveloperScreen> {
  String _fingerprint = '…';
  String _createdAt = '-';
  int _spkId = -1;
  int _opks = -1;
  int _sessions = -1;
  int _messages = -1;
  int _chats = -1;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  /// SHA-256 over the identity public key, hexed and grouped — the same
  /// "compare over another channel" verification idea as the web client.
  static Future<String> _fingerprintOf(Uint8List publicKey) async {
    final hash = await Sha256().hash(publicKey);
    final hex = hash.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    return RegExp('.{1,4}').allMatches(hex).map((m) => m.group(0)).join(' ');
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final profileId = ref.read(apiProvider).myProfileId;
      if (profileId == null || profileId.isEmpty) {
        throw StateError('Not signed in — no profile id.');
      }
      final store = ref.read(cryptoStoreProvider);
      final identity = await store.getIdentity(profileId);
      if (identity != null) {
        _fingerprint = await _fingerprintOf(identity.ik.publicKey);
        _createdAt = identity.createdAt;
        _spkId = identity.spkId;
        _opks = identity.opks.length;
      } else {
        _fingerprint = 'identity not initialised yet';
      }
      final sessions = Hive.isBoxOpen(HiveCryptoStore.sessionsBoxName)
          ? Hive.box(HiveCryptoStore.sessionsBoxName)
          : await Hive.openBox(HiveCryptoStore.sessionsBoxName);
      final db = ref.read(localDbProvider);
      if (!mounted) return;
      setState(() {
        _sessions = sessions.length;
        _messages = db.messageCount();
        _chats = db.chatCount();
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Developer',
            style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
              onPressed: _busy ? null : _load,
              icon: const Icon(Icons.refresh_rounded)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Card(
            title: 'END-TO-END ENCRYPTION IDENTITY',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _row('Safety fingerprint', _fingerprint, mono: true),
                _row('Signed prekey ID', _spkId < 0 ? '-' : '$_spkId'),
                _row('One-time prekeys', _opks < 0 ? '-' : '$_opks'),
                _row('Identity created', _createdAt.isEmpty ? '-' : _createdAt),
                _row('Protocol',
                    'X3DH + Double Ratchet (R1 direct / R2 fan-out)'),
                const SizedBox(height: 8),
                Text(
                  'Compare the safety fingerprint with your contact over another channel. '
                  'Identical on both devices = no man in the middle.',
                  style: TextStyle(
                      fontSize: 11, color: theme.hintColor, height: 1.45),
                ),
              ],
            ),
          ),
          _Card(
            title: 'LOCAL STORES',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _row('Ratchet sessions (Hive)',
                    _sessions < 0 ? '-' : '$_sessions'),
                _row('Cached chats (SQLite)', _chats < 0 ? '-' : '$_chats'),
                _row('Cached messages (SQLite)',
                    _messages < 0 ? '-' : '$_messages'),
              ],
            ),
          ),
          _Card(
            title: 'BUILD',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _row('Version', RelayConfig.appVersion),
                _row('Package', RelayConfig.packageName, mono: true),
                _row(
                    'Backend project',
                    RelayConfig.hasBackendCredentials
                        ? RelayConfig.supabaseRef
                        : 'not configured'),
                _row(
                    'Platform',
                    theme.platform == TargetPlatform.windows
                        ? 'Windows'
                        : 'Android'),
              ],
            ),
          ),
          _Card(
            title: 'RECOVERY',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Reset ALL ratchet sessions while keeping your identity keys. Use this if a '
                  'conversation shows undecryptable messages — the next message in each chat '
                  're-runs the key agreement automatically.',
                  style: TextStyle(
                      fontSize: 11, color: theme.hintColor, height: 1.45),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.redAccent),
                  icon: const Icon(Icons.warning_amber_rounded, size: 18),
                  label: const Text('Reset E2EE sessions'),
                  onPressed:
                      _busy ? null : () => _confirmResetSessions(context),
                ),
              ],
            ),
          ),
          const SyncVaultCard(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!,
                  style:
                      const TextStyle(fontSize: 11, color: Colors.redAccent)),
            ),
        ],
      ),
    );
  }

  Future<void> _confirmResetSessions(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset E2EE sessions?'),
        content: const Text(
          'Every ratchet session on this device is discarded and will be '
          're-established on the next message. Your identity keys, account and '
          'on-screen history are kept.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Reset')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final sessions = Hive.isBoxOpen(HiveCryptoStore.sessionsBoxName)
          ? Hive.box(HiveCryptoStore.sessionsBoxName)
          : await Hive.openBox(HiveCryptoStore.sessionsBoxName);
      await sessions.clear();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Sessions reset — open each chat to re-establish keys')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  Widget _row(String label, String value, {bool mono = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 148,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey)),
          ),
          Expanded(
            child: Text(value,
                textAlign: TextAlign.right,
                style: TextStyle(
                    fontSize: 12, fontFamily: mono ? 'monospace' : null)),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(18),
        border:
            Border.all(color: Theme.of(context).dividerColor.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                  color: Colors.grey)),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}
