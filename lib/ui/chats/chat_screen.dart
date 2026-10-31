import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:realtime_client/realtime_client.dart';
import '../../services/voice_recorder.dart';
import '../../state/providers.dart';

/// Chat screen — rebuilt WhatsApp-grade:
///  · bubbles aligned like WhatsApp (mine right/accent with tail, others left)
///  · date separators, in-bubble timestamps, delivery ticks (sent/read)
///  · swipe a bubble right to reply (accent bar + reply preview above composer)
///  · voice notes with real playback + waveform progress
///  · hold-to-record: slide up to lock, slide left to cancel, release to send
class ChatScreen extends ConsumerStatefulWidget {
  final String chatId;
  final String title;
  final String type;
  final VoidCallback onBack;

  const ChatScreen({
    super.key,
    required this.chatId,
    required this.title,
    required this.type,
    required this.onBack,
  });

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  List<Map<String, Object?>> _messages = [];
  final _composer = TextEditingController();
  final _scroll = ScrollController();
  Timer? _typingDebounce;

  // reply state
  Map<String, Object?>? _replyTo;

  // voice playback
  AudioPlayer? _player;
  String? _playingId;
  Duration _playPos = Duration.zero;
  Duration _playDur = Duration.zero;
  String? _loadingMediaId;

  // voice recording
  bool _recording = false;
  bool _locked = false;
  Duration _recDuration = Duration.zero;
  Timer? _recTicker;
  DateTime? _pressStart;
  double _pressStartDy = 0;
  double _pressStartDx = 0;
  final _waveRandom = Random();
  List<double> _wave = List.filled(22, 0.3);
  String? _hint;
  String? _error;

  // mic permission — resolved up front so the first hold-to-record never
  // fires a system dialog mid-gesture, and the hint is always accurate.
  MicPermission _mic = MicPermission.denied;
  bool _micResolved = false;

  RealtimeChannel? _channel;

  @override
  void initState() {
    super.initState();
    _loadLocalThenSync();
    _subscribe();
    _warmMicPermission();
  }

  Future<void> _warmMicPermission() async {
    try {
      final recorder = ref.read(voiceRecorderProvider);
      final p = await recorder.resolvePermission(request: false);
      if (!mounted) return;
      setState(() {
        _mic = p;
        _micResolved = true;
      });
      // Denied (not blocked) on entry: ask once now, out of the record gesture.
      if (p == MicPermission.denied) {
        final after = await recorder.resolvePermission(request: true);
        if (mounted) setState(() => _mic = after);
      }
    } catch (_) {
      if (mounted) setState(() => _micResolved = true);
    }
  }

  Future<void> _loadLocalThenSync() async {
    final db = ref.read(localDbProvider);
    setState(() => _messages = db.listMessages(widget.chatId));
    final cursor = db.cursorFor(widget.chatId);
    try {
      await ref.read(syncEngineProvider).syncMessages(widget.chatId, fullHistory: !cursor.historyLoaded);
    } catch (_) {}
    if (mounted) setState(() => _messages = db.listMessages(widget.chatId));
    _scrollToBottom();
  }

