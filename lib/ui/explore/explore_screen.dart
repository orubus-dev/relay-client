import 'dart:async';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import '../../services/voice_recorder.dart';

import '../../state/providers.dart';

/// Explore — X/Threads × TikTok mix, backed by the same Supabase data as the
/// web app: For You (public threads feed), Stories (WhatsApp-style composer
/// with Text / Photo / Video / Voice + immersive fullscreen viewer that covers
/// the nav bar), People (profile search → DM).
class ExploreScreen extends ConsumerStatefulWidget {
  const ExploreScreen({super.key});

  @override
  ConsumerState<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends ConsumerState<ExploreScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  List<Map<String, dynamic>> _feed = [];
  List<Map<String, dynamic>> _stories = [];
  List<Map<String, dynamic>> _people = [];
  bool _loading = true;
  String? _error;

  final _composer = TextEditingController();
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _tabs.dispose();
    _composer.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final api = ref.read(apiProvider);
      final feed = await api.fetchPublicFeed(limit: 24);
      final stories = await api.fetchActiveStories();
      if (!mounted) return;
      setState(() {
        _feed = feed;
        _stories = stories;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Failed to load explore — pull to retry');
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _post() async {
    final text = _composer.text.trim();
    if (text.isEmpty || _posting) return;
    setState(() => _posting = true);
    try {
      final post = await ref.read(apiProvider).createPublicPost(text);
      if (mounted) {
        setState(() {
          _composer.clear();
          if (post != null) _feed.insert(0, post);
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Failed to post');
    }
    if (mounted) setState(() => _posting = false);
  }

  Future<void> _like(int index) async {
    final post = _feed[index];
    try {
      final res = await ref.read(apiProvider).togglePostLike(post['id'] as String);
      if (mounted) {
        setState(() {
          _feed[index] = {
            ...post,
            'liked_by_me': res['liked'] ?? true,
            'like_count': res['like_count'] ?? ((post['like_count'] ?? 0) as int) + 1,
          };
        });
      }
    } catch (_) {}
  }

  Future<void> _openDm(Map<String, dynamic> person) async {
    try {
      final convId = await ref.read(apiProvider).createDirectChat(person['id'] as String);
      final name = (person['display_name'] ?? person['username'] ?? 'Chat').toString();
      // open through the shell (registered hook) — no route juggling needed
      relayOpenChatCallback?.call(convId, name, 'direct');
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not start chat');
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = ref.watch(themeControllerProvider).accent;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Explore', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            tooltip: 'Add status',
            icon: const Icon(Icons.add_rounded),
            onPressed: _openStoryComposer,
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          dividerColor: Colors.transparent,
          indicatorColor: accent,
          labelColor: accent,
          tabs: const [Tab(text: 'For you'), Tab(text: 'Stories'), Tab(text: 'People')],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: TabBarView(
                controller: _tabs,
                children: [
                  _forYou(accent),
                  _storiesTab(accent),
                  _peopleTab(accent),
                ],
              ),
            ),
    );
  }

  // ---------------- For you ----------------

  Widget _forYou(Color accent) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
          ),
        // quick composer
        Card(
          margin: const EdgeInsets.only(bottom: 10),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _composer,
                    maxLines: 3,
                    minLines: 1,
                    style: const TextStyle(fontSize: 13.5),
                    decoration: const InputDecoration(hintText: 'Start a thread…', filled: false, border: InputBorder.none),
                  ),
                ),
                if (_composer.text.trim().isNotEmpty)
                  FilledButton(
                    onPressed: _posting ? null : _post,
                    style: FilledButton.styleFrom(backgroundColor: accent),
                    child: Text(_posting ? '…' : 'Post'),
                  ),
              ],
            ),
          ),
        ),
        for (final post in _feed) _threadCard(post, accent),
        if (_feed.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 60),
            child: Center(child: Text('Nothing here yet — post the first thread', style: TextStyle(color: Colors.grey))),
          ),
      ],
    );
  }

  Widget _threadCard(Map<String, dynamic> post, Color accent) {
    final author = ((post['author_name'] ?? post['authorName'] ?? post['display_name'] ?? '') as String).trim().isEmpty ? 'User' : (post['author_name'] ?? post['authorName'] ?? post['display_name']).toString().trim();
    final avatar = post['author_avatar'] ?? post['authorAvatar'];
    final content = (post['content'] ?? '').toString();
    final liked = post['liked_by_me'] == true;
    final likes = post['like_count'] ?? 0;
    final created = DateTime.tryParse((post['created_at'] ?? '').toString());
    final ago = created != null ? _ago(created) : '';

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 15,
                  backgroundImage: avatar != null ? NetworkImage(avatar as String) : null,
                  backgroundColor: accent.withOpacity(0.15),
                  child: avatar == null ? Text(author.isEmpty ? 'U' : author[0].toUpperCase(), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: accent)) : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(author, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                ),
                Text(ago, style: TextStyle(fontSize: 10.5, color: Theme.of(context).hintColor)),
              ],
            ),
            const SizedBox(height: 8),
            Text(content, style: const TextStyle(fontSize: 13.5, height: 1.45)),
            const SizedBox(height: 8),
            Row(
              children: [
                GestureDetector(
                  onTap: () => _like(_feed.indexOf(post)),
                  child: Row(
                    children: [
                      Icon(liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                          size: 16, color: liked ? const Color(0xFFF43F5E) : Theme.of(context).hintColor),
                      const SizedBox(width: 4),
                      Text('$likes', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Theme.of(context).hintColor)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- Stories ----------------

  Widget _storiesTab(Color accent) {
    final me = ref.read(apiProvider).myProfileId;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 10),
      children: [
        // my story + ring strip
        SizedBox(
          height: 110,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            children: [
              _storyRing(
                label: 'Your story',
                avatar: null,
                accent: accent,
                plus: true,
                onTap: _openStoryComposer,
              ),
              for (final s in _stories)
                _storyRing(
                  label: (s['display_name'] ?? s['username'] ?? 'User').toString(),
                  avatar: s['avatar_url'] as String?,
                  accent: accent,
                  seen: (s['view_count'] ?? 0) > 0 && s['profile_id'] != me,
                  onTap: () => _openViewer(_stories.indexOf(s)),
                ),
            ],
          ),
        ),
        if (_stories.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 50),
            child: Center(child: Text('No active stories — add the first one', style: TextStyle(color: Colors.grey))),
          ),
        // recent cards (TikTok energy): media thumbnails list
        for (final s in _stories.take(12))
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            child: ListTile(
              leading: _storyThumb(s, accent),
              title: Text((s['display_name'] ?? s['username'] ?? 'User').toString(),
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800)),
              subtitle: Text(
                '${(s['story_type'] ?? 'text').toString() == 'voice' ? 'Voice' : (s['story_type'] ?? 'text').toString() == 'text' ? 'Text' : 'Media'} · ${_ago(DateTime.tryParse((s['created_at'] ?? '').toString()) ?? DateTime.now())} · ${(s['view_count'] ?? 0)} views',
                style: const TextStyle(fontSize: 11.5),
              ),
              trailing: const Icon(Icons.play_circle_fill_rounded),
              onTap: () => _openViewer(_stories.indexOf(s)),
            ),
          ),
      ],
    );
  }

  Widget _storyThumb(Map<String, dynamic> s, Color accent) {
    final type = (s['story_type'] ?? 'text').toString();
    if (type == 'text') {
      return Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          gradient: storyGradientFor(s),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.text_fields_rounded, color: Colors.white, size: 20),
      );
    }
    if (type == 'voice') {
      return Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(color: accent.withOpacity(0.16), borderRadius: BorderRadius.circular(12)),
        child: Icon(Icons.graphic_eq_rounded, color: accent),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 48,
        height: 48,
        color: Theme.of(context).dividerColor,
        child: const Icon(Icons.play_arrow_rounded),
      ),
    );
  }



  Widget _storyRing({required String label, String? avatar, required Color accent, bool plus = false, bool seen = false, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(right: 12),
        child: Column(
          children: [
            Container(
              width: 64,
              height: 64,
              padding: const EdgeInsets.all(2.5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: seen || plus
                    ? LinearGradient(colors: [Theme.of(context).dividerColor, Theme.of(context).dividerColor])
                    : const LinearGradient(colors: [Color(0xFF7C3AED), Color(0xFFEC4899), Color(0xFFF59E0B)]),
              ),
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(shape: BoxShape.circle, color: Theme.of(context).scaffoldBackgroundColor),
                child: plus
                    ? Icon(Icons.add_rounded, color: accent, size: 26)
                    : CircleAvatar(
                        backgroundImage: avatar != null ? NetworkImage(avatar) : null,
                        backgroundColor: accent.withOpacity(0.15),
                        child: avatar == null
                            ? Text(label.isEmpty ? '?' : label[0].toUpperCase(), style: TextStyle(color: accent, fontWeight: FontWeight.w800))
                            : null,
                      ),
              ),
            ),
            const SizedBox(height: 5),
            SizedBox(
              width: 62,
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center, style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }

  void _openViewer(int index) {
    if (_stories.isEmpty) return;
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _StoryViewer(stories: _stories, initialIndex: index),
    ));
  }

  void _openStoryComposer() {
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => const _StoryComposer(),
    ));
  }

  // ---------------- People ----------------

  Widget _peopleTab(Color accent) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
          child: TextField(
            decoration: const InputDecoration(hintText: 'Search people', prefixIcon: Icon(Icons.search_rounded, size: 20)),
            onChanged: (q) async {
              if (q.trim().length < 2) return;
              try {
                final res = await ref.read(apiProvider).searchProfiles(q.trim());
                if (mounted) setState(() => _people = res);
              } catch (_) {}
            },
          ),
        ),
        Expanded(
          child: _people.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.person_search_rounded, size: 40, color: Theme.of(context).hintColor),
                      const SizedBox(height: 10),
                      const Text('Type at least 2 characters to find people', style: TextStyle(color: Colors.grey, fontSize: 12.5)),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    for (final p in _people)
                      Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundImage: p['avatar_url'] != null ? NetworkImage(p['avatar_url'] as String) : null,
                            backgroundColor: accent.withOpacity(0.15),
                            child: p['avatar_url'] == null
                                ? Text(((p['display_name'] ?? p['username'] ?? 'U') as String).isEmpty ? 'U' : ((p['display_name'] ?? p['username'] ?? 'U') as String)[0].toUpperCase(),
                                    style: TextStyle(color: accent, fontWeight: FontWeight.w800))
                                : null,
                          ),
                          title: Text((p['display_name'] ?? p['username'] ?? 'User').toString(),
                              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800)),
                          subtitle: Text(p['username'] != null ? '@${p['username']}' : '',
                              style: const TextStyle(fontSize: 11.5)),
                          trailing: FilledButton(
                            onPressed: () => _openDm(p),
                            style: FilledButton.styleFrom(backgroundColor: accent, padding: const EdgeInsets.symmetric(horizontal: 14)),
                            child: const Text('Message', style: TextStyle(fontSize: 12)),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  String _ago(DateTime d) {
    final diff = DateTime.now().difference(d);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return DateFormat('d MMM').format(d);
  }
}

