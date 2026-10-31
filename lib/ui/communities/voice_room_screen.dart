import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';

/// Voice room (occupancy v1 — mirrors the web client): joining broadcasts a
/// live heartbeat through `user_presence`, occupants stream in every few
/// seconds, mic mute is local. Multi-party WebRTC audio rides the 1:1 call
/// stack and lands here next.
class VoiceRoomScreen extends ConsumerStatefulWidget {
  final String communityId;
  final String channelId;
  final String channelName;
  final String communityName;

  const VoiceRoomScreen({
    super.key,
    required this.communityId,
    required this.channelId,
    required this.channelName,
    required this.communityName,
  });

  @override
  ConsumerState<VoiceRoomScreen> createState() => _VoiceRoomScreenState();
}

class _VoiceRoomScreenState extends ConsumerState<VoiceRoomScreen> {
  List<Map<String, dynamic>> _occupants = [];
  Timer? _poll;
  Timer? _heartbeat;
  bool _joined = false;
  bool _muted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _join());
  }

  Future<void> _join() async {
    try {
      await ref.read(apiProvider).setVoicePresence(widget.communityId, widget.channelId);
    } catch (_) {}
    setState(() => _joined = true);
    _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
      ref.read(apiProvider).setVoicePresence(widget.communityId, widget.channelId).catchError((_) => null);
    });
    _poll = Timer.periodic(const Duration(seconds: 6), (_) => _refresh());
    await _refresh();
  }

  Future<void> _refresh() async {
    try {
      final occ = await ref.read(apiProvider).fetchVoiceOccupants(widget.channelId);
      if (mounted) setState(() => _occupants = occ);
    } catch (_) {}
  }

  Future<void> _leave() async {
    _poll?.cancel();
    _heartbeat?.cancel();
    try {
      await ref.read(apiProvider).setVoicePresence(widget.communityId, null);
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _heartbeat?.cancel();
    // best-effort clear if popped via back gesture
    ref.read(apiProvider).setVoicePresence(widget.communityId, null).catchError((_) => null);
    super.dispose();
  }

  String _name(Map<String, dynamic> occ) {
    final p = occ['profiles'] as Map<String, dynamic>?;
    final n = (p?['display_name'] ?? p?['username'] ?? '').toString().trim();
    return n.isEmpty ? 'Member' : n;
  }

  @override
  Widget build(BuildContext context) {
    final accent = ref.watch(themeControllerProvider).accent;
    final me = ref.read(apiProvider).myProfileId;

    return Scaffold(
      backgroundColor: const Color(0xFF0B1220),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.channelName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
            Text(widget.communityName, style: const TextStyle(color: Colors.white54, fontSize: 11)),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _occupants.isEmpty && !_joined
                ? const Center(child: CircularProgressIndicator(color: Colors.white24))
                : _occupants.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.volume_up_rounded, size: 52, color: Colors.white24),
                            const SizedBox(height: 12),
                            const Text("You're the first one here", style: TextStyle(color: Colors.white54, fontSize: 13)),
                            const SizedBox(height: 4),
                            Text('Invite people — they appear live in this room',
                                style: TextStyle(color: Colors.white30, fontSize: 11)),
                          ],
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.all(18),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: 16,
                          crossAxisSpacing: 16,
                          childAspectRatio: 0.82,
                        ),
                        itemCount: _occupants.length,
                        itemBuilder: (ctx, i) {
                          final occ = _occupants[i];
                          final isMe = occ['profile_id'] == me;
                          return Column(
                            children: [
                              Stack(
                                children: [
                                  CircleAvatar(
                                    radius: 32,
                                    backgroundImage: ((occ['profiles'] as Map?)?['avatar_url']) != null
                                        ? NetworkImage((occ['profiles'] as Map)['avatar_url'] as String)
                                        : null,
                                    backgroundColor: accent.withOpacity(0.2),
                                    child: ((occ['profiles'] as Map?)?['avatar_url']) == null
                                        ? Text(_name(occ)[0].toUpperCase(),
                                            style: TextStyle(color: accent, fontWeight: FontWeight.w800, fontSize: 18))
                                        : null,
                                  ),
                                  if (!_muted)
                                    Positioned(
                                      right: 0,
                                      bottom: 0,
                                      child: Container(
                                        width: 14,
                                        height: 14,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF10B981),
                                          shape: BoxShape.circle,
                                          border: Border.all(color: const Color(0xFF0B1220), width: 2),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                isMe ? 'You' : _name(occ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w700),
                              ),
                            ],
                          );
                        },
                      ),
          ),
          // controls bar
          SafeArea(
            child: Container(
              margin: const EdgeInsets.fromLTRB(18, 0, 18, 16),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.06),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white10),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // mute
                  GestureDetector(
                    onTap: () => setState(() => _muted = !_muted),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            color: _muted ? Colors.redAccent.withOpacity(0.2) : Colors.white.withOpacity(0.1),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(_muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                              color: _muted ? Colors.redAccent : Colors.white, size: 24),
                        ),
                        const SizedBox(height: 6),
                        Text(_muted ? 'Unmute' : 'Mute', style: const TextStyle(color: Colors.white60, fontSize: 10.5, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                  // leave
                  GestureDetector(
                    onTap: _leave,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(color: Colors.redAccent.withOpacity(0.85), shape: BoxShape.circle),
                          child: const Icon(Icons.call_end_rounded, color: Colors.white, size: 26),
                        ),
                        const SizedBox(height: 6),
                        const Text('Leave', style: TextStyle(color: Colors.white60, fontSize: 10.5, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
