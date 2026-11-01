import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/crypto/crypto_store.dart';
import '../../data/crypto/signal_protocol.dart';
import '../../data/sync/sync_vault.dart';
import '../../state/providers.dart';

/// Developer → Cloud sync (zero-knowledge vault).
///
/// The universal key is generated on this device and wrapped with the sync
/// passphrase (PBKDF2-SHA-256, 650k iterations); every record is sealed with
/// a fresh key that only opens through the UK → SK channel. The server
/// stores wrapped keys + ciphertext and can decrypt nothing. Byte-compatible
/// with the web client: a vault made on web unlocks here and vice versa.
class SyncVaultCard extends ConsumerStatefulWidget {
  const SyncVaultCard({super.key});

  @override
  ConsumerState<SyncVaultCard> createState() => _SyncVaultCardState();
}

class _SyncVaultCardState extends ConsumerState<SyncVaultCard> {
  VaultMeta? _meta;
  String? _backendNote;
  String? _msg;
  bool _busy = false;
  bool _obscure = true;
  final _passController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    _passController.dispose();
    super.dispose();
  }

  SyncVault? _vault() {
    final api = ref.read(apiProvider);
    final profileId = api.myProfileId;
    if (profileId == null || profileId.isEmpty) return null;
    return SyncVault(sb: api.sb, profileId: profileId);
  }

  Future<void> _refresh() async {
    final vault = _vault();
    if (vault == null) {
      setState(() {
        _meta = null;
        _msg = 'Not signed in — no profile id.';
      });
      return;
    }
    try {
      final meta = await vault.getVaultMeta();
      if (!mounted) return;
      setState(() {
        _meta = meta;
        _backendNote = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (SyncVault.isMissingTableError(e)) {
        setState(() {
          _meta = const VaultMeta(status: VaultStatus.missing);
          _backendNote =
              'Sync tables are not on the backend yet — the admin needs to run '
              'supabase/migrations/20261101120000_sync_vault.sql on the Relay project.';
        });
      } else {
        setState(() {
          _meta = null;
          _msg = '$e';
        });
      }
    }
  }

  void _hint(String text) {
    if (!mounted) return;
    setState(() => _msg = text);
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted && _msg == text) setState(() => _msg = null);
    });
  }

  Future<void> _guarded(
      Future<void> Function(SyncVault vault) fn, String done) async {
    final vault = _vault();
    if (vault == null) return _hint('Not signed in.');
    setState(() => _busy = true);
    try {
      await fn(vault);
      _hint(done);
      await _refresh();
    } catch (e) {
      final text = '$e';
      final wrongPass = _meta?.status == VaultStatus.locked &&
          (text.contains('failed') ||
              text.toLowerCase().contains('auth') ||
              text.contains('decrypt'));
      _hint(wrongPass ? 'Wrong passphrase — try again.' : text);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setup() async {
    final pass = _passController.text;
    if (pass.length < 8)
      return _hint('Passphrase needs at least 8 characters.');
    await _guarded((vault) async {
      await vault.setupVault(pass);
      _passController.clear();
    }, 'Encrypted sync is on.');
  }

  Future<void> _unlock() async {
    await _guarded((vault) async {
      await vault.unlockVault(_passController.text);
      _passController.clear();
    }, 'Vault unlocked.');
  }

  Future<void> _backupIdentity() async {
    await _guarded((vault) async {
      final store = ref.read(cryptoStoreProvider);
      final profileId = vault.profileId;
      final identity = await store.getIdentity(profileId);
      if (identity == null)
        throw StateError('No E2EE identity on this device yet.');
      await vault.vaultPut('identity', 'signal_v1', identity.toJson());
    }, 'E2EE identity backed up (end-to-end encrypted).');
  }

  Future<void> _restoreIdentity() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore identity from vault?'),
        content: const Text(
          'The encrypted identity bundle from your vault replaces the local one. '
          'Use this after reinstalling or when this device lost its keys.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Restore')),
        ],
      ),
    );
    if (ok != true) return;
    await _guarded((vault) async {
      final data = await vault.vaultGet('identity', 'signal_v1');
      if (data == null)
        throw StateError(
            'No identity backup in the vault yet — back one up first.');
      final store = ref.read(cryptoStoreProvider);
      await store.setIdentity(
        vault.profileId,
        LocalIdentity.fromJson(Map<String, dynamic>.from(data as Map)),
      );
    }, 'E2EE identity restored from your encrypted backup.');
  }

  Future<void> _changePassphrase() async {
    final oldCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Change sync passphrase'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: oldCtrl,
              obscureText: true,
              decoration:
                  const InputDecoration(labelText: 'Current passphrase'),
            ),
            TextField(
              controller: newCtrl,
              obscureText: true,
              decoration:
                  const InputDecoration(labelText: 'New passphrase (min 8)'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Change')),
        ],
      ),
    );
    if (ok != true) return;
    if (newCtrl.text.length < 8)
      return _hint('New passphrase needs at least 8 characters.');
    await _guarded((vault) async {
      await vault.changePassphrase(oldCtrl.text, newCtrl.text);
    }, 'Passphrase changed — keys re-wrapped in place.');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = switch (_meta?.status) {
      VaultStatus.unlocked => 'unlocked',
      VaultStatus.locked => 'locked',
      VaultStatus.missing => 'not set up',
      null => _busy ? 'checking…' : 'unavailable',
    };
    final unlocked = _meta?.status == VaultStatus.unlocked;

    return _VaultCard(
      title: 'CLOUD SYNC — ZERO-KNOWLEDGE VAULT',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row('Vault', status),
          if (_meta?.createdAt != null)
            _row('Created',
                _meta!.createdAt!.substring(0, 19).replaceAll('T', ' ')),
          const SizedBox(height: 4),
          Text(
            'Passphrase-wrapped universal key (PBKDF2-SHA-256, 650k iterations), '
            'per-space channel keys, a fresh key per record. The server can decrypt '
            'nothing. Same vault on web and Android — same passphrase.',
            style:
                TextStyle(fontSize: 11, color: theme.hintColor, height: 1.45),
          ),
          const SizedBox(height: 10),
          if (_backendNote != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange.withOpacity(0.4)),
              ),
              child: Text(_backendNote!,
                  style: const TextStyle(fontSize: 11, color: Colors.orange)),
            ),
          if (_meta?.status == VaultStatus.missing && _backendNote == null) ...[
            TextField(
              controller: _passController,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'Sync passphrase (min 8 characters)',
                suffixIcon: IconButton(
                  icon: Icon(
                      _obscure
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded,
                      size: 18),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _busy ? null : _setup,
              icon: const Icon(Icons.key_rounded, size: 18),
              label: const Text('Create vault'),
            ),
            const SizedBox(height: 6),
            Text(
              'No recovery by design — the passphrase is the only key. Lose it and '
              'the encrypted backups are unrecoverable.',
              style:
                  TextStyle(fontSize: 11, color: theme.hintColor, height: 1.45),
            ),
          ],
          if (_meta?.status == VaultStatus.locked) ...[
            TextField(
              controller: _passController,
              obscureText: _obscure,
              onSubmitted: (_) => _busy ? null : _unlock(),
              decoration: InputDecoration(
                labelText: 'Sync passphrase',
                suffixIcon: IconButton(
                  icon: Icon(
                      _obscure
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded,
                      size: 18),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _unlock,
                  icon: const Icon(Icons.lock_open_rounded, size: 18),
                  label: const Text('Unlock'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _changePassphrase,
                  icon: const Icon(Icons.password_rounded, size: 18),
                  label: const Text('Change passphrase'),
                ),
              ],
            ),
          ],
          if (unlocked) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _backupIdentity,
                  icon: const Icon(Icons.cloud_upload_rounded, size: 18),
                  label: const Text('Back up E2EE identity'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _restoreIdentity,
                  icon: const Icon(Icons.cloud_download_rounded, size: 18),
                  label: const Text('Restore here'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _changePassphrase,
                  icon: const Icon(Icons.password_rounded, size: 18),
                  label: const Text('Change passphrase'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _guarded((vault) => vault.lockVault(),
                          'Vault locked — keys wiped from memory.'),
                  icon: const Icon(Icons.lock_rounded, size: 18),
                  label: const Text('Lock'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Space identity · record signal_v1 — your X3DH identity bundle travels '
              'as ciphertext. After a reinstall: sign in, unlock with the passphrase, '
              'Restore here — history stays decryptable.',
              style:
                  TextStyle(fontSize: 11, color: theme.hintColor, height: 1.45),
            ),
          ],
          if (_msg != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_msg!,
                  style: const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w600)),
            ),
        ],
      ),
    );
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

/// Local card shell mirroring the developer screen's `_Card` (kept private to
/// this library so the two files stay independent).
class _VaultCard extends StatelessWidget {
  const _VaultCard({required this.title, required this.child});
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