/// Global hook the HomeShell registers so any screen can open a conversation.
void Function(String id, String title, String type)? relayOpenChatCallback;

LinearGradient storyGradientFor(Map<String, dynamic> s) {
  const presets = [
    [0xFF667EEA, 0xFF764BA2],
    [0xFFF093FB, 0xFFF5576C],
    [0xFF4FACFE, 0xFF00F2FE],
    [0xFF43E97B, 0xFF38F9D7],
    [0xFFFA709A, 0xFFFEE140],
    [0xFFA18CD1, 0xFFFBC2EB],
  ];
  final bg = (s['background_color'] ?? '').toString();
  // background_color holds "color1|color2" hex pair from the composer
  final parts = bg.split('|');
  for (final pair in [parts]) {
    if (pair.length == 2) {
      try {
        return LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(int.parse(pair[0])), Color(int.parse(pair[1]))],
        );
      } catch (_) {}
    }
  }
  final idx = ((s['id'] ?? '').toString().hashCode.abs()) % presets.length;
  return LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(presets[idx][0]), Color(presets[idx][1])],
  );
}

// ================= immersive story viewer =================

class _StoryViewer extends ConsumerStatefulWidget {
  final List<Map<String, dynamic>> stories;
  final int initialIndex;
  const _StoryViewer({required this.stories, required this.initialIndex});

