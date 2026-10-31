import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'chats/chats_screen.dart';
import 'chats/chat_screen.dart';
import 'communities/communities_screen.dart';
import 'explore/explore_screen.dart';
import 'profile/profile_screen.dart';

/// WhatsApp-style shell. The bottom nav keeps the liquid-glass LOOK
/// (frosted tint, specular top highlight, accent selection pill) but drops the
/// live BackdropFilter — a 22-sigma realtime blur re-renders the whole list
/// beneath it every frame, which on mid/low-end GPUs stalls the raster
/// pipeline until scrolling feels broken. A translucent tint + hairline reads
/// the same and costs nothing. It hides completely while a conversation open.
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
    // register the global hook so Explore/People can open DMs through the shell
    relayOpenChatCallback = openChat;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(chatsControllerProvider.notifier).reload();
      ref.read(notificationsControllerProvider.notifier).reload();
      ref.read(syncEngineProvider).subscribeNotificationsRealtime(() {
        ref.read(notificationsControllerProvider.notifier).reload();
      });
    });
  }

  void openChat(String id, String title, String type) {
    setState(() {
      _openChatId = id;
      _openChatTitle = title;
      _openChatType = type;
    });
    ref.read(chatsControllerProvider.notifier).markReadAndReload(id);
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

    // real unread total across chats — the badge used to be hardwired to 0
    final chats = ref.watch(chatsControllerProvider);
    var unread = 0;
    for (final c in chats) {
      final v = c['unread_count'];
      if (v is int) unread += v;
      if (v is num) unread += v.toInt();
      if (v is String) unread += int.tryParse(v) ?? 0;
    }

    return Scaffold(
      extendBody: true,
      body: IndexedStack(
        index: _tab,
        children: [
          ChatsScreen(onOpenChat: openChat),
          CommunitiesScreen(onOpenChannelChat: openChat),
          const ExploreScreen(),
          const ProfileScreen(),
        ],
      ),
      bottomNavigationBar: _GlassNavBar(
        destinations: _destinations,
        currentIndex: _tab,
        unreadBadge: unread,
        onSelect: (i) => setState(() => _tab = i),
      ),
    );
  }
}

/// Liquid-glass-look navigation bar — frosted tint + specular edge + accent
/// pill. No BackdropFilter: scrolling stays 60fps even on budget devices.
class _GlassNavBar extends ConsumerStatefulWidget {
  final List<(IconData, String)> destinations;
  final int currentIndex;
  final int unreadBadge;
  final ValueChanged<int> onSelect;

  const _GlassNavBar({
    required this.destinations,
    required this.currentIndex,
    required this.onSelect,
    this.unreadBadge = 0,
  });

  @override
  ConsumerState<_GlassNavBar> createState() => _GlassNavBarState();
}

class _GlassNavBarState extends ConsumerState<_GlassNavBar> {
  @override
  Widget build(BuildContext context) {
    final accent = ref.watch(themeControllerProvider).accent;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Glass tint: light mode = bright frosted white, dark = deep translucent
    // slate. Opaque enough to read labels over any content.
    final glassTint = isDark
        ? const Color(0xFF0B1220).withOpacity(0.86)
        : Colors.white.withOpacity(0.88);
    final edgeHighlight = isDark ? Colors.white.withOpacity(0.16) : Colors.white.withOpacity(0.9);
    final hairline = isDark ? Colors.white.withOpacity(0.10) : const Color(0xFF0F172A).withOpacity(0.08);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
        child: Container(
          decoration: BoxDecoration(
            color: glassTint,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: hairline, width: 0.8),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [glassTint, (isDark ? const Color(0xFF0B1220) : Colors.white).withOpacity(0.55)],
            ),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(isDark ? 0.45 : 0.10), blurRadius: 24, offset: const Offset(0, 8)),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(26),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(26),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [edgeHighlight, edgeHighlight.withOpacity(0.0)],
                  stops: const [0, 0.12],
                ),
              ),
              child: Row(
                children: [
                  for (var i = 0; i < widget.destinations.length; i++)
                    Expanded(
                      child: _GlassTab(
                        icon: widget.destinations[i].$1,
                        label: widget.destinations[i].$2,
                        selected: widget.currentIndex == i,
                        accent: accent,
                        isDark: isDark,
                        showBadge: i == 0 && widget.unreadBadge > 0,
                        badgeCount: widget.unreadBadge,
                        onTap: () => widget.onSelect(i),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassTab extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final Color accent;
  final bool isDark;
  final bool showBadge;
  final int badgeCount;
  final VoidCallback onTap;

  const _GlassTab({
    required this.icon,
    required this.label,
    required this.selected,
    required this.accent,
    required this.isDark,
    required this.onTap,
    this.showBadge = false,
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final fg = selected ? accent : (isDark ? Colors.white70 : const Color(0xFF64748B));
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
                  decoration: BoxDecoration(
                    color: selected ? accent.withOpacity(0.18) : Colors.transparent,
                    borderRadius: BorderRadius.circular(16),
                    border: selected ? Border.all(color: accent.withOpacity(0.35), width: 1) : null,
                    boxShadow: selected
                        ? [BoxShadow(color: accent.withOpacity(0.25), blurRadius: 12, offset: const Offset(0, 3))]
                        : null,
                  ),
                  child: Icon(icon, size: 22, color: fg),
                ),
                if (showBadge)
                  Positioned(
                    top: -4,
                    right: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      constraints: const BoxConstraints(minWidth: 15),
                      decoration: BoxDecoration(
                        color: Colors.redAccent,
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: isDark ? const Color(0xFF0B1220) : Colors.white, width: 1.2),
                      ),
                      child: Text(
                        badgeCount > 99 ? '99+' : '$badgeCount',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 8.5,
                          height: 1.25,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 3),
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 220),
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                color: fg,
                letterSpacing: 0.1,
              ),
              child: Text(label),
            ),
          ],
        ),
      ),
    );
  }
}
