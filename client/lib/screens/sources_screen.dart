import 'dart:convert';
import 'package:flutter/material.dart';
import '../services/api_client.dart';

class SourcesScreen extends StatefulWidget {
  const SourcesScreen({super.key, required this.api});
  final ApiClient api;

  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen> {
  late Future<List<Map<String, dynamic>>> _future;
  @override
  void initState() { super.initState(); _reload(); }
  void _reload() => _future = widget.api.sources();

  Future<void> _add() async {
    final result = await showDialog<_SourceDraft>(context: context, builder: (_) => const _SourceDialog());
    if (result == null) return;
    try {
      final created = await widget.api.addSource(result.name, result.kind, result.config);
      if (result.kind == 'json' && result.uploadJson) await widget.api.uploadJson(created['id'].toString());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Source added')));
        setState(_reload);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _test(String id) async {
    try {
      final result = await widget.api.testSource(id);
      if (!mounted) return;
      showDialog<void>(context: context, builder: (_) => AlertDialog(
        title: Text(result['ok'] == true ? 'Connection successful' : 'Connection failed'),
        content: Text(result['ok'] == true ? '${result['items_found']} catalog items found.' : '${result['error'] ?? 'Unknown error'}'),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _edit(Map<String, dynamic> source) async {
    final config = (source['config'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final draft = await showDialog<_SourceDraft>(context: context,
      builder: (_) => _SourceDialog(initialName: source['name']?.toString() ?? '',
        initialKind: source['kind']?.toString() ?? 'rest', initialConfig: config));
    if (draft == null) return;
    try {
      await widget.api.updateSource(source['id'].toString(), draft.name, draft.kind, draft.config);
      if (mounted) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Source updated'))); setState(_reload); }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _toggle(String id, bool enabled) async {
    try { await widget.api.setSourceEnabled(id, enabled); if (mounted) setState(_reload); }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()))); }
  }

  Future<void> _delete(String id) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Remove source?'), content: const Text('This removes the source from the catalog. Cloud files are not deleted.'),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove'))],
    ));
    if (ok != true) return;
    try { await widget.api.deleteSource(id); if (mounted) setState(_reload); }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()))); }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Data sources'), leading: const BackButton(), actions: [
      IconButton(onPressed: _add, tooltip: 'Add source', icon: const Icon(Icons.add_circle_outline, color: Color(0xFFE50914))),
    ]),
    floatingActionButton: FloatingActionButton.extended(onPressed: _add, backgroundColor: const Color(0xFFE50914),
      icon: const Icon(Icons.add), label: const Text('Add source')),
    body: FutureBuilder<List<Map<String, dynamic>>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
        if (snapshot.hasError) return _error(snapshot.error.toString());
        final rows = snapshot.data ?? [];
        if (rows.isEmpty) return const Center(child: Text('No sources configured yet. Add Telegram, Teldrive, JSON, REST, M3U or direct links.'));
        return ListView.separated(padding: const EdgeInsets.all(16), itemCount: rows.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final source = rows[index];
            final id = source['id'].toString();
            final kind = source['kind'].toString();
            final icon = switch (kind) {
              'telegram' => Icons.send,
              'teldrive' => Icons.cloud_outlined,
              'json' => Icons.data_object,
              'rest' => Icons.api,
              'm3u' => Icons.playlist_play,
              _ => Icons.link,
            };
            return Container(
              decoration: BoxDecoration(color: const Color(0xFF141414), borderRadius: BorderRadius.circular(12)),
              child: ListTile(
                leading: CircleAvatar(backgroundColor: const Color(0xFF252525), child: Icon(icon)),
                title: Text(source['name'].toString()),
                subtitle: Text('${kind.toUpperCase()}  ·  ${source['enabled'] == true ? 'ENABLED' : 'DISABLED'}', style: const TextStyle(color: Colors.white54, fontSize: 11)),
                trailing: Wrap(spacing: 0, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Switch(value: source['enabled'] == true, onChanged: (v) => _toggle(id, v), activeColor: const Color(0xFFE50914)),
                  IconButton(tooltip: 'Test connection', onPressed: () => _test(id), icon: const Icon(Icons.wifi_tethering)),
                  IconButton(tooltip: 'Edit source', onPressed: () => _edit(source), icon: const Icon(Icons.edit_outlined)),
                  if (kind == 'json') IconButton(tooltip: 'Upload JSON', onPressed: () async {
                    try { await widget.api.uploadJson(id); if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Catalog uploaded'))); }
                    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()))); }
                  }, icon: const Icon(Icons.upload_file)),
                  IconButton(tooltip: 'Remove', onPressed: () => _delete(id), icon: const Icon(Icons.delete_outline, color: Colors.redAccent)),
                ]),
              ),
            );
          },
        );
      },
    ),
  );

  Widget _error(String message) => Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(message, textAlign: TextAlign.center)));
}