  @override
  ConsumerState<_StoryViewer> createState() => _StoryViewerState();
}

class _StoryViewerState extends ConsumerState<_StoryViewer> {
  late int _index = widget.initialIndex;
  Timer? _ticker;
  double _progress = 0;
  bool _paused = false;
  AudioPlayer? _voicePlayer;

  @override
  void initState() {
    super.initState();
    _startProgress();
    final me = ref.read(apiProvider).myProfileId;
    _markViewed(widget.stories[_index], me);
    _syncVoicePlayback();
  }

  void _startProgress() {
    _ticker?.cancel();
    _progress = 0;
    _ticker = Timer.periodic(const Duration(milliseconds: 50), (t) {
      if (!mounted) return t.cancel();
      if (_paused) return;
      setState(() => _progress += 0.05 / _storySeconds);
      if (_progress >= 1) {
        _next();
      }
    });
  }

  double get _storySeconds {
    final type = (widget.stories[_index]['story_type'] ?? 'text').toString();
    return type == 'video' ? 15.0 : type == 'voice' ? 12.0 : 6.0;
  }

  void _markViewed(Map<String, dynamic> s, String? me) {
    if (me == null || s['profile_id'] == me) return;
    ref.read(apiProvider).recordStoryView(s['id'] as String).catchError((_) => null);
  }

