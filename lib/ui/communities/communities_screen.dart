import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import 'voice_room_screen.dart';

/// Communities — Discord-style: community list → channel sidebar (text +
/// voice), tap the top bar for the FULL settings screen, plus creates a
/// channel (text or voice). Voice channels open a live voice room with
/// presence (occupants broadcast through user_presence heartbeats).
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
  Map<String, int> _voiceOccupants = {};
  Timer? _occupancyTimer;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _occupancyTimer?.cancel();
    super.dispose();
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
      await _refreshOccupancy(channels);
      _occupancyTimer?.cancel();
      _occupancyTimer = Timer.periodic(const Duration(seconds: 10), (_) {
        if (mounted) _refreshOccupancy(_channels);
      });
    } catch (_) {
      setState(() => _error = 'Failed to load channels');
    }
  }

  Future<void> _refreshOccupancy(List<Map<String, dynamic>> channels) async {
    for (final ch in channels.where((c) => c['channel_type'] == 'voice')) {
      try {
        final occ = await ref.read(apiProvider).fetchVoiceOccupants(ch['id'] as String);
        if (mounted) setState(() => _voiceOccupants[ch['id'] as String] = occ.length);
      } catch (_) {}
    }
  }

  Future<void> _openChannel(Map<String, dynamic> ch) async {
    final communityId = _activeCommunityId!;
    if (ch['channel_type'] == 'voice') {
      Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => VoiceRoomScreen(
          communityId: communityId,
          channelId: ch['id'] as String,
          channelName: (ch['name'] ?? 'Voice').toString(),
          communityName: _communityName(communityId),
        ),
      ));
      return;
    }
    try {
      final convId = await ref.read(apiProvider).openChannelConversation(ch['id'] as String);
      widget.onOpenChannelChat(convId, '${ch['name']}', 'channel');
    } catch (_) {
      setState(() => _error = 'Failed to open channel');
    }
  }

  String _communityName(String id) =>
      _communities.where((c) => c['id'] == id).firstOrNull?['name']?.toString() ?? 'Community';

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
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(20, 8, 20, 28 + MediaQuery.of(ctx).viewInsets.bottom),
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
                onChanged: (_) => setSheet(() {}),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: nameCtrl.text.trim().isEmpty
                      ? null
                      : () {
                          final name = nameCtrl.text.trim();
                          Navigator.pop(sheetCtx);
                          _createChannel(name, type);
                        },
                  child: const Text('Create channel'),
                ),
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
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 60),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.groups_rounded, size: 44, color: Theme.of(context).hintColor),
                          const SizedBox(height: 10),
                          const Text('No communities yet', style: TextStyle(color: Colors.grey)),
                          const SizedBox(height: 4),
                          const Text('Create or join one from the web app', style: TextStyle(color: Colors.grey, fontSize: 11.5)),
                        ],
                      ),
                    ),
                  ),
                for (final c in _communities)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
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
    final accent = ref.watch(themeControllerProvider).accent;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () {
            _occupancyTimer?.cancel();
            setState(() => _activeCommunityId = null);
          },
        ),
        title: GestureDetector(
          onTap: () => _openSettings(community ?? {}),
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
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 11.5)),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 6),
            child: Text('TEXT CHANNELS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: Colors.grey)),
          ),
          for (final ch in textChannels)
            ListTile(
              dense: true,
              leading: Icon(ch['name'] == 'announcements' ? Icons.campaign_rounded : Icons.tag,
                  size: 18, color: Theme.of(context).hintColor),
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
              leading: Icon(Icons.volume_up_rounded, size: 18, color: accent),
              title: Text((ch['name'] ?? '') as String, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
              trailing: (_voiceOccupants[ch['id']] ?? 0) > 0
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(width: 6, height: 6, decoration: const BoxDecoration(color: Color(0xFF10B981), shape: BoxShape.circle)),
                        const SizedBox(width: 5),
                        Text('${_voiceOccupants[ch['id']]}',
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFF10B981))),
                      ],
                    )
                  : null,
              onTap: () => _openChannel(ch),
            ),
        ],
      ),
    );
  }

  // ---------------- full settings screen ----------------

  void _openSettings(Map<String, dynamic> community) {
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
      builder: (_) => _CommunitySettingsScreen(
        community: community,
        onLeft: () {
          setState(() => _activeCommunityId = null);
          _load();
        },
      ),
    ));
  }
}