class _SourceDraft {
  const _SourceDraft(this.name, this.kind, this.config, {this.uploadJson = false});
  final String name;
  final String kind;
  final Map<String, dynamic> config;
  final bool uploadJson;
}

class _SourceDialog extends StatefulWidget {
  const _SourceDialog({this.initialName = '', this.initialKind = 'telegram', this.initialConfig});
  final String initialName;
  final String initialKind;
  final Map<String, dynamic>? initialConfig;
  @override
  State<_SourceDialog> createState() => _SourceDialogState();
}

class _SourceDialogState extends State<_SourceDialog> {
  final _name = TextEditingController();
  final _config = TextEditingController();
  String _kind = 'telegram';
  bool _upload = false;

  String _template(String kind) => switch (kind) {
    'telegram' => '{\n  "channel": "@your_channel",\n  "limit": 500\n}',
    'teldrive' => '{\n  "base_url": "https://your-teldrive-host",\n  "token_env": "TELDRIVE_TOKEN",\n  "auth_header": "X-Api-Key",\n  "auth_prefix": "",\n  "list_path": "/api/files",\n  "items_path": "files",\n  "hash_field": "hash",\n  "download_path": "/api/files/{id}/{name}?hash={hash}&download=1",\n  "list_params": {"page": 1, "order": "asc", "sort": "name", "path": "/"},\n  "type_field": "type",\n  "id_field": "id",\n  "title_field": "name",\n  "mime_field": "mime_type",\n  "size_field": "size"\n}',
    'm3u' => '{\n  "url": "https://example.com/playlist.m3u"\n}',
    'json' => '{\n  "items_path": "items",\n  "url": "https://example.com/catalog.json",\n  "id_field": "id",\n  "title_field": "title",\n  "url_field": "url"\n}',
    'rest' => '{\n  "base_url": "https://api.example.com",\n  "list_path": "/media",\n  "items_path": "data.items",\n  "token_env": "MEDIA_API_TOKEN",\n  "auth_header": "Authorization",\n  "auth_prefix": "Bearer ",\n  "id_field": "id",\n  "title_field": "file_name",\n  "url_field": "stream_url",\n  "mime_field": "mime_type",\n  "size_field": "size"\n}',
    _ => '{\n  "links": [\n    {"title": "Example movie", "url": "https://example.com/movie.mp4"}\n  ]\n}',
  };

  @override
  void initState() {
    super.initState();
    _kind = widget.initialKind;
    _name.text = widget.initialName;
    _config.text = widget.initialConfig == null
        ? _template(_kind)
        : JsonEncoder.withIndent('  ').convert(widget.initialConfig);
  }
  @override
  void dispose() { _name.dispose(); _config.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.initialName.isEmpty ? 'Add media source' : 'Edit media source'),
    content: SizedBox(width: 560, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(controller: _name, decoration: const InputDecoration(labelText: 'Display name', hintText: 'My Telegram library')),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(value: _kind, decoration: const InputDecoration(labelText: 'Source type'),
        items: const [
          DropdownMenuItem(value: 'telegram', child: Text('Telegram channel / group (MTProto)')),
          DropdownMenuItem(value: 'teldrive', child: Text('Teldrive API')),
          DropdownMenuItem(value: 'json', child: Text('JSON catalog')),
          DropdownMenuItem(value: 'rest', child: Text('Generic REST API')),
          DropdownMenuItem(value: 'link', child: Text('Direct HTTP / HTTPS links')),
          DropdownMenuItem(value: 'm3u', child: Text('M3U / M3U8 playlist')),
        ], onChanged: (value) { if (value != null) setState(() { _kind = value; _config.text = _template(value); _upload = false; }); }),
      const SizedBox(height: 12),
      TextField(controller: _config, minLines: 9, maxLines: 16, style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        decoration: const InputDecoration(labelText: 'Source configuration (JSON)', alignLabelWithHint: true)),
      if (_kind == 'json') CheckboxListTile(contentPadding: EdgeInsets.zero, value: _upload,
        onChanged: (v) => setState(() => _upload = v ?? false), title: const Text('Upload a local JSON file after creating this source')),
      const SizedBox(height: 4),
      const Text('Tokens are referenced by environment-variable name (token_env); keep the actual secret in the backend .env file.',
        style: TextStyle(color: Colors.white54, fontSize: 11)),
    ]))),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: () {
        try {
          final name = _name.text.trim();
          if (name.isEmpty) throw const FormatException('Display name is required');
          final cfg = jsonDecode(_config.text) as Map<String, dynamic>;
          Navigator.pop(context, _SourceDraft(name, _kind, cfg, uploadJson: _upload));
        } catch (e) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Invalid source configuration: $e')));
        }
      }, child: Text(widget.initialName.isEmpty ? 'Add source' : 'Save changes')),
    ],
  );
}