  void _subscribe() {
    final api = ref.read(apiProvider);
    _channel?.unsubscribe();
    _channel = api.subscribeMessages(widget.chatId, (row) async {
      await ref.read(syncEngineProvider).ingestRealtimeRow(row);
      if (mounted) setState(() => _messages = ref.read(localDbProvider).listMessages(widget.chatId));
      _scrollToBottom();
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    _composer.dispose();
    _scroll.dispose();
    _typingDebounce?.cancel();
    _recTicker?.cancel();
    _player?.dispose();
    // never strand the app-lifetime recorder (mic stays hot otherwise)
    try {
      ref.read(voiceRecorderProvider).isRecording.then((hot) {
        if (hot) ref.read(voiceRecorderProvider).stop();
      }).catchError((_) {});
    } catch (_) {}
    super.dispose();
  }

  // ---------------- sending ----------------

  Future<void> _sendText() async {
    final text = _composer.text.trim();
    if (text.isEmpty) return;
    _composer.clear();
    final reply = _replyTo;
    setState(() => _replyTo = null);

    final payload = <String, dynamic>{'k': 't', 't': text};
    if (reply != null) {
      payload['r'] = reply['id'];
      payload['rn'] = (reply['sender_name'] ?? '') as String;
      payload['rt'] = (reply['content'] ?? '') as String;
    }
    try {
      final api = ref.read(apiProvider);
      final sync = ref.read(syncEngineProvider);
      final row = await api.sendMessageRaw(
            widget.chatId,
            jsonEncode(payload),
            'text',
          );
      // own plaintext lives here (fanout has no self entry) — echo it into the
      // local db BEFORE sync so the row comes back readable
      await sync.persistOwnMessage(widget.chatId, jsonEncode(payload), 'text', row);
      await sync.syncMessages(widget.chatId);
      setState(() => _messages = ref.read(localDbProvider).listMessages(widget.chatId));
      _scrollToBottom();
    } catch (e) {
      setState(() => _error = 'Failed to send — try again');
    }
  }

  Future<void> _sendVoice(String filePath) async {
    setState(() {
      _error = null;
      _hint = null;
    });
    try {
      final api = ref.read(apiProvider);
      final sync = ref.read(syncEngineProvider);
      final uploaded = await api.uploadEncryptedFile(filePath, mime: 'audio/mp4');
      final dur = _recDuration.inSeconds;
      final payload = jsonEncode({
        'k': 'm',
        'u': uploaded['url'],
        'key': uploaded['mediaKey'],
        'mime': 'audio/mp4',
        'name': 'Voice note',
        'dur': dur,
      });
      final row = await api.sendMessageRaw(widget.chatId, payload, 'voice_note');
      // own voice notes decrypt through the local echo, not the peer envelope
      await sync.persistOwnMessage(widget.chatId, payload, 'voice_note', row);
      await sync.syncMessages(widget.chatId);
      setState(() => _messages = ref.read(localDbProvider).listMessages(widget.chatId));
      _scrollToBottom();
    } catch (e) {
      setState(() => _error = 'Voice send failed');
    }
  }

  // ---------------- voice playback ----------------

  Future<void> _togglePlay(Map<String, Object?> m) async {
    final id = m['id'] as String;
    if (_playingId == id) {
      await _player?.stop();
      setState(() => _playingId = null);
      return;
    }
    try {
      setState(() => _loadingMediaId = id);
      final api = ref.read(apiProvider);
      final url = (m['media_url'] ?? '') as String;
      if (url.isEmpty) return;
      final playable = await api.fetchPlayableFile(
        url,
        (m['media_key'] ?? '') as String?,
        (m['mime_type'] ?? 'audio/mp4') as String,
      );
      _player?.dispose();
      final player = AudioPlayer();
      _player = player;
      player.positionStream.listen((p) {
        if (mounted && _playingId == id) setState(() => _playPos = p);
      });
      player.durationStream.listen((d) {
        if (mounted && _playingId == id) setState(() => _playDur = d ?? Duration.zero);
      });
      player.playerStateStream.listen((s) {
        if (s.processingState == ProcessingState.completed && mounted) {
          setState(() {
            _playingId = null;
            _playPos = Duration.zero;
          });
        }
      });
      if (playable.startsWith('http')) {
        await player.setUrl(playable);
      } else {
        await player.setFilePath(playable);
      }
      await player.play();
      setState(() {
        _playingId = id;
        _loadingMediaId = null;
        _playPos = Duration.zero;
      });
    } catch (e) {
      setState(() {
        _loadingMediaId = null;
        _error = 'Playback failed';
      });
    }
  }

  // ---------------- hold-to-record (WhatsApp flow) ----------------

  Future<void> _onMicDown(PointerDownEvent e) async {
    final recorder = ref.read(voiceRecorderProvider);
    // Ground-truth OS check. When the mic is genuinely off we say exactly
    // that; when it is enabled we NEVER show a permission hint here.
    final mic = await recorder.resolvePermission();
    if (!mounted) return;
    if (mic != MicPermission.granted) {
      setState(() {
        _mic = mic;
        _micResolved = true;
        _hint = mic == MicPermission.blocked
            ? 'Microphone is off for Relay — tap to open Settings'
            : 'Microphone permission required — tap to allow';
      });
      return;
    }
    if (_recording) return; // pointer double-fire guard
    setState(() => _hint = null);
    _pressStart = DateTime.now();
    _pressStartDy = e.position.dy;
    _pressStartDx = e.position.dx;
    await recorder.start();
    if (!mounted || _pressStart == null) {
      // release already happened while start() was in flight — don't strand
      // a running recorder
      try { await recorder.stop(); } catch (_) {}
      return;
    }
    _recTicker?.cancel();
    _recDuration = Duration.zero;
    _wave = List.filled(22, 0.3);
    _recTicker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted || !_recording) return;
      setState(() {
        _recDuration = DateTime.now().difference(_pressStart!);
        _wave = [for (var i = 0; i < 22; i++) 0.25 + _waveRandom.nextDouble() * (_recording ? 0.75 : 0.2)];
      });
    });
    setState(() {
      _recording = true;
      _locked = false;
    });
  }

  Future<void> _onMicMove(PointerMoveEvent e) async {
    if (!_recording || _locked) return;
    final dyUp = _pressStartDy - e.position.dy;
    final dxLeft = _pressStartDx - e.position.dx;
    if (dyUp > 64) {
      setState(() => _locked = true);
      return;
    }
    if (dxLeft > 110) {
      await _cancelRecording();
    }
  }

  Future<void> _onMicUp() async {
    if (_locked) return; // locked keeps recording (WhatsApp behavior)
    final held = _pressStart == null ? Duration.zero : DateTime.now().difference(_pressStart!);
    if (held < const Duration(milliseconds: 700)) {
      await _cancelRecording();
      setState(() => _hint = 'Hold the mic to record');
      return;
    }
    await _finishRecording();
  }

  Future<void> _cancelRecording() async {
    final recorder = ref.read(voiceRecorderProvider);
    _recTicker?.cancel();
    _pressStart = null;
    try {
      await recorder.stop();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _recording = false;
      _locked = false;
    });
  }

  Future<void> _finishRecording() async {
    final recorder = ref.read(voiceRecorderProvider);
    _recTicker?.cancel();
    _pressStart = null;
    final path = await recorder.stop();
    if (!mounted) return;
    setState(() {
      _recording = false;
      _locked = false;
    });
    if (path != null) await _sendVoice(path);
  }

  // ---------------- build ----------------

  @override
  Widget build(BuildContext context) {
    final accent = ref.watch(themeControllerProvider).accent;
    final me = ref.read(apiProvider).myProfileId ?? '';
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0B1220) : const Color(0xFFF1F5F9),
      appBar: AppBar(
        backgroundColor: isDark ? const Color(0xFF101A2C) : Colors.white,
        leading: IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: widget.onBack),
        titleSpacing: 0,
        title: Row(
          children: [
            CircleAvatar(
              radius: 17,
              backgroundColor: accent.withOpacity(0.16),
              child: Text(
                widget.title.isNotEmpty ? widget.title[0].toUpperCase() : '?',
                style: TextStyle(color: accent, fontWeight: FontWeight.w800, fontSize: 14),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800)),
                  Text(
                    widget.type == 'channel' ? 'channel' : widget.type == 'group' ? 'group' : 'end-to-end encrypted',
                    style: TextStyle(fontSize: 10.5, color: Theme.of(context).hintColor, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.lock_rounded, size: 34, color: Theme.of(context).hintColor),
                        const SizedBox(height: 10),
                        Text('Say hello to start', style: TextStyle(color: Theme.of(context).hintColor, fontSize: 13)),
                        const SizedBox(height: 4),
                        Text('Messages are end-to-end encrypted',
                            style: TextStyle(color: Theme.of(context).hintColor.withOpacity(0.7), fontSize: 11)),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                    itemCount: _messages.length,
                    itemBuilder: (context, i) {
                      final m = _messages[i];
                      final showDate = i == 0 || !_sameDay(_messages[i - 1], m);
                      return Column(
                        children: [
                          if (showDate) _dateChip(m, isDark),
                          _bubbleRow(m, me, accent, isDark),
                        ],
                      );
                    },
                  ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.w600)),
              ),
            ),
          if (_hint != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: GestureDetector(
                // permission hints are tappable → straight to app settings
                onTap: _micResolved && _mic != MicPermission.granted
                    ? () async {
                        await openAppSettings();
                        // re-resolve on return from settings
                        final p = await ref.read(voiceRecorderProvider).resolvePermission(request: false);
                        if (mounted) setState(() { _mic = p; if (p == MicPermission.granted) _hint = null; });
                      }
                    : null,
                child: Text(_hint!, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: accent)),
              ),
            ),
          _composerBar(accent, isDark),
        ],
      ),
    );
  }

  bool _sameDay(Map<String, Object?> a, Map<String, Object?> b) {
    final da = DateTime.tryParse((a['created_at'] ?? '') as String);
    final db2 = DateTime.tryParse((b['created_at'] ?? '') as String);
    if (da == null || db2 == null) return true;
    return da.year == db2.year && da.month == db2.month && da.day == db2.day;
  }

  Widget _dateChip(Map<String, Object?> m, bool isDark) {
    final created = DateTime.tryParse((m['created_at'] ?? '') as String);
    if (created == null) return const SizedBox.shrink();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(created.year, created.month, created.day);
    String label;
    if (that == today) {
      label = 'TODAY';
    } else if (that == today.subtract(const Duration(days: 1))) {
      label = 'YESTERDAY';
    } else {
      label = DateFormat('d MMM yyyy').format(created).toUpperCase();
    }
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withOpacity(0.07) : Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(isDark ? 0.3 : 0.05), blurRadius: 6)],
        ),
        child: Text(label,
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.6, color: Theme.of(context).hintColor)),
      ),
    );
  }

  Widget _bubbleRow(Map<String, Object?> m, String me, Color accent, bool isDark) {
    final isMine = m['sender_id'] == me;
    final isGroup = widget.type == 'group' || widget.type == 'channel';
    final created = DateTime.tryParse((m['created_at'] ?? '') as String);
    final time = created != null ? DateFormat('HH:mm').format(created) : '';
    final isVoice = m['type'] == 'voice_note';

    Widget bubble = _bubble(m, isMine, isGroup, accent, isDark, time, isVoice);

    // swipe-to-reply: drag right (mine) / left (others) past 250 px/s arms reply
    return GestureDetector(
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v > 250) {
          setState(() => _replyTo = m);
        }
      },
      child: Padding(
        padding: EdgeInsets.only(
          left: isMine ? 64 : 4,
          right: isMine ? 4 : 64,
          top: 1.5,
          bottom: 1.5,
        ),
        child: bubble,
      ),
    );
  }

  Widget _bubble(Map<String, Object?> m, bool isMine, bool isGroup, Color accent, bool isDark, String time, bool isVoice) {
    final bgColor = isMine ? accent : (isDark ? const Color(0xFF16202F) : Colors.white);
    final fg = isMine ? Colors.white : (isDark ? Colors.white : const Color(0xFF0F172A));
    final state = (m['delivery_state'] ?? 'sent') as String;

    Widget content;
    if (isVoice) {
      content = _voiceContent(m, isMine, accent, fg);
    } else {
      content = Text(
        (m['content'] ?? '') as String,
        style: TextStyle(fontSize: 14, height: 1.32, fontWeight: FontWeight.w500, color: fg),
      );
    }

    final hasReply = (m['reply_to_id'] ?? '') != '' && m['reply_to_id'] != null;

    return Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(isMine ? 16 : 4),
          bottomRight: Radius.circular(isMine ? 4 : 16),
        ),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(isDark ? 0.25 : 0.06), blurRadius: 5, offset: const Offset(0, 1.5)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isMine && isGroup)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                ((m['sender_name'] ?? 'User') as String),
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: accent),
              ),
            ),
          if (hasReply)
            Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.14),
                borderRadius: BorderRadius.circular(8),
                border: Border(left: BorderSide(color: isMine ? Colors.white : accent, width: 2.5)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text((m['reply_to_name'] ?? 'Reply') as String,
                      style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: isMine ? Colors.white : accent)),
                  Text((m['reply_to_content'] ?? '') as String,
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: fg.withOpacity(0.75))),
                ],
              ),
            ),
          content,
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              const Spacer(),
              Text(time, style: TextStyle(fontSize: 9.5, color: isMine ? Colors.white70 : Theme.of(context).hintColor)),
              if (isMine) ...[
                const SizedBox(width: 3),
                Icon(
                  state == 'read' ? Icons.done_all_rounded : (state == 'delivered' ? Icons.done_all_rounded : Icons.done_rounded),
                  size: 13,
                  color: state == 'read' ? const Color(0xFF53BDEB) : (isMine ? Colors.white70 : Colors.grey),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _voiceContent(Map<String, Object?> m, bool isMine, Color accent, Color fg) {
    final id = m['id'] as String;
    final playing = _playingId == id;
    final dur = playing ? _playDur : Duration(seconds: (m['duration_seconds'] ?? 0) as int);
    final pos = playing ? _playPos : Duration.zero;
    final progress = dur.inMilliseconds > 0 ? pos.inMilliseconds / dur.inMilliseconds : 0.0;
    final waveSeed = (m['id'] as String).hashCode;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: () => _togglePlay(m),
          child: CircleAvatar(
            radius: 16,
            backgroundColor: isMine ? Colors.white24 : accent.withOpacity(0.18),
            child: _loadingMediaId == id
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.8, color: isMine ? Colors.white : accent))
                : Icon(
                    playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: 22,
                    color: isMine ? Colors.white : accent,
                  ),
          ),
        ),
        const SizedBox(width: 8),
        // waveform: 18 bars seeded by message id; played portion tinted
        SizedBox(
          width: 110,
          height: 26,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (var i = 0; i < 18; i++)
                Container(
                  width: 3,
                  height: 5 + ((waveSeed >> i) & 7) * 2.6,
                  decoration: BoxDecoration(
                    color: (i / 18) <= progress
                        ? (isMine ? Colors.white : accent)
                        : fg.withOpacity(0.35),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 6),
        Text(
          _fmt(playing && pos > Duration.zero ? dur - pos : dur),
          style: TextStyle(fontSize: 10.5, color: isMine ? Colors.white70 : Theme.of(context).hintColor),
        ),
      ],
    );
  }

  // ---------------- composer ----------------

  Widget _composerBar(Color accent, bool isDark) {
    if (_recording) return _recordingBar(accent, isDark);

    final hasReply = _replyTo != null;

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasReply)
            Container(
              margin: const EdgeInsets.fromLTRB(10, 6, 10, 0),
              padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF16202F) : Colors.white,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Container(width: 3.5, height: 34, decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(3))),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text((_replyTo!['sender_name'] ?? 'Reply') as String,
                            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: accent)),
                        Text((_replyTo!['content'] ?? '') as String,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () => setState(() => _replyTo = null),
                  ),
                ],
              ),
            ),
          Padding(
            padding: EdgeInsets.only(left: 8, right: 8, bottom: MediaQuery.of(context).padding.bottom + 8, top: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF16202F) : Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(isDark ? 0.2 : 0.05), blurRadius: 8)],
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      children: [
                        IconButton(
                          icon: Icon(Icons.emoji_emotions_outlined, color: Theme.of(context).hintColor, size: 22),
                          onPressed: () {},
                        ),
                        Expanded(
                          child: TextField(
                            controller: _composer,
                            minLines: 1,
                            maxLines: 5,
                            textCapitalization: TextCapitalization.sentences,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _sendText(),
                            style: TextStyle(fontSize: 14.5, color: isDark ? Colors.white : const Color(0xFF0F172A)),
                            decoration: const InputDecoration(
                              hintText: 'Message',
                              filled: false,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              contentPadding: EdgeInsets.symmetric(vertical: 12),
                            ),
                            onChanged: (_) {
                              setState(() {}); // swap mic/send instantly
                              _typingDebounce?.cancel();
                              _typingDebounce = Timer(const Duration(seconds: 2), () {});
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                if (_composer.text.trim().isEmpty)
                  Listener(
                    onPointerDown: _onMicDown,
                    onPointerMove: _onMicMove,
                    onPointerUp: (_) => _onMicUp(),
                    onPointerCancel: (_) => _cancelRecording(),
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                      child: const Icon(Icons.mic_rounded, color: Colors.white, size: 23),
                    ),
                  )
                else
                  GestureDetector(
                    onTap: _sendText,
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                      child: const Icon(Icons.send_rounded, color: Colors.white, size: 21),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// WhatsApp-style recording bar: pulsing red dot + timer + live waveform +
  /// "‹ slide to cancel"; locked state adds trash + send.
  Widget _recordingBar(Color accent, bool isDark) {
    final barColor = isDark ? const Color(0xFF16202F) : Colors.white;
    return SafeArea(
      top: false,
      child: Container(
        margin: EdgeInsets.only(left: 10, right: 10, bottom: MediaQuery.of(context).padding.bottom + 8, top: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: barColor,
          borderRadius: BorderRadius.circular(26),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(isDark ? 0.3 : 0.08), blurRadius: 10)],
        ),
        child: Row(
          children: [
            if (!_locked) ...[
              // pulsing red dot
              Opacity(
                opacity: _recDuration.inMilliseconds % 1000 < 500 ? 1.0 : 0.3,
                child: const Icon(Icons.circle, color: Colors.redAccent, size: 13),
              ),
              const SizedBox(width: 10),
              Text(_fmt(_recDuration),
                  style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w800, fontSize: 14, color: Colors.redAccent)),
              const SizedBox(width: 12),
              // live waveform
              Expanded(
                child: SizedBox(
                  height: 22,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      for (final h in _wave)
                        Container(
                          width: 2.6,
                          height: 4 + h * 16,
                          decoration: BoxDecoration(color: accent.withOpacity(0.75), borderRadius: BorderRadius.circular(2)),
                        ),
                    ],
                  ),
                ),
              ),
              const Icon(Icons.chevron_left, size: 16, color: Colors.grey),
              Text('Slide to cancel',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Theme.of(context).hintColor)),
              const SizedBox(width: 10),
              // lock zone — slide up on the mic to lock
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.keyboard_arrow_up_rounded, size: 14, color: Theme.of(context).hintColor),
                  Icon(Icons.lock_rounded, size: 17, color: Theme.of(context).hintColor),
                ],
              ),
            ] else ...[
              const Icon(Icons.lock_rounded, size: 16, color: Colors.redAccent),
              const SizedBox(width: 8),
              Text('Recording ${_fmt(_recDuration)}',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5, color: Colors.redAccent)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 24),
                onPressed: _cancelRecording,
              ),
              GestureDetector(
                onTap: _finishRecording,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                  child: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _fmt(Duration d) {
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }
}
