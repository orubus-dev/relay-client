import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';

/// Communities — Discord-style: community rail → channel sidebar (text +
/// voice), tap the top bar for the full settings screen, plus icon creates a
/// channel (text or voice).
class CommunitiesScreen extends ConsumerStatefulWidget {
  final void Function(String conversationId, String title, String type) onOpenChannelChat;

  const CommunitiesScreen({super.key, required this.onOpenChannelChat});

  @override
  ConsumerState<CommunitiesScreen> createState() => _CommunitiesScreenState();
}

class _CommunitiesScreenState extends ConsumerState<CommunitiesScreen> {
  List<Map<String, dynamic>> _communities = [];
  String? _activeCommunityId;
  List<Map<String, dynamic>> _channels = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final communities = await ref.read(apiProvider).listMyCommunities();
      setState(() {
        _communities = communities;
        _error = null;
      });
      if (_activeCommunityId != null) await _loadChannels(_activeCommunityId!);
    } catch (e) {
      setState(() => _error = 'Failed to load communities');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadChannels(String communityId) async {
    try {
      final channels = await ref.read(apiProvider).listChannels(communityId);
      setState(() => _channels = channels);
    } catch (_) {
      setState(() => _error = 'Failed to load channels');
    }
  }

  Future<void> _openChannel(Map<String, dynamic> ch) async {
    try {
      final convId = await ref.read(apiProvider).openChannelConversation(ch['id'] as String);
      widget.onOpenChannelChat(convId, '${ch['name']}', 'channel');
    } catch (_) {
      setState(() => _error = 'Failed to open channel');
    }
  }

  Future<void> _createChannel(String name, String type) async {
    if (_activeCommunityId == null) return;
    try {
      await ref.read(apiProvider).createChannel(_activeCommunityId!, name, type);
      await _loadChannels(_activeCommunityId!);
    } catch (e) {
      setState(() => _error = 'Only owners/moderators can create channels');
    }
  }

  void _showCreateChannelSheet() {
    final nameCtrl = TextEditingController();
    String type = 'text';
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Create channel', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
              const SizedBox(height: 14),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'text', icon: Icon(Icons.tag), label: Text('Text')),
                  ButtonSegment(value: 'voice', icon: Icon(Icons.volume_up_rounded), label: Text('Voice')),
                ],
                selected: {type},
                onSelectionChanged: (s) => setSheet(() => type = s.first),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(hintText: 'new-channel'),
                autofocus: true,
              ),
              const SizedBox(height: 14),
              FilledButton(
                onPressed: () {
                  final name = nameCtrl.text.trim();
                  if (name.isEmpty) return;
                  Navigator.pop(sheetCtx);
                  _createChannel(name, type);
                },
                child: const Text('Create channel'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_activeCommunityId != null) return _channelSidebar();
    return _hub();
  }

  // ---------------- hub: my communities ----------------

  Widget _hub() {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Communities', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                  ),
                if (_communities.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 60),
                    child: Center(child: Text('No communities yet', style: TextStyle(color: Colors.grey))),
                  ),
                for (final c in _communities)
                  Card(
                    elevation: 0,
                    margin: const EdgeInsets.only(bottom: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundImage: c['avatar_url'] != null ? NetworkImage(c['avatar_url'] as String) : null,
                        child: c['avatar_url'] == null
                            ? Text((c['name'] ?? 'C').toString().substring(0, 1).toUpperCase())
                            : null,
                      ),
                      title: Text((c['name'] ?? '') as String, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                      subtitle: Text((c['description'] ?? '') as String, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () {
                        setState(() => _activeCommunityId = c['id'] as String);
                        _loadChannels(c['id'] as String);
                      },
                    ),
                  ),
              ],
            ),
    );
  }

  // ---------------- inside a community: channel sidebar ----------------

  Widget _channelSidebar() {
    final community = _communities.where((c) => c['id'] == _activeCommunityId).firstOrNull;
    final textChannels = _channels.where((c) => c['channel_type'] == 'text').toList();
    final voiceChannels = _channels.where((c) => c['channel_type'] == 'voice').toList();

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => setState(() => _activeCommunityId = null),
        ),
        title: GestureDetector(
          onTap: () => _showSettingsSheet(community ?? {}),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text((community?['name'] ?? '') as String,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
              const SizedBox(width: 6),
              Icon(Icons.settings_rounded, size: 15, color: Theme.of(context).hintColor),
            ],
          ),
        ),
        actions: [
          IconButton(icon: const Icon(Icons.add_rounded), onPressed: _showCreateChannelSheet),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 6),
            child: Text('TEXT CHANNELS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: Colors.grey)),
          ),
          for (final ch in textChannels)
            ListTile(
              dense: true,
              leading: Icon(ch['name'] == 'announcements' ? Icons.campaign_rounded : Icons.tag, size: 18),
              title: Text((ch['name'] ?? '') as String, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
              onTap: () => _openChannel(ch),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 6),
            child: Text('VOICE CHANNELS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: Colors.grey)),
          ),
          if (voiceChannels.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text('No voice channels yet — create one with +', style: TextStyle(fontSize: 12, color: Colors.grey)),
            ),
          for (final ch in voiceChannels)
            ListTile(
              dense: true,
              leading: const Icon(Icons.volume_up_rounded, size: 18),
              title: Text((ch['name'] ?? '') as String, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
              onTap: () => _openChannel(ch),
            ),
        ],
      ),
    );
  }

  void _showSettingsSheet(Map<String, dynamic> community) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => FutureBuilder<List<Map<String, dynamic>>>(
        future: ref.read(apiProvider).listCommunityMembers(community['id'] as String),
        builder: (ctx, snap) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text((community['name'] ?? 'Community') as String,
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
              const SizedBox(height: 4),
              Text('@${community['slug'] ?? ''}', style: TextStyle(fontSize: 11, color: Theme.of(ctx).hintColor)),
              const SizedBox(height: 16),
              const Text('MEMBERS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: Colors.grey)),
              const SizedBox(height: 6),
              if (snap.hasData)
                for (final m in snap.data!.take(20))
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const CircleAvatar(radius: 15, child: Icon(Icons.person_rounded, size: 16)),
                    title: Text(
                      (((m['profiles'] as Map?)?['display_name']) ?? 'Member').toString(),
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                    ),
                    trailing: (m['is_owner'] == true)
                        ? const Icon(Icons.workspace_premium_rounded, size: 16, color: Colors.amber)
                        : (m['is_moderator'] == true)
                            ? const Icon(Icons.shield_rounded, size: 15, color: Colors.blue)
                            : null,
                  )
              else
                const Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator()),
            ],
          ),
        ),
      ),
    );
  }
}

extension _FirstOrNullX<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