  void _next() {
    if (_index >= widget.stories.length - 1) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _index += 1);
    _startProgress();
    _markViewed(widget.stories[_index], ref.read(apiProvider).myProfileId);
    _syncVoicePlayback();
  }

  void _prev() {
    if (_index <= 0) {
      setState(() => _progress = 0);
      _startProgress();
      return;
    }
    setState(() => _index -= 1);
    _startProgress();
    _syncVoicePlayback();
  }

  /// Voice stories actually PLAY now (they used to be a static icon).
  Future<void> _syncVoicePlayback() async {
    final s = widget.stories[_index];
    final type = (s['story_type'] ?? 'text').toString();
    final url = (s['media_url'] ?? '').toString();
    try {
      if (type != 'voice' || url.isEmpty) {
        await _voicePlayer?.stop();
        return;
      }
      _voicePlayer ??= AudioPlayer();
      await _voicePlayer!.setUrl(url);
      if (!_paused) await _voicePlayer!.play();
    } catch (_) {
      // missing/expired media — the visual still renders
    }
  }

  void _setPaused(bool v) {
    setState(() => _paused = v);
    final p = _voicePlayer;
    if (p == null) return;
    if (v) {
      p.pause();
    } else {
      p.play();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _voicePlayer?.dispose();
    super.dispose();
  }

  Future<void> _deleteMine() async {
    final s = widget.stories[_index];
    try {
      await ref.read(apiProvider).sb.from('stories').delete().eq('id', s['id']);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.stories[_index];
    final me = ref.read(apiProvider).myProfileId;
    final isMine = s['profile_id'] == me;
    final type = (s['story_type'] ?? 'text').toString();

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTapDown: (d) {
          if (d.globalPosition.dx > MediaQuery.of(context).size.width / 2) {
            _next();
          } else {
            _prev();
          }
        },
        onLongPressStart: (_) => _setPaused(true),
        onLongPressEnd: (_) => _setPaused(false),
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) > 120) Navigator.of(context).pop();
        },
        child: Stack(
          children: [
            // story content
            Positioned.fill(child: _storyBody(s, type)),
            // progress bars
            SafeArea(
              child: Column(
                children: [
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      for (var i = 0; i < widget.stories.length; i++)
                        Expanded(
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 2),
                            height: 2.5,
                            child: LinearProgressIndicator(
                              value: i < _index ? 1 : (i == _index ? _progress.clamp(0, 1) : 0),
                              backgroundColor: Colors.white24,
                              valueColor: const AlwaysStoppedAnimation(Colors.white),
                              minHeight: 2.5,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 15,
                          backgroundImage: s['avatar_url'] != null ? NetworkImage(s['avatar_url'] as String) : null,
                          backgroundColor: Colors.white24,
                          child: s['avatar_url'] == null
                              ? Text(((s['display_name'] ?? 'U') as String).isEmpty ? 'U' : ((s['display_name'] ?? 'U') as String)[0].toUpperCase(),
                                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800))
                              : null,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text((s['display_name'] ?? s['username'] ?? 'User').toString(),
                                  style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w800)),
                              Text(_agoStr(DateTime.tryParse((s['created_at'] ?? '').toString()) ?? DateTime.now()),
                                  style: const TextStyle(color: Colors.white60, fontSize: 10)),
                            ],
                          ),
                        ),
                        if (isMine)
                          IconButton(
                            icon: const Icon(Icons.delete_outline_rounded, color: Colors.white70, size: 20),
                            onPressed: _deleteMine,
                          ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded, color: Colors.white, size: 22),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (isMine)
              Positioned(
                bottom: 40,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                    decoration: BoxDecoration(color: Colors.white.withOpacity(0.14), borderRadius: BorderRadius.circular(20)),
                    child: Text('${s['view_count'] ?? 0} views',
                        style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w700)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _storyBody(Map<String, dynamic> s, String type) {
    if (type == 'text') {
      return Container(
        decoration: BoxDecoration(gradient: storyGradientFor(s)),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Text(
          (s['caption'] ?? '').toString(),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _tryColor(s['text_color']) ?? Colors.white,
            fontSize: 22,
            height: 1.4,
            fontWeight: FontWeight.w800,
          ),
        ),
      );
    }
    if (type == 'voice') {
      final playing = !_paused;
      return Container(
        decoration: BoxDecoration(gradient: storyGradientFor(s)),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                if (playing)
                  SizedBox(
                    width: 120,
                    height: 120,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      valueColor: const AlwaysStoppedAnimation(Colors.white38),
                      backgroundColor: Colors.white12,
                    ),
                  ),
                Icon(playing ? Icons.graphic_eq_rounded : Icons.pause_circle_outline_rounded,
                    color: Colors.white, size: 72),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              _fmtDur(Duration(seconds: ((s['media_duration_ms'] ?? 0) as int) ~/ 1000)),
              style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800, fontFamily: 'monospace'),
            ),
            const SizedBox(height: 8),
            Text(playing ? 'Playing voice status · hold to pause' : 'Paused · release to play',
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ],
        ),
      );
    }
    // image / video — signed URL plays directly
    final url = (s['media_url'] ?? '').toString();
    if (url.isEmpty) {
      return Container(color: const Color(0xFF1A1A1A), alignment: Alignment.center, child: const Text('Media unavailable', style: TextStyle(color: Colors.white54)));
    }
    return InteractiveViewer(
      maxScale: 4,
      child: Center(
        child: Image.network(
          url,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => Container(
            color: const Color(0xFF1A1A1A),
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.videocam_rounded, color: Colors.white38, size: 44),
                const SizedBox(height: 8),
                Text((s['caption'] ?? '').toString(), style: const TextStyle(color: Colors.white70), textAlign: TextAlign.center),
              ],
            ),
          ),
          loadingBuilder: (ctx, child, prog) =>
              prog == null ? child : const Center(child: CircularProgressIndicator(color: Colors.white24)),
        ),
      ),
    );
  }

  Color? _tryColor(Object? v) {
    if (v == null) return null;
    try {
      return Color(int.parse(v.toString()));
    } catch (_) {
      return null;
    }
  }

  String _fmtDur(Duration d) {
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  String _agoStr(DateTime d) {
    final diff = DateTime.now().difference(d);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    return DateFormat('d MMM').format(d);
  }
}

