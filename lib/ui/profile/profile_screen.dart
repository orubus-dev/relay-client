import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../state/providers.dart';

/// Profile — accent color + theme mode (icon follows the accent via themed
/// adaptive icons), username with server-side availability checks, sign out.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _usernameCtrl = TextEditingController();
  String? _usernameMsg;
  bool _checking = false;
  bool _available = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final profile = ref.read(authControllerProvider).profile;
      _usernameCtrl.text = (profile?['username'] ?? '') as String;
    });
  }

  Future<void> _checkUsername(String v) async {
    final handle = v.trim().toLowerCase().replaceAll(RegExp(r'^@+'), '');
    if (handle.isEmpty) {
      setState(() { _usernameMsg = null; _available = true; });
      return;
    }
    if (handle.length < 3 || handle.length > 20 || !RegExp(r'^[a-z0-9_]+$').hasMatch(handle)) {
      setState(() { _checking = false; _available = false; _usernameMsg = '3–20 chars, a-z 0-9 _ only'; });
      return;
    }
    setState(() => _checking = true);
    try {
      final ok = await ref.read(apiProvider).usernameAvailable(handle);
      setState(() {
        _checking = false;
        _available = ok;
        _usernameMsg = ok ? 'Username is available' : 'Username taken';
      });
    } catch (_) {
      setState(() { _checking = false; _usernameMsg = null; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(themeControllerProvider);
    final auth = ref.watch(authControllerProvider);
    final profile = auth.profile ?? const {};

    return Scaffold(
      appBar: AppBar(title: const Text('Profile', style: TextStyle(fontWeight: FontWeight.w800))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // identity card
          Row(
            children: [
              CircleAvatar(
                radius: 30,
                backgroundColor: theme.accent.withOpacity(0.15),
                backgroundImage: profile['avatar_url'] != null ? NetworkImage(profile['avatar_url'] as String) : null,
                child: profile['avatar_url'] == null
                    ? Text((profile['display_name'] ?? 'U').toString().substring(0, 1).toUpperCase(),
                        style: TextStyle(color: theme.accent, fontWeight: FontWeight.w800, fontSize: 20))
                    : null,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text((profile['display_name'] ?? 'User') as String,
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                    Text('@${profile['username'] ?? ''}', style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // appearance
          const Text('ACCENT COLOR', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: Colors.grey)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final a in kAccents)
                GestureDetector(
                  onTap: () => ref.read(themeControllerProvider).setAccent(a.value),
                  child: Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: a.color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: theme.accentValue == a.value ? (Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black) : Colors.transparent,
                        width: 3,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 18),
          const Text('THEME', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: Colors.grey)),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: [
              for (final m in kThemeModes) ButtonSegment(value: m.id, label: Text(m.label, style: const TextStyle(fontSize: 11))),
            ],
            selected: {theme.themeModeId},
            onSelectionChanged: (s) => ref.read(themeControllerProvider).setThemeMode(s.first),
          ),
          const SizedBox(height: 20),

          // username
          const Text('USERNAME', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: Colors.grey)),
          const SizedBox(height: 8),
          TextField(
            controller: _usernameCtrl,
            onChanged: _checkUsername,
            decoration: InputDecoration(
              prefixText: '@ ',
              suffixIcon: _checking
                  ? const SizedBox(width: 18, height: 18, child: Padding(padding: EdgeInsets.all(10), child: CircularProgressIndicator(strokeWidth: 2)))
                  : Icon(_available ? Icons.check_circle_rounded : Icons.cancel_rounded,
                      size: 18, color: _available ? Colors.green : Colors.redAccent),
              helperText: _usernameMsg,
              helperStyle: TextStyle(color: _available ? Colors.green : Colors.redAccent),
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: (!_available || _checking)
                ? null
                : () async {
                    await ref.read(apiProvider).updateProfile(
                      ref.read(apiProvider).myProfileId!,
                      {'username': _usernameCtrl.text.trim().toLowerCase()},
                    );
                    await ref.read(authControllerProvider.notifier).refreshProfile();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Username saved')));
                    }
                  },
            child: const Text('Save username'),
          ),

          const SizedBox(height: 28),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent),
            onPressed: () => ref.read(authControllerProvider.notifier).signOut(),
            icon: const Icon(Icons.logout_rounded, size: 18),
            label: const Text('Sign out'),
          ),
          const SizedBox(height: 10),
          const Center(child: Text('Relay · app.orubus.relay', style: TextStyle(fontSize: 10, color: Colors.grey))),
        ],
      ),
    );
  }
}