class _CommunitySettingsScreen extends ConsumerStatefulWidget {
  final Map<String, dynamic> community;
  final VoidCallback onLeft;
  const _CommunitySettingsScreen({required this.community, required this.onLeft});

  @override
  ConsumerState<_CommunitySettingsScreen> createState() => _CommunitySettingsScreenState();
}

class _CommunitySettingsScreenState extends ConsumerState<_CommunitySettingsScreen> {
  List<Map<String, dynamic>>? _members;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMembers());
  }

  Future<void> _loadMembers() async {
    try {
      final members = await ref.read(apiProvider).listCommunityMembers(widget.community['id'] as String);
      if (mounted) setState(() => _members = members);
    } catch (_) {
      if (mounted) setState(() => _members = []);
    }
  }

  Future<void> _leave() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave community?'),
        content: Text('You will leave ${(widget.community['name'] ?? 'this community')}.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(apiProvider).sb.rpc('leave_community', params: {'p_community_id': widget.community['id']});
      if (mounted) {
        Navigator.of(context).pop();
        widget.onLeft();
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final accent = ref.watch(themeControllerProvider).accent;
    final members = _members;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Community settings', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundImage: widget.community['avatar_url'] != null ? NetworkImage(widget.community['avatar_url'] as String) : null,
                backgroundColor: accent.withOpacity(0.16),
                child: widget.community['avatar_url'] == null
                    ? Text((widget.community['name'] ?? 'C').toString().substring(0, 1).toUpperCase(),
                        style: TextStyle(color: accent, fontWeight: FontWeight.w800, fontSize: 20))
                    : null,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text((widget.community['name'] ?? 'Community') as String,
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                    if ((widget.community['slug'] ?? '').toString().isNotEmpty)
                      Text('@${widget.community['slug']}', style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
                  ],
                ),
              ),
            ],
          ),
          if (((widget.community['description'] ?? '') as String).isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(widget.community['description'] as String,
                  style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor, height: 1.4)),
            ),
          const SizedBox(height: 20),
          Text('MEMBERS ${members == null ? '' : '· ${members.length}'}',
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: Colors.grey)),
          const SizedBox(height: 4),
          if (members == null)
            const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
          else
            for (final m in members)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: CircleAvatar(
                  radius: 17,
                  backgroundImage: ((m['profiles'] as Map?)?['avatar_url']) != null
                      ? NetworkImage((m['profiles'] as Map)['avatar_url'] as String)
                      : null,
                  backgroundColor: accent.withOpacity(0.12),
                  child: ((m['profiles'] as Map?)?['avatar_url']) == null
                      ? Text((((m['profiles'] as Map?)?['display_name']) ?? 'M').toString().substring(0, 1).toUpperCase(),
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: accent))
                      : null,
                ),
                title: Text((((m['profiles'] as Map?)?['display_name']) ?? 'Member').toString(),
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                subtitle: ((m['profiles'] as Map?)?['username']) != null
                    ? Text('@${(m['profiles'] as Map)['username']}', style: const TextStyle(fontSize: 11))
                    : null,
                trailing: (m['is_owner'] == true)
                    ? const Icon(Icons.workspace_premium_rounded, size: 17, color: Colors.amber)
                    : (m['is_moderator'] == true)
                        ? Icon(Icons.shield_rounded, size: 16, color: accent)
                        : null,
              ),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: _leave,
            icon: const Icon(Icons.logout_rounded, size: 17),
            label: const Text('Leave community'),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent, side: BorderSide(color: Colors.redAccent.withOpacity(0.5))),
          ),
        ],
      ),
    );
  }
}

extension _FirstOrNullX<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
