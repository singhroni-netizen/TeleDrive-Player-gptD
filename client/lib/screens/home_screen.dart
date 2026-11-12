import 'dart:async';
import 'package:flutter/material.dart';
import '../models/media_item.dart';
import '../services/api_client.dart';
import '../widgets/poster_card.dart';
import 'player_screen.dart';
import 'settings_screen.dart';
import 'virtual_folders_screen.dart';
import 'sources_screen.dart';
import 'teledrive_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.api});
  final ApiClient api;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _search = TextEditingController();
  Timer? _debounce;
  List<MediaItem> _items = [];
  Map<String, dynamic> _progress = {};
  List<dynamic> _warnings = [];
  bool _loading = true;
  String _filter = 'All';
  String? _error;

  @override
  void initState() { super.initState(); _load(); }
  @override
  void dispose() { _search.dispose(); _debounce?.cancel(); super.dispose(); }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([widget.api.catalog(query: _search.text.trim()), widget.api.progress()]);
      final payload = results[0] as List<MediaItem>;
      final progress = results[1] as Map<String, dynamic>;
      if (mounted) setState(() { _items = payload; _progress = progress; _warnings = widget.api.lastWarnings; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  List<MediaItem> get _visibleItems => _items.where((x) {
    if (_filter == 'Movies') return x.isVideo && x.season == null;
    if (_filter == 'TV Shows') return x.isVideo && (x.season != null || x.episode != null);
    if (_filter == 'Files') return !x.isVideo;
    if (_filter == 'Low Data') {
      final quality = (x.quality ?? x.filename ?? x.title).toString().toLowerCase();
      return x.isVideo && ((x.size > 0 && x.size <= 800 * 1024 * 1024) || RegExp(r'(360p|480p|576p|720p)').hasMatch(quality));
    }
    return true;
  }).toList();

  double _itemProgress(MediaItem item) {
    final p = _progress[item.key];
    if (p is! Map) return 0;
    final position = (p['position_ms'] as num?)?.toDouble() ?? 0;
    final duration = (p['duration_ms'] as num?)?.toDouble() ?? 0;
    return duration > 0 && position < duration - 15000 ? position / duration : 0;
  }

  Future<void> _deepSearch() async {
    final query = _search.text.trim();
    if (query.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a longer description to use Deep Search.')));
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final results = await widget.api.deepSearch(query);
      if (mounted) setState(() { _items = results; _warnings = widget.api.lastWarnings; _loading = false; _filter = 'All'; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _play(MediaItem item) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerScreen(api: widget.api, item: item)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visibleItems;
    final hero = visible.where((x) => x.isVideo).firstOrNull;
    final continueItems = visible.where((x) => _itemProgress(x) > 0).toList()
      ..sort((a, b) => _itemProgress(b).compareTo(_itemProgress(a)));
    return Scaffold(
      appBar: AppBar(
        title: const Text('TELEDRIVE', style: TextStyle(color: Color(0xFFE50914), fontWeight: FontWeight.w900, letterSpacing: 1.2)),
        actions: [
          IconButton(tooltip: 'Open TeleDrive storage', onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TeleDriveScreen(onPlay: _play))), icon: const Icon(Icons.cloud_done_outlined, color: Color(0xFFE50914))),
          IconButton(tooltip: 'Virtual folders', onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => VirtualFoldersScreen(api: widget.api, onPlay: _play))), icon: const Icon(Icons.folder_copy_outlined)),
          IconButton(tooltip: 'Data sources', onPressed: () async { await Navigator.push(context, MaterialPageRoute(builder: (_) => SourcesScreen(api: widget.api))); _load(); }, icon: const Icon(Icons.cloud_queue_outlined)),
          IconButton(tooltip: 'Settings', onPressed: () async { await Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen(api: widget.api))); _load(); }, icon: const Icon(Icons.settings_outlined)),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 8), child: TextField(
          controller: _search,
          onChanged: (_) { _debounce?.cancel(); _debounce = Timer(const Duration(milliseconds: 350), _load); },
          decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: 'Search titles, years, codecs or episodes',
            suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [IconButton(tooltip: 'Deep AI search', onPressed: _deepSearch, icon: const Icon(Icons.auto_awesome, color: Color(0xFFE50914))), IconButton(onPressed: () { _search.clear(); _filter = 'All'; _load(); }, icon: const Icon(Icons.close))])),
        )),
        SizedBox(height: 42, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12),
          children: ['All', 'Movies', 'TV Shows', 'Low Data', 'Files'].map((f) => Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: ChoiceChip(
            label: Text(f), selected: f == _filter, selectedColor: const Color(0xFFE50914), backgroundColor: const Color(0xFF171717),
            onSelected: (_) => setState(() => _filter = f),))).toList())),
        Expanded(child: _loading ? const Center(child: CircularProgressIndicator(color: Color(0xFFE50914))) :
          _error != null ? _errorView() : RefreshIndicator(color: const Color(0xFFE50914), onRefresh: _load,
            child: CustomScrollView(slivers: [
              if (_warnings.isNotEmpty) SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(12), child: Text('${_warnings.length} source(s) reported an error. Check Data Sources.', style: const TextStyle(color: Colors.orangeAccent)))),
              if (hero != null && _search.text.isEmpty && _filter == 'All') SliverToBoxAdapter(child: _hero(hero)),
              if (continueItems.isNotEmpty) SliverToBoxAdapter(child: _section('Continue Watching', continueItems)),
              if (visible.isNotEmpty) SliverToBoxAdapter(child: _section(_search.text.isEmpty ? 'Your Library' : 'Search Results', visible)),
              if (visible.isEmpty) SliverFillRemaining(hasScrollBody: false, child: Center(child: Padding(padding: const EdgeInsets.all(30), child: Text(
                _items.isEmpty ? 'Your catalog is empty. Add a data source to get started.' : 'No matching media found.', textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 16))))),
              const SliverToBoxAdapter(child: SizedBox(height: 40)),
            ])),
        ),
      ]),
    );
  }

  Widget _errorView() => Center(child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisSize: MainAxisSize.min, children: [
    const Icon(Icons.cloud_off_outlined, size: 44, color: Colors.white38), const SizedBox(height: 14), Text(_error!, textAlign: TextAlign.center),
    const SizedBox(height: 14), FilledButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen(api: widget.api))), child: const Text('Configure backend')),
    TextButton(onPressed: _load, child: const Text('Retry')),
  ])));

  Widget _hero(MediaItem item) => SizedBox(height: 340, child: Stack(fit: StackFit.expand, children: [
    if (item.poster != null && item.poster!.isNotEmpty) Image.network(item.poster!, fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => Container(color: const Color(0xFF171717)))
    else Container(color: const Color(0xFF171717)),
    Container(decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.centerRight, end: Alignment.centerLeft,
      colors: [Colors.black54, Colors.black87, Colors.black], stops: [0, .48, 1]))),
    Positioned(left: 20, right: 20, bottom: 25, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('FEATURED', style: TextStyle(color: Color(0xFFE50914), fontWeight: FontWeight.w900, letterSpacing: 2)),
      const SizedBox(height: 8), Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 27)),
      const SizedBox(height: 8), Text('${item.year ?? ''}  •  ${item.sourceName}  •  ${MediaItem.formatSize(item.size)}', style: const TextStyle(color: Colors.white70)),
      if ((item.description ?? '').isNotEmpty) Padding(padding: const EdgeInsets.only(top: 5), child: Text(item.description!, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white60))),
      const SizedBox(height: 14), FilledButton.icon(onPressed: () => _play(item), icon: const Icon(Icons.play_arrow), label: const Text('Play'),
        style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE50914), foregroundColor: Colors.white)),
    ])),
  ]));

  Widget _section(String title, List<MediaItem> items) => Padding(padding: const EdgeInsets.only(top: 18, bottom: 6), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800))),
    const SizedBox(height: 10), SizedBox(height: 292, child: ListView.separated(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: items.length, separatorBuilder: (_, __) => const SizedBox(width: 12),
      itemBuilder: (_, i) => PosterCard(item: items[i], progress: _itemProgress(items[i]), onTap: () => _play(items[i])))),
  ]));
}

extension FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
