import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:realtime_client/realtime_client.dart';
import 'package:record/record.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/constants.dart';
import '../../data/local/local_db.dart';
import '../../state/providers.dart';

/// Chat screen — WhatsApp alignment (mine right / accent, others left),
/// swipe-to-reply, and the hold-to-record voice flow: hold the mic to record,
/// slide up to lock, slide left to cancel, release to send.
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

  // voice state
  bool _recording = false;
  bool _locked = false;
  Duration _recDuration = Duration.zero;
  Timer? _recTicker;
  DateTime? _pressStart;
  double _pressStartDy = 0;
  double _pressStartDx = 0;
  String? _hint;
  String? _error;

  RealtimeChannel? _channel;

  @override
  void initState() {
    super.initState();
    _loadLocalThenSync();
    _subscribe();
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
        _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    _composer.dispose();
    _scroll.dispose();
    _typingDebounce?.cancel();
    super.dispose();
  }

  Future<void> _sendText() async {
    final text = _composer.text.trim();
    if (text.isEmpty) return;
    _composer.clear();
    final payload = jsonEncode({'k': 't', 't': text});
    try {
      await ref.read(apiProvider).sendMessageRaw(widget.chatId, payload, 'text');
      await ref.read(syncEngineProvider).syncMessages(widget.chatId);
      setState(() => _messages = ref.read(localDbProvider).listMessages(widget.chatId));
      _scrollToBottom();
    } catch (e) {
      setState(() => _error = 'Failed to send — try again');
    }
  }

  Future<void> _sendVoice(String filePath) async {
    // encrypted upload path — mirrors the web client (ciphertext-only storage)
    setState(() => _error = null);
    try {
      final uploaded = await ref.read(apiProvider).uploadEncryptedFile(filePath);
      final payload = jsonEncode({
        'k': 'm',
        'u': uploaded['url'],
        'key': uploaded['mediaKey'],
        'mime': 'audio/mp4',
        'name': 'VoiceNote.m4a',
      });
      await ref.read(apiProvider).sendMessageRaw(widget.chatId, payload, 'voice_note');
      await ref.read(syncEngineProvider).syncMessages(widget.chatId);
      setState(() => _messages = ref.read(localDbProvider).listMessages(widget.chatId));
      _scrollToBottom();
    } catch (e) {
      setState(() => _error = 'Voice send failed');
    }
  }

  // ---------------- hold-to-record ----------------

  Future<void> _onMicDown(PointerDownEvent e) async {
    final recorder = ref.read(voiceRecorderProvider);
    if (!await recorder.hasPermission()) {
      setState(() => _hint = 'Microphone permission required');
      return;
    }
    _pressStart = DateTime.now();
    _pressStartDy = e.position.dy;
    _pressStartDx = e.position.dx;
    await recorder.start();
    _recTicker?.cancel();
    _recDuration = Duration.zero;
    _recTicker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted || !_recording) return;
      setState(() => _recDuration = DateTime.now().difference(_pressStart!));
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
    try { await recorder.stop(); } catch (_) {}
    setState(() {
      _recording = false;
      _locked = false;
    });
  }

  Future<void> _finishRecording() async {
    final recorder = ref.read(voiceRecorderProvider);
    _recTicker?.cancel();
    final path = await recorder.stop();
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

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: widget.onBack),
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: accent.withOpacity(0.15),
              child: Text(widget.title.isNotEmpty ? widget.title[0].toUpperCase() : '?',
                  style: TextStyle(color: accent, fontWeight: FontWeight.w800, fontSize: 13)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                  if (widget.type == 'group')
                    Text('group', style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
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
                ? const Center(child: Text('Say hello to start', style: TextStyle(color: Colors.grey)))
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    itemCount: _messages.length,
                    itemBuilder: (context, i) => _bubble(_messages[i], me, accent),
                  ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 11)),
              ),
            ),
          if (_hint != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(_hint!, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
            ),
          _composerBar(accent),
        ],
      ),
    );
  }

  Widget _bubble(Map<String, Object?> m, String me, Color accent) {
    final isMine = m['sender_id'] == me;
    final isGroup = widget.type == 'group' || widget.type == 'channel';
    final created = DateTime.tryParse((m['created_at'] ?? '') as String);
    final time = created != null ? DateFormat('HH:mm').format(created) : '';
    final isVoice = m['type'] == 'voice_note';

    final bubble = Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: isMine ? accent : (Theme.of(context).brightness == Brightness.dark ? const Color(0xFF16202F) : Colors.white),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(isMine ? 18 : 4),
          bottomRight: Radius.circular(isMine ? 4 : 18),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMine && isGroup)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                (m['sender_name'] ?? 'User') as String,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: accent),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: isVoice
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.play_arrow_rounded, color: Colors.white70),
                      Text('Voice note', style: TextStyle(color: isMine ? Colors.white : null, fontSize: 13, fontWeight: FontWeight.w600)),
                    ],
                  )
                : Text(
                    (m['content'] ?? '') as String,
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: isMine ? Colors.white : null),
                  ),
          ),
          const SizedBox(height: 2),
          Text(time, style: TextStyle(fontSize: 9, color: isMine ? Colors.white70 : Colors.grey)),
        ],
      ),
    );

    return GestureDetector(
      onHorizontalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) > 250) {
          _composer.text = '${m['sender_name'] ?? ''}: ${m['content']}';
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: [bubble],
        ),
      ),
    );
  }

  Widget _composerBar(Color accent) {
    if (_recording) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(color: Theme.of(context).brightness == Brightness.dark ? Colors.black : Colors.white),
        child: Row(
          children: [
            const Icon(Icons.circle, color: Colors.red, size: 12),
            const SizedBox(width: 8),
            Text(_fmt(_recDuration), style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w700)),
            const SizedBox(width: 10),
            if (!_locked)
              const Expanded(
                child: Row(children: [
                  Icon(Icons.chevron_left, size: 16),
                  Text('Slide left to cancel', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                ]),
              )
            else
              Expanded(child: Text('Locked — release and tap send', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: accent))),
            const SizedBox(width: 8),
            if (_locked) ...[
              IconButton(icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent), onPressed: _cancelRecording),
              IconButton(icon: Icon(Icons.send_rounded, color: accent), onPressed: _finishRecording),
            ] else
              Expanded(child: Container()),
          ],
        ),
      );
    }

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(left: 8, right: 8, bottom: MediaQuery.of(context).padding.bottom + 6, top: 6),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _composer,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _sendText(),
                decoration: const InputDecoration(hintText: 'Message'),
                onChanged: (_) {
                  _typingDebounce?.cancel();
                  _typingDebounce = Timer(const Duration(seconds: 2), () {});
                },
              ),
            ),
            if (_composer.text.trim().isEmpty)
              Listener(
                onPointerDown: _onMicDown,
                onPointerMove: _onMicMove,
                onPointerUp: (_) => _onMicUp(),
                onPointerCancel: (_) => _cancelRecording(),
                child: IconButton(icon: const Icon(Icons.mic_rounded), onPressed: () {}, style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap)),
              )
            else
              IconButton.filled(
                icon: const Icon(Icons.send_rounded),
                onPressed: _sendText,
                style: FilledButton.styleFrom(backgroundColor: accent),
              ),
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