// ================= story composer (WhatsApp Add status) =================

class _StoryComposer extends ConsumerStatefulWidget {
  const _StoryComposer();

  @override
  ConsumerState<_StoryComposer> createState() => _StoryComposerState();
}

class _StoryComposerState extends ConsumerState<_StoryComposer> {
  String _mode = 'text'; // text | image | video | voice
  final _text = TextEditingController();
  int _gradient = 0;
  String? _mediaPath; // picked image/video
  bool _isVideo = false;
  String? _voicePath;
  Duration _voiceDur = Duration.zero;
  bool _recording = false;
  Timer? _ticker;
  DateTime? _pressStart;
  bool _posting = false;
  String? _voiceError;

  static const _gradients = [
    [0xFF667EEA, 0xFF764BA2],
    [0xFFF093FB, 0xFFF5576C],
    [0xFF4FACFE, 0xFF00F2FE],
    [0xFF43E97B, 0xFF38F9D7],
    [0xFFFA709A, 0xFFFEE140],
    [0xFF0F172A, 0xFF334155],
  ];

  @override
  void dispose() {
    _text.dispose();
    _ticker?.cancel();
    // never strand the app-lifetime recorder (mic stays hot otherwise)
    try {
      ref.read(voiceRecorderProvider).isRecording.then((hot) {
        if (hot) ref.read(voiceRecorderProvider).stop();
      }).catchError((_) {});
    } catch (_) {}
    super.dispose();
  }

