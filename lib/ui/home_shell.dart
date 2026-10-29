import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'chats/chats_screen.dart';
import 'chats/chat_screen.dart';
import 'communities/communities_screen.dart';
import 'explore/explore_screen.dart';
import 'profile/profile_screen.dart';

/// WhatsApp-style shell: bottom nav (dark glass, standalone — never a white
/// sheet) that hides while a conversation is open.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _tab = 0;
  String? _openChatId;
  String? _openChatTitle;
  String? _openChatType;

  static const _destinations = [
    (Icons.chat_bubble_rounded, 'Chats'),
    (Icons.groups_rounded, 'Communities'),
    (Icons.explore_rounded, 'Explore'),
    (Icons.person_rounded, 'Profile'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(chatsControllerProvider).reload();
      ref.read(notificationsControllerProvider).reload();
      ref.read(syncEngineProvider).subscribeNotificationsRealtime(() {
        ref.read(notificationsControllerProvider).reload();
      });
    });
  }

  void openChat(String id, String title, String type) {
    setState(() {
      _openChatId = id;
      _openChatTitle = title;
      _openChatType = type;
    });
    ref.read(chatsControllerProvider).markReadAndReload(id);
  }

  @override
  Widget build(BuildContext context) {
    if (_openChatId != null) {
      return ChatScreen(
        chatId: _openChatId!,
        title: _openChatTitle ?? 'Chat',
        type: _openChatType ?? 'direct',
        onBack: () => setState(() => _openChatId = null),
      );
    }

    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          ChatsScreen(onOpenChat: openChat),
          CommunitiesScreen(onOpenChannelChat: openChat),
          const ExploreScreen(),
          const ProfileScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        height: 68,
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          for (final d in _destinations)
            NavigationDestination(
              icon: Icon(d.$1),
              selectedIcon: Icon(d.$1, size: 26),
              label: d.$2,
            ),
        ],
      ),
    );
  }
}
