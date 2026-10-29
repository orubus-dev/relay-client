import 'package:flutter/material.dart';

/// Explore — X/Threads/TikTok mix: threads-style For You feed, stories strip,
/// people rows. Placeholder feed pulls in from the web app's public feed.
class ExploreScreen extends StatefulWidget {
  const ExploreScreen({super.key});

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Explore', style: TextStyle(fontWeight: FontWeight.w800)),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'For you'),
            Tab(text: 'Stories'),
            Tab(text: 'People'),
          ],
          dividerColor: Colors.transparent,
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _forYou(),
          _stories(),
          _people(),
        ],
      ),
    );
  }

  Widget _forYou() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _threadCard('Relay', 'End-to-end encrypted by default. Your keys never leave the device.'),
        _threadCard('Communities', 'Channels are live: text + voice, Discord-style.'),
        _threadCard('Voice notes', 'Hold to record, slide up to lock — just like WhatsApp.'),
      ],
    );
  }

  Widget _threadCard(String author, String text) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 15,
                  backgroundColor: Theme.of(context).colorScheme.primary.withOpacity(0.15),
                  child: Text(author[0], style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.primary)),
                ),
                const SizedBox(width: 8),
                Text(author, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
              ],
            ),
            const SizedBox(height: 8),
            Text(text, style: const TextStyle(fontSize: 13.5, height: 1.45)),
          ],
        ),
      ),
    );
  }

  Widget _stories() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome_rounded, size: 42, color: Theme.of(context).hintColor),
          const SizedBox(height: 10),
          const Text('Stories sync from the web app', style: TextStyle(color: Colors.grey, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _people() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.person_search_rounded, size: 42, color: Theme.of(context).hintColor),
          const SizedBox(height: 10),
          const Text('Search people on the Explore tab of the web app', style: TextStyle(color: Colors.grey, fontSize: 13)),
        ],
      ),
    );
  }
}