  Future<void> _pick(bool video) async {
    final picker = ImagePicker();
    try {
      final picked = video
          ? await picker.pickVideo(source: ImageSource.gallery)
          : await picker.pickImage(source: ImageSource.gallery, imageQuality: 88);
      if (picked != null) {
        setState(() {
          _mediaPath = picked.path;
          _isVideo = video;
          _mode = video ? 'video' : 'image';
        });
      }
    } catch (_) {}
  }

  Future<void> _startVoice() async {
    final recorder = ref.read(voiceRecorderProvider);
    if (await recorder.resolvePermission() != MicPermission.granted) {
      if (mounted) setState(() => _voiceError = 'Microphone permission required');
      return;
    }
    try {
      if (await recorder.isRecording) await recorder.stop(); // stale state guard
      await recorder.start();
    } catch (_) {
      if (mounted) setState(() => _voiceError = 'Could not start recording');
      return;
    }
    if (!mounted) {
      try { await recorder.stop(); } catch (_) {}
      return;
    }
    _pressStart = DateTime.now();
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted) return;
      setState(() => _voiceDur = DateTime.now().difference(_pressStart!));
    });
    setState(() => _recording = true);
  }

  Future<void> _stopVoice({bool discard = false}) async {
    final recorder = ref.read(voiceRecorderProvider);
    _ticker?.cancel();
    final path = await recorder.stop();
    if (!mounted) return;
    setState(() {
      _recording = false;
      _voicePath = discard ? null : path;
    });
  }

  Future<void> _post() async {
    if (_posting) return;
    setState(() => _posting = true);
    final api = ref.read(apiProvider);
    try {
      if (_mode == 'text' && _text.text.trim().isNotEmpty) {
        final g = _gradients[_gradient];
        await api.createStory(
          type: 'text',
          caption: _text.text.trim(),
          backgroundColor: '${g[0]}|${g[1]}',
          textColor: '${0xFFFFFFFF}',
          fontName: 'Inter',
        );
      } else if ((_mode == 'image' || _mode == 'video') && _mediaPath != null) {
        final signed = await api.uploadStoryMedia(_mediaPath!, isVideo: _isVideo);
        await api.createStory(
          type: _mode,
          caption: _text.text.trim().isEmpty ? null : _text.text.trim(),
          mediaUrl: signed,
        );
      } else if (_mode == 'voice' && _voicePath != null) {
        final signed = await api.uploadStoryMedia(_voicePath!, isVideo: false);
        await api.createStory(
          type: 'voice',
          caption: null,
          mediaUrl: signed,
          backgroundColor: '${_gradients[_gradient][0]}|${_gradients[_gradient][1]}',
          durationMs: _voiceDur.inMilliseconds,
        );
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to add status')));
      }
    }
    if (mounted) setState(() => _posting = false);
  }

  @override
  Widget build(BuildContext context) {
    final accent = ref.watch(themeControllerProvider).accent;
    final canPost = _mode == 'text'
        ? _text.text.trim().isNotEmpty
        : _mode == 'voice'
            ? _voicePath != null
            : _mediaPath != null;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Add status', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        actions: [
          if (canPost && !_posting)
            TextButton(onPressed: _post, child: Text('Share', style: TextStyle(color: accent, fontWeight: FontWeight.w800))),
        ],
      ),
      body: Column(
        children: [
          if (_voiceError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(_voiceError!, style: TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.w700)),
              ),
            ),
          Expanded(
            child: _mode == 'text'
                ? Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(_gradients[_gradient][0]), Color(_gradients[_gradient][1])],
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 26),
                      child: TextField(
                        controller: _text,
                        maxLines: null,
                        textAlign: TextAlign.center,
                        autofocus: true,
                        onChanged: (_) => setState(() {}),
                        style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800, height: 1.4),
                        decoration: const InputDecoration(
                          hintText: 'Type a status…',
                          hintStyle: TextStyle(color: Colors.white54, fontSize: 20),
                          border: InputBorder.none,
                        ),
                        cursorColor: Colors.white,
                      ),
                    ),
                  )
                : _mode == 'voice'
                    ? Container(
                        alignment: Alignment.center,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(_recording ? Icons.mic_rounded : Icons.graphic_eq_rounded,
                                color: _recording ? Colors.redAccent : accent, size: 64),
                            const SizedBox(height: 16),
                            Text(
                              _recording ? 'Recording… ${_voiceDur.inSeconds}s' : (_voicePath != null ? 'Voice ready — ${_voiceDur.inSeconds}s' : 'Tap record to start'),
                              style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 20),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if (!_recording && _voicePath == null)
                                  FilledButton.icon(
                                    onPressed: _startVoice,
                                    icon: const Icon(Icons.mic_rounded),
                                    label: const Text('Record'),
                                  )
                                else if (_recording) ...[
                                  OutlinedButton(onPressed: () => _stopVoice(discard: true), child: const Text('Cancel', style: TextStyle(color: Colors.white70))),
                                  const SizedBox(width: 12),
                                  FilledButton.icon(
                                    onPressed: () => _stopVoice(),
                                    icon: const Icon(Icons.stop_rounded),
                                    label: const Text('Stop'),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      )
                    : _mediaPath != null && !_isVideo
                        ? Image.file(
                            File(_mediaPath!),
                            fit: BoxFit.contain,
                            height: double.infinity,
                            errorBuilder: (_, __, ___) => const Center(child: Text('Preview unavailable', style: TextStyle(color: Colors.white54))),
                          )
                        : _mediaPath != null
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.videocam_rounded, color: Colors.white38, size: 56),
                                    const SizedBox(height: 12),
                                    const Text('Video ready — share to post', style: TextStyle(color: Colors.white70)),
                                  ],
                                ),
                              )
                            : Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.photo_library_outlined, color: Colors.white24, size: 56),
                                    const SizedBox(height: 12),
                                    Text('Pick media below', style: TextStyle(color: Colors.white38)),
                                  ],
                                ),
                              ),
          ),
          // gradient strip for text/voice modes
          if (_mode == 'text' || _mode == 'voice')
            SizedBox(
              height: 42,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < _gradients.length; i++)
                    GestureDetector(
                      onTap: () => setState(() => _gradient = i),
                      child: Container(
                        width: 26,
                        height: 26,
                        margin: const EdgeInsets.symmetric(horizontal: 5),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(colors: [Color(_gradients[i][0]), Color(_gradients[i][1])]),
                          border: _gradient == i ? Border.all(color: Colors.white, width: 2.2) : null,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          // mode chips (WhatsApp Add status row)
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              decoration: const BoxDecoration(color: Colors.black),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _modeChip('text', 'Text', Icons.text_fields_rounded, accent),
                  _modeChip('image', 'Photo', Icons.image_outlined, accent),
                  _modeChip('video', 'Video', Icons.videocam_outlined, accent),
                  _modeChip('voice', 'Voice', Icons.mic_rounded, accent),
                ],
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: null,
    );
  }

  Widget _modeChip(String id, String label, IconData icon, Color accent) {
    final selected = _mode == id || (_mode == 'video' && id == 'video');
    return GestureDetector(
      onTap: () async {
        if (id == 'image' || id == 'video') {
          await _pick(id == 'video');
        } else {
          setState(() => _mode = id);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? accent.withOpacity(0.22) : Colors.white.withOpacity(0.08),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: selected ? accent : Colors.white12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: selected ? accent : Colors.white70),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: selected ? accent : Colors.white70)),
          ],
        ),
      ),
    );
  }
}
