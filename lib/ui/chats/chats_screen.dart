import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';

/// Chats list — reads the LOCAL database (no network on open).
class ChatsScreen extends ConsumerStatefulWidget {
  final void Function(String chatId, String title, String type) onOpenChat;

  const ChatsScreen({super.key, required this.onOpenChat});

  @override
  ConsumerState<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends ConsumerState<ChatsScreen> {
  bool _syncing = false;

  Future<void> _refresh() async {
    setState(() => _syncing = true);
    try {
      await ref.read(syncEngineProvider).bootstrap();
      ref.read(chatsControllerProvider.notifier).reload();
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chats = ref.watch(chatsControllerProvider);
    final notifications = ref.watch(notificationsControllerProvider);
    final unreadNotifs = notifications.where((n) => n['is_read'] == false).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.notifications_rounded),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const NotificationsScreen()),
                ),
              ),
              if (unreadNotifs > 0)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(
                      unreadNotifs > 99 ? '99+' : '$unreadNotifs',
                      style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: chats.isEmpty
            ? ListView(
                children: const [
                  SizedBox(height: 160),
                  Center(
                    child: Text(
                      'No conversations yet.\nPull to sync.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 13),
                    ),
                  ),
                ],
              )
            : ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: chats.length,
                itemBuilder: (context, i) {
                  final c = chats[i];
                  final unread = (c['unread_count'] as int? ?? 0);
                  final isGroup = c['type'] == 'group' || c['type'] == 'channel';
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Theme.of(context).colorScheme.primary.withOpacity(0.15),
                      backgroundImage: c['avatar_url'] != null ? NetworkImage(c['avatar_url'] as String) : null,
                      child: c['avatar_url'] == null
                          ? Text(
                              ((c['name'] ?? '') as String).isEmpty ? '?' : (c['name'] as String).trim().substring(0, 1).toUpperCase().toUpperCase(),
                              style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w800),
                            )
                          : null,
                    ),
                    title: Text(
                      (c['name'] ?? 'Conversation') as String,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                    ),
                    subtitle: Text(
                      (c['last_message_text'] ?? 'Say hello') as String,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5),
                    ),
                    trailing: unread > 0
                        ? Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text('$unread', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800)),
                          )
                        : null,
                    onTap: () => widget.onOpenChat(
                      c['id'] as String,
                      (c['name'] ?? 'Conversation') as String,
                      (c['type'] ?? 'direct') as String,
                    ),
                  );
                },
              ),
      ),
      floatingActionButton: _syncing
          ? const CircularProgressIndicator()
          : FloatingActionButton(
              onPressed: _refresh,
              child: const Icon(Icons.sync_rounded),
            ),
    );
  }
}

/// Notification center.
class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => ref.read(notificationsControllerProvider.notifier).reload());
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(notificationsControllerProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          if (items.any((n) => n['is_read'] == false))
            TextButton(
              onPressed: () => ref.read(notificationsControllerProvider.notifier).markAllRead(),
              child: const Text('Mark all read'),
            ),
        ],
      ),
      body: items.isEmpty
          ? const Center(child: Text("You're all caught up", style: TextStyle(color: Colors.grey)))
          : ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final n = items[i];
                final isUnread = n['is_read'] == false;
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: isUnread
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.primary.withOpacity(0.12),
                    child: Icon(Icons.chat_bubble_rounded,
                        size: 18, color: isUnread ? Colors.white : Theme.of(context).colorScheme.primary),
                  ),
                  title: Text((n['title'] ?? 'Relay') as String,
                      style: TextStyle(fontWeight: isUnread ? FontWeight.w800 : FontWeight.w600, fontSize: 14)),
                  subtitle: Text((n['body'] ?? '') as String, style: const TextStyle(fontSize: 12.5)),
                  trailing: isUnread
                      ? Container(width: 8, height: 8, decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, shape: BoxShape.circle))
                      : null,
                  onTap: () {
                    ref.read(notificationsControllerProvider.notifier).markAllRead();
                    Navigator.of(context).pop();
                  },
                );
              },
            ),
    );
  }
}
