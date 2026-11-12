import 'package:flutter/material.dart';
import '../models/media_item.dart';
import '../services/api_client.dart';

class VirtualFoldersScreen extends StatefulWidget {
  const VirtualFoldersScreen({super.key, required this.api, required this.onPlay});
  final ApiClient api;
  final Future<void> Function(MediaItem) onPlay;

  @override
  State<VirtualFoldersScreen> createState() => _VirtualFoldersScreenState();
}

class _VirtualFoldersScreenState extends State<VirtualFoldersScreen> {
  late Future<Map<String, dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.api.catalogTree();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Virtual folders')),
        body: FutureBuilder<Map<String, dynamic>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
            if (snapshot.hasError) return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(snapshot.error.toString())));
            final tree = (snapshot.data?['tree'] as Map?)?.cast<String, dynamic>() ?? {};
            final movies = (tree['movies'] as List? ?? []);
            final shows = (tree['tv_shows'] as List? ?? []);
            final other = (tree['other_files'] as List? ?? []);
            return RefreshIndicator(
              onRefresh: () async => setState(() => _future = widget.api.catalogTree()),
              child: ListView(padding: const EdgeInsets.all(12), children: [
                _root('Movies', Icons.movie_outlined, movies.length, movies.map((movie) {
                  final row = movie as Map;
                  return ExpansionTile(
                    title: Text('${row['name']}'),
                    children: _mediaRows(row['items'] as List? ?? []),
                  );
                })),
                _root('TV Shows', Icons.live_tv_outlined, shows.length, shows.map((show) {
                  final row = show as Map;
                  final seasons = row['seasons'] as List? ?? [];
                  return ExpansionTile(
                    title: Text('${row['name']}'),
                    children: seasons.map((season) {
                      final s = season as Map;
                      return ExpansionTile(
                        leading: const Icon(Icons.folder_outlined, size: 18),
                        title: Text('${s['name']}'),
                        children: _mediaRows(s['items'] as List? ?? []),
                      );
                    }).toList(),
                  );
                })),
                _root('Other Files', Icons.folder_open_outlined, other.length, other.map((file) {
                  final item = MediaItem.fromJson((file as Map).cast<String, dynamic>());
                  return ListTile(leading: const Icon(Icons.insert_drive_file_outlined), title: Text(item.title), subtitle: Text(item.sourceName));
                })),
              ]),
            );
          },
        ),
      );

  Widget _root(String title, IconData icon, int count, Iterable<Widget> children) => Card(
        color: const Color(0xFF141414),
        child: ExpansionTile(
          initiallyExpanded: true,
          leading: Icon(icon, color: const Color(0xFFE50914)),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          trailing: Text('$count', style: const TextStyle(color: Colors.white54)),
          children: children.toList(),
        ),
      );

  List<Widget> _mediaRows(List<dynamic> rows) => rows.map((row) {
        final item = MediaItem.fromJson((row as Map).cast<String, dynamic>());
        return ListTile(
          dense: true,
          leading: const Icon(Icons.play_circle_outline, color: Color(0xFFE50914)),
          title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${item.episode != null ? 'E${item.episode} · ' : ''}${item.sourceName}'),
          trailing: Text(MediaItem.formatSize(item.size), style: const TextStyle(color: Colors.white54, fontSize: 11)),
          onTap: item.isVideo ? () => widget.onPlay(item) : null,
        );
      }).toList();
}
